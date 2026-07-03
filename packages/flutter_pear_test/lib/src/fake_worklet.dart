import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_pear_bare/flutter_pear_bare.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/crypto.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';

part 'failure_injection.dart';

/// Thrown by [FakeBareWorklet]'s method handlers to produce a typed `err`
/// response envelope -- mirrors how pear-end/index.js attaches `err.code`
/// to a thrown JS `Error`.
class FakeRpcError implements Exception {
  /// Creates a fake RPC error with [message] and [code].
  FakeRpcError(this.message, this.code);

  /// Human-readable description -- the wire `err.message` field.
  final String message;

  /// Machine-readable code -- the wire `err.code` field. See [PearErrorCode].
  final String code;

  @override
  String toString() => 'FakeRpcError($code): $message';
}

/// A deterministic, in-memory "network" [FakeBareWorklet]s join topics on to
/// discover and connect to each other -- the in-memory stand-in for
/// Hyperswarm's real DHT: no timers, radios, or network latency. Joining a
/// topic another already-joined worklet is on connects both immediately.
///
/// Give two [FakeBareWorklet]s the same hub (via its constructor) to let
/// them talk to each other; each gets its own private hub by default, so
/// unrelated tests can't cross-connect by accident.
class FakeSwarmHub {
  final Map<String, Set<FakeBareWorklet>> _topics = {};

  /// Registers [worklet] as joined to [topicHex], connecting it to every
  /// other worklet already joined to the same topic (and vice versa).
  void join(String topicHex, FakeBareWorklet worklet) {
    final peers = _topics.putIfAbsent(topicHex, () => <FakeBareWorklet>{});
    for (final other in peers.toList()) {
      if (identical(other, worklet)) continue;
      worklet._connectTo(other, topicHex);
      other._connectTo(worklet, topicHex);
    }
    peers.add(worklet);
  }

  /// Removes [worklet] from [topicHex]'s membership. Existing peer
  /// connections are left alone -- matches real Hyperswarm, where leaving a
  /// topic doesn't kill live connections established through it.
  void leave(String topicHex, FakeBareWorklet worklet) {
    _topics[topicHex]?.remove(worklet);
  }
}

/// An in-memory, deterministic stand-in for a real Bare Kit worklet + the
/// pear-end JS it runs -- implements the same [WorkletIpc] seam so
/// `PearRpc`/`PearSwarm`/`PearConnection` (from `package:flutter_pear`) run
/// completely unmodified against it.
///
/// A CONFORMANCE CONSUMER (LOCKED, E3): this class implements the wire
/// schema (`package:flutter_pear/src/schema.dart`) as faithfully as
/// pear-end/index.js does for the request/response and event shapes
/// `PearSwarm`/`PearConnection` actually exercise -- it never defines new
/// behavior of its own. When the two disagree, the schema wins and this
/// file gets fixed to match, not the other way around.
///
/// Join two instances to the same [FakeSwarmHub] to simulate two peers
/// finding each other.
///
/// TIMING NOTE: unlike a real network, an already-present peer connects
/// here with no discovery delay at all -- the connecting side's own
/// `swarm.connection` event is queued right after its `swarm.join` ack (so
/// `await PearSwarm.join(...)` always resolves before that event is lost to
/// a not-yet-subscribed `.connections` stream), but nothing else is
/// delayed. A test that inserts EXTRA awaited work between joining and
/// subscribing to `.connections` (e.g. awaiting one side's first connection
/// before even reading the other side's stream) can still race past this
/// window on a real, slower network. Subscribe to `.connections` for every
/// side immediately after its own `PearSwarm.join(...)` resolves, with
/// nothing else awaited in between, before awaiting any of them.
class FakeBareWorklet implements WorkletIpc {
  /// Creates a fake worklet, optionally sharing [hub] with other instances
  /// so they can discover and connect to each other. Each instance gets its
  /// own private hub by default.
  FakeBareWorklet({FakeSwarmHub? hub})
      : hub = hub ?? FakeSwarmHub(),
        peerKey = _randomHex(32),
        _sessionNonce = _randomHex(16);

  /// The in-memory "network" this worklet joins topics on.
  final FakeSwarmHub hub;

  /// This worklet's peer identity -- a random 64-char hex string, matching
  /// `PearKey.hex`'s format, analogous to a real Hyperswarm public key.
  final String peerKey;

  final String _sessionNonce;

  final Set<String> _joinedTopics = {};
  final Map<String, FakeBareWorklet> _connections = {}; // peer hex -> other
  final Map<String, Set<String>> _connectionTopics = {}; // peer hex -> topics

  // E5.2 -- Corestore/Hypercore conformance. _cores holds THIS worklet's view
  // of each key it has opened via PearMethod.storeGet -- initially private,
  // becoming a shared _FakeCore object (same instance, both maps updated)
  // once PearMethod.coreReplicate binds it to a peer that also has that key
  // open. _closedCores is per-worklet (closing your own handle doesn't
  // affect a peer still replicating the same core), unlike _cores.
  final Map<String, _FakeCore> _cores = {}; // key hex -> core
  final Set<String> _closedCores = {}; // key hex

  // 'keyHex:peerHex' pairs this worklet has itself called coreReplicate for
  // -- see PearMethod.coreReplicate's handling below for why a merge only
  // happens once BOTH sides have recorded a matching offer. Shared with
  // bee replication below (PearMethod.beeReplicate) -- a bare identifier
  // string either a core's or a bee's key hex, same as pear-end/index.js's
  // real replicationStreams map being shared between the two methods.
  final Set<String> _replicateOffered = {};

  // E5.3 -- Hyperbee conformance. Same shape as _cores/_closedCores above:
  // _bees holds THIS worklet's view of each bee key it has opened via
  // PearMethod.beeOpen, becoming a shared _FakeBee object once
  // PearMethod.beeReplicate binds it to a peer that also has that key
  // open. _closedBees is per-worklet. _beeWatches holds THIS worklet's own
  // outstanding PearMethod.beeWatch subscriptions, by watchId.
  final Map<String, _FakeBee> _bees = {}; // bee key hex -> bee
  final Set<String> _closedBees = {}; // bee key hex
  final Map<String, _FakeBeeWatch> _beeWatches = {}; // watchId -> watch

  // E5.5 -- Hyperdrive conformance. Same shape as _cores/_closedCores: _drives
  // holds THIS worklet's view of each drive key it has opened via
  // PearMethod.driveOpen, becoming a shared _FakeDrive object once
  // PearMethod.driveReplicate binds it to a peer that also has that key
  // open. _closedDrives is per-worklet.
  final Map<String, _FakeDrive> _drives = {}; // drive key hex -> drive
  final Set<String> _closedDrives = {}; // drive key hex
  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  final StreamController<WorkletCrash> _crash =
      StreamController<WorkletCrash>.broadcast();

  // Set by FailureInjection.swallowNextRequest (E3.3) -- '*' matches any
  // method, a specific method name matches only that one. Null = swallow
  // nothing.
  String? _swallowNextMethod;

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<WorkletCrash> get onCrash => _crash.stream;

  @override
  Future<void> send(Uint8List frame) async {
    if (frame.isEmpty) return;
    if (frame[0] != PearFrameType.json) return; // not handled by the fake

    final Object? decoded;
    try {
      decoded = jsonDecode(utf8.decode(frame.sublist(1)));
    } catch (_) {
      return;
    }
    if (decoded is! Map || decoded['id'] is! int) return;

    final id = decoded['id'] as int;
    final method = decoded['m'] as String?;
    final params = decoded['p'] is Map ? decoded['p'] as Map : const {};

    if (_swallowNextMethod != null &&
        (_swallowNextMethod == '*' || _swallowNextMethod == method)) {
      _swallowNextMethod = null;
      return; // deliberately never responds -- see FailureInjection.swallowNextRequest
    }

    try {
      final result = await _handle(method, params);
      _respond(id, ok: result);
      if (method == PearMethod.swarmJoin) {
        // Deliberately AFTER the ack is sent/queued, not inside _handle:
        // this fake connects an already-present peer immediately (no real
        // network discovery delay), so if this ran before the ack, a
        // caller's own `await PearSwarm.join(...)` could resolve AFTER its
        // own resulting swarm.connection event had already been delivered
        // and lost (a plain broadcast stream doesn't replay to a listener
        // that subscribes once join() returns) -- ordering both frames
        // this way guarantees "await join(), then subscribe to
        // .connections" never misses a connection that same join()
        // triggers, matching what a real (slower) network naturally
        // guarantees for free.
        hub.join(params['topic'] as String, this);
      }
    } on FakeRpcError catch (e) {
      _respond(id, err: {'message': e.message, 'code': e.code});
    }
  }

  Future<Object?> _handle(String? method, Map params) async {
    switch (method) {
      case PearMethod.attachInfo:
        return {
          PearHandshakeField.nonce: _sessionNonce,
          // No real pear-end bundle to version-check against -- callers
          // that need Pear.start()'s bundle-version handshake construct
          // their own PearRpc directly against this fake instead (see
          // README): this covers PearRpc/PearSwarm conformance, not Pear.
          PearHandshakeField.bundleVersion: 'fake',
        };
      case PearMethod.swarmJoin:
        final topicHex = params['topic'] as String;
        if (_joinedTopics.add(topicHex)) {
          _sendState(topicHex, PearSwarmState.discovering);
        }
        return {'joined': topicHex};
      case PearMethod.swarmLeave:
        final topicHex = params['topic'] as String;
        if (_joinedTopics.remove(topicHex)) {
          hub.leave(topicHex, this);
        }
        return {'left': topicHex};
      case PearMethod.connectionWrite:
        final peerHex = params['peer'] as String;
        final other = _connections[peerHex];
        if (other == null) {
          throw FakeRpcError(
              'unknown peer: $peerHex', PearErrorCode.unknownPeer);
        }
        other._receiveData(peerKey, params['data'] as String);
        return null;
      case PearMethod.storeGet:
        final keyParam = params['key'] as String?;
        final nameParam = params['name'] as String?;
        if ((keyParam == null) == (nameParam == null)) {
          throw FakeRpcError('store.get needs exactly one of name/key',
              PearErrorCode.storageUnavailable);
        }
        // A name-derived key is salted with THIS worklet's own identity so
        // two different worklets calling store.get(name: sameName) do NOT
        // collide on the same key -- mirrors real Corestore, where a
        // name-derived key comes from that corestore's own on-disk primary
        // key (unique per device/install). Reaching the SAME core from
        // another worklet always requires its actual public key
        // (store.get(key:)), never a shared name.
        final keyHex =
            keyParam ?? PearCrypto.hash(utf8.encode('$peerKey:$nameParam')).hex;
        _closedCores.remove(keyHex); // a fresh session, even if a prior one closed
        final core =
            _cores.putIfAbsent(keyHex, () => _FakeCore(keyHex).._owners.add(this));
        // Only a name:-derived open ever claims writer status -- a
        // key:-derived open attaches to a (possibly remote) core exactly
        // like a real non-owning Corestore session: read-only until it
        // replicates in someone else's data (see coreAppend's writer check
        // below, which is what this models).
        if (keyParam == null) core.writer ??= this;
        return {'key': keyHex, 'length': core.blocks.length};
      case PearMethod.coreAppend:
        final keyHex = params['key'] as String;
        final core = _requireOpenCore(keyHex);
        if (!identical(core.writer, this)) {
          throw FakeRpcError(
              'core is not writable from this worklet: $keyHex',
              PearErrorCode.storageUnavailable);
        }
        core.append((params['data'] as List)
            .map((b) => base64Decode(b as String))
            .toList());
        return {'length': core.blocks.length};
      case PearMethod.coreGet:
        final keyHex = params['key'] as String;
        final core = _requireOpenCore(keyHex);
        final index = params['index'] as int;
        if (index < 0 || index >= core.blocks.length) {
          throw FakeRpcError(
              'index out of range: $index', PearErrorCode.indexOutOfRange);
        }
        return {'data': base64Encode(core.blocks[index])};
      case PearMethod.coreReplicate:
        final keyHex = params['key'] as String;
        final peerHex = params['peer'] as String;
        final other = _connections[peerHex];
        if (other == null) {
          throw FakeRpcError(
              'unknown peer: $peerHex', PearErrorCode.unknownPeer);
        }
        final mine = _requireOpenCore(keyHex);
        _replicateOffered.add('$keyHex:$peerHex');
        if (!other._replicateOffered.contains('$keyHex:$peerKey')) {
          // This worklet's own offer is now recorded; nothing actually
          // syncs until the peer ALSO calls replicate() for this same
          // (key, peer) pair -- mirrors real Hypercore, where both ends
          // must attach their own protocol instance to the shared
          // connection before the muxed channel opens and any data
          // crosses over. A test that forgets one side's call sees
          // exactly the same "nothing happens" as it would against a
          // real worklet, instead of a false-positive full sync.
          return null;
        }
        final theirs = other._cores[keyHex];
        if (theirs != null && !identical(theirs, mine)) {
          // Merge two independently-opened views of the same key into one
          // shared object -- see the field doc above _cores. Only ever
          // safe when one side's blocks are a prefix of the other's (the
          // only shape single-writer Hypercore replication can produce --
          // the writer check in coreAppend above is what's supposed to
          // prevent anything else from reaching here). This is the loud
          // backstop if that invariant is ever broken, instead of silently
          // discarding one side's real data.
          final canonical =
              mine.blocks.length >= theirs.blocks.length ? mine : theirs;
          final loser = identical(canonical, mine) ? theirs : mine;
          if (!_isPrefix(loser.blocks, canonical.blocks)) {
            throw StateError(
                'FakeBareWorklet: two non-identical, non-prefix core views '
                'for key $keyHex cannot be replicated -- this fake only '
                'models single-writer Hypercore (multi-writer is Autobase, '
                'out of scope for E5.2). Only the core\'s own writer '
                'should ever append to it.');
          }
          for (final owner in loser._owners.toList()) {
            owner._cores[keyHex] = canonical;
            canonical._owners.add(owner);
            // A real Hypercore fires 'append' as replicated blocks
            // actually arrive, so a peer catching up to a further-ahead
            // canonical learns its new length that way -- mirrored here
            // as one immediate sync, since this fake merges in one step
            // rather than streaming block-by-block.
            if (canonical.blocks.length > loser.blocks.length) {
              owner._emitEvent(PearEventName.coreUpdate,
                  {'key': keyHex, 'length': canonical.blocks.length});
            }
          }
        }
        return null;
      case PearMethod.coreClose:
        final keyHex = params['key'] as String;
        _requireCore(keyHex); // throws unknownCore if never opened
        _closedCores.add(keyHex);
        return null;
      case PearMethod.beeOpen:
        final keyParam = params['key'] as String?;
        final nameParam = params['name'] as String?;
        if ((keyParam == null) == (nameParam == null)) {
          throw FakeRpcError('bee.open needs exactly one of name/key',
              PearErrorCode.storageUnavailable);
        }
        // Same per-worklet salt rationale as PearMethod.storeGet -- see its
        // handling above.
        final beeKeyHex =
            keyParam ?? PearCrypto.hash(utf8.encode('$peerKey:$nameParam')).hex;
        _closedBees.remove(beeKeyHex); // a fresh session, even if a prior one closed
        final bee = _bees.putIfAbsent(beeKeyHex, () => _FakeBee(beeKeyHex).._owners.add(this));
        if (keyParam == null) bee.writer ??= this;
        return {'key': beeKeyHex};
      case PearMethod.beeGet:
        final bee = _requireOpenBee(params['bee'] as String);
        final value = bee.entries[_hexOf(base64Decode(params['key'] as String))];
        return value == null
            ? {'found': false}
            : {'found': true, 'value': base64Encode(value)};
      case PearMethod.beePut:
        final bee = _requireOpenBee(params['bee'] as String);
        if (!identical(bee.writer, this)) {
          throw FakeRpcError(
              'bee is not writable from this worklet: ${bee.keyHex}',
              PearErrorCode.storageUnavailable);
        }
        bee.put(base64Decode(params['key'] as String),
            base64Decode(params['value'] as String));
        return null;
      case PearMethod.beeDel:
        final bee = _requireOpenBee(params['bee'] as String);
        if (!identical(bee.writer, this)) {
          throw FakeRpcError(
              'bee is not writable from this worklet: ${bee.keyHex}',
              PearErrorCode.storageUnavailable);
        }
        bee.del(base64Decode(params['key'] as String));
        return null;
      case PearMethod.beeReplicate:
        final beeKeyHex = params['bee'] as String;
        final peerHex = params['peer'] as String;
        final other = _connections[peerHex];
        if (other == null) {
          throw FakeRpcError(
              'unknown peer: $peerHex', PearErrorCode.unknownPeer);
        }
        final mine = _requireOpenBee(beeKeyHex);
        _replicateOffered.add('$beeKeyHex:$peerHex');
        if (!other._replicateOffered.contains('$beeKeyHex:$peerKey')) {
          // Same two-sided handshake as PearMethod.coreReplicate -- see
          // its handling above for why.
          return null;
        }
        final theirs = other._bees[beeKeyHex];
        if (theirs != null && !identical(theirs, mine)) {
          final canonical =
              mine.entries.length >= theirs.entries.length ? mine : theirs;
          final loser = identical(canonical, mine) ? theirs : mine;
          if (!_isSubsetWithMatchingValues(loser.entries, canonical.entries)) {
            throw StateError(
                'FakeBareWorklet: two non-identical, non-subset bee views '
                'for bee $beeKeyHex cannot be replicated -- this fake only '
                'models single-writer Hyperbee (multi-writer is Autobase, '
                'out of scope for E5.3). Only the bee\'s own writer should '
                'ever put/del to it.');
          }
          for (final owner in loser._owners.toList()) {
            owner._bees[beeKeyHex] = canonical;
            canonical._owners.add(owner);
          }
          // Migrate the loser's watches onto canonical, notifying each one
          // if the merge actually changed what it can see -- mirrors
          // coreReplicate's "sync on merge" event above.
          final migratedWatches = loser._watches.toList();
          final changed = canonical.entries.length != loser.entries.length;
          for (final w in migratedWatches) {
            loser._watches.remove(w);
            canonical._watches.add(w);
            // Without this, a later beeUnwatch/beeClose for `w` would act
            // on the orphaned `loser` object -- a no-op that leaves `w`
            // permanently registered on `canonical` (E5.3 review fix).
            w.bee = canonical;
            if (changed) {
              w.owner._emitEvent(
                  PearEventName.beeUpdate, {'bee': beeKeyHex, 'watch': w.watchId});
            }
          }
        }
        return null;
      case PearMethod.beeRange:
        final bee = _requireOpenBee(params['bee'] as String);
        final entries = _rangeOf(bee, params);
        return {
          'entries': [
            for (final e in entries)
              {'key': base64Encode(_bytesOf(e.key)), 'value': base64Encode(e.value)}
          ]
        };
      case PearMethod.beeWatch:
        final beeKeyHex = params['bee'] as String;
        final bee = _requireOpenBee(beeKeyHex);
        final watchId = params['watch'] as String;
        final watch = _FakeBeeWatch(this, watchId, bee);
        _beeWatches[watchId] = watch;
        bee._watches.add(watch);
        return null;
      case PearMethod.beeUnwatch:
        final watchId = params['watch'] as String;
        final watch = _beeWatches[watchId];
        // Scoped by bee, same as beeClose's cleanup loop below -- mirrors
        // pear-end/index.js's BEE_UNWATCH fix.
        if (watch != null && watch.bee.keyHex == params['bee']) {
          _beeWatches.remove(watchId);
          watch.bee._watches.remove(watch);
        } else if (watch != null) {
          throw FakeRpcError(
              'watch $watchId does not belong to bee ${params['bee']}',
              PearErrorCode.unknownBee);
        }
        return null;
      case PearMethod.beeClose:
        final beeKeyHex = params['bee'] as String;
        _requireBee(beeKeyHex); // throws unknownBee if never opened
        if (_closedBees.add(beeKeyHex)) {
          for (final watchId
              in _beeWatches.keys.where((id) => _beeWatches[id]!.bee.keyHex == beeKeyHex).toList()) {
            final watch = _beeWatches.remove(watchId);
            watch?.bee._watches.remove(watch);
          }
        }
        return null;
      case PearMethod.driveOpen:
        final keyParam = params['key'] as String?;
        final nameParam = params['name'] as String?;
        if ((keyParam == null) == (nameParam == null)) {
          throw FakeRpcError('drive.open needs exactly one of name/key',
              PearErrorCode.storageUnavailable);
        }
        final driveKeyHex =
            keyParam ?? PearCrypto.hash(utf8.encode('$peerKey:$nameParam')).hex;
        _closedDrives.remove(driveKeyHex); // a fresh session, even if a prior one closed
        final drive = _drives.putIfAbsent(
            driveKeyHex, () => _FakeDrive(driveKeyHex).._owners.add(this));
        if (keyParam == null) drive.writer ??= this;
        return {'key': driveKeyHex};
      case PearMethod.drivePut:
        final drive = _requireOpenDrive(params['drive'] as String);
        if (!identical(drive.writer, this)) {
          throw FakeRpcError(
              'drive is not writable from this worklet: ${drive.keyHex}',
              PearErrorCode.storageUnavailable);
        }
        final bytes = await File(params['localSourcePath'] as String).readAsBytes();
        drive.files[params['path'] as String] = bytes;
        return null;
      case PearMethod.driveGet:
        final drive = _requireOpenDrive(params['drive'] as String);
        final virtualPath = params['path'] as String;
        final bytes = drive.files[virtualPath];
        if (bytes == null) {
          throw FakeRpcError('file not found: $virtualPath', PearErrorCode.fileNotFound);
        }
        await File(params['destinationPath'] as String).writeAsBytes(bytes);
        return null;
      case PearMethod.driveExists:
        final drive = _requireOpenDrive(params['drive'] as String);
        return {'exists': drive.files.containsKey(params['path'] as String)};
      case PearMethod.driveDelete:
        final drive = _requireOpenDrive(params['drive'] as String);
        if (!identical(drive.writer, this)) {
          throw FakeRpcError(
              'drive is not writable from this worklet: ${drive.keyHex}',
              PearErrorCode.storageUnavailable);
        }
        drive.files.remove(params['path'] as String);
        return null;
      case PearMethod.driveList:
        final drive = _requireOpenDrive(params['drive'] as String);
        final folder = (params['folder'] as String?) ?? '/';
        final paths = drive.files.keys
            .where((path) => _isUnderDriveFolder(path, folder))
            .toList()
          ..sort();
        return {'paths': paths};
      case PearMethod.driveReplicate:
        final driveKeyHex = params['drive'] as String;
        final peerHex = params['peer'] as String;
        final other = _connections[peerHex];
        if (other == null) {
          throw FakeRpcError(
              'unknown peer: $peerHex', PearErrorCode.unknownPeer);
        }
        final mine = _requireOpenDrive(driveKeyHex);
        _replicateOffered.add('$driveKeyHex:$peerHex');
        if (!other._replicateOffered.contains('$driveKeyHex:$peerKey')) {
          // Same two-sided handshake as PearMethod.coreReplicate/
          // beeReplicate -- see coreReplicate's handling for why.
          return null;
        }
        final theirs = other._drives[driveKeyHex];
        if (theirs != null && !identical(theirs, mine)) {
          final canonical =
              mine.files.length >= theirs.files.length ? mine : theirs;
          final loser = identical(canonical, mine) ? theirs : mine;
          if (!_isSubsetWithMatchingValues(loser.files, canonical.files)) {
            throw StateError(
                'FakeBareWorklet: two non-identical, non-subset drive views '
                'for drive $driveKeyHex cannot be replicated -- this fake '
                'only models single-writer Hyperdrive. Only the drive\'s '
                'own writer should ever put/delete on it.');
          }
          for (final owner in loser._owners.toList()) {
            owner._drives[driveKeyHex] = canonical;
            canonical._owners.add(owner);
          }
        }
        return null;
      case PearMethod.driveMirrorToDisk:
        final drive = _requireOpenDrive(params['drive'] as String);
        final localDir = params['localDir'] as String;
        // ponytail: unconditionally (re)writes every file and never prunes
        // extras already on disk -- the real implementation delegates all
        // diff/prune logic to mirror-drive itself (a battle-tested Pear
        // ecosystem library), so faithfully reproducing its diffing here
        // would just be re-testing that library, not this wrapper. Upgrade
        // if a test ever needs to assert prune/no-op-on-unchanged behavior.
        var added = 0;
        for (final entry in drive.files.entries) {
          final target = File(_joinDrivePath(localDir, entry.key));
          final existedBefore = await target.exists();
          if (!existedBefore) added++;
          await target.create(recursive: true);
          await target.writeAsBytes(entry.value);
        }
        return {'added': added, 'changed': 0, 'removed': 0};
      case PearMethod.driveClose:
        final driveKeyHex = params['drive'] as String;
        _requireDrive(driveKeyHex); // throws unknownDrive if never opened
        _closedDrives.add(driveKeyHex);
        return null;
      default:
        throw FakeRpcError(
            'unknown method: $method', PearErrorCode.unknownMethod);
    }
  }

  /// The number of currently-active [PearMethod.beeWatch] subscriptions
  /// THIS worklet has open for the bee [beeKeyHex] -- lets a test assert
  /// that canceling a Dart-side `PearBee.watch()` stream actually stops the
  /// underlying worklet-side watch (E5.3), not just locally.
  int activeBeeWatchCount(String beeKeyHex) =>
      _beeWatches.values.where((w) => w.bee.keyHex == beeKeyHex).length;

  _FakeCore _requireCore(String keyHex) {
    final core = _cores[keyHex];
    if (core == null) {
      throw FakeRpcError('unknown core: $keyHex', PearErrorCode.unknownCore);
    }
    return core;
  }

  _FakeCore _requireOpenCore(String keyHex) {
    final core = _requireCore(keyHex);
    if (_closedCores.contains(keyHex)) {
      throw FakeRpcError('core is closed: $keyHex', PearErrorCode.coreClosed);
    }
    return core;
  }

  _FakeBee _requireBee(String keyHex) {
    final bee = _bees[keyHex];
    if (bee == null) {
      throw FakeRpcError('unknown bee: $keyHex', PearErrorCode.unknownBee);
    }
    return bee;
  }

  _FakeBee _requireOpenBee(String keyHex) {
    final bee = _requireBee(keyHex);
    if (_closedBees.contains(keyHex)) {
      throw FakeRpcError('bee is closed: $keyHex', PearErrorCode.beeClosed);
    }
    return bee;
  }

  _FakeDrive _requireDrive(String keyHex) {
    final drive = _drives[keyHex];
    if (drive == null) {
      throw FakeRpcError('unknown drive: $keyHex', PearErrorCode.unknownDrive);
    }
    return drive;
  }

  _FakeDrive _requireOpenDrive(String keyHex) {
    final drive = _requireDrive(keyHex);
    if (_closedDrives.contains(keyHex)) {
      throw FakeRpcError('drive is closed: $keyHex', PearErrorCode.driveClosed);
    }
    return drive;
  }

  void _connectTo(FakeBareWorklet other, String topicHex) {
    final peerHex = other.peerKey;
    final isNew = !_connections.containsKey(peerHex);
    _connections[peerHex] = other;
    _connectionTopics.putIfAbsent(peerHex, () => <String>{}).add(topicHex);
    if (isNew) {
      _emitEvent(
          PearEventName.swarmConnection, {'topic': topicHex, 'peer': peerHex});
    }
    _sendState(topicHex, PearSwarmState.connected);
  }

  /// Simulates this peer disconnecting from [other] -- the in-memory
  /// equivalent of a real Hyperswarm connection ending. Emits
  /// [PearEventName.connectionClose] on this side only; call it on both
  /// sides to simulate a mutual disconnect, or one side only to simulate
  /// whichever peer detects the drop first.
  void disconnectFrom(FakeBareWorklet other) {
    final peerHex = other.peerKey;
    if (_connections.remove(peerHex) == null) return;
    final topics = _connectionTopics.remove(peerHex) ?? const <String>{};
    for (final topicHex in topics) {
      _emitEvent(PearEventName.connectionClose,
          {'topic': topicHex, 'peer': peerHex});
    }
  }

  void _receiveData(String fromPeerHex, String dataBase64) {
    final topics = _connectionTopics[fromPeerHex] ?? const <String>{};
    for (final topicHex in topics) {
      _emitEvent(PearEventName.connectionData, {
        'topic': topicHex,
        'peer': fromPeerHex,
        'data': dataBase64,
      });
    }
  }

  void _sendState(String topicHex, PearSwarmState state, {String? reason}) {
    _emitEvent(PearEventName.swarmLifecycle, {
      'topic': topicHex,
      'state': state.name,
      if (reason != null) 'reason': reason,
    });
  }

  void _emitEvent(String name, Map<String, Object?> payload,
      {String? nonceOverride}) {
    _emit({'ev': name, 'p': payload}, nonceOverride: nonceOverride);
  }

  void _respond(int id, {Object? ok, Map<String, Object?>? err}) {
    _emit({'id': id, if (err != null) 'err': err else 'ok': ok});
  }

  void _emit(Map<String, Object?> body, {String? nonceOverride}) {
    final stamped = {
      ...body,
      PearHandshakeField.envelopeNonce: nonceOverride ?? _sessionNonce,
    };
    final jsonBytes = utf8.encode(jsonEncode(stamped));
    final frame = Uint8List(jsonBytes.length + 1)
      ..[0] = PearFrameType.json
      ..setRange(1, jsonBytes.length + 1, jsonBytes);
    _incoming.add(frame);
  }
}

/// E5.2 -- one in-memory Hypercore's worth of state: an append-only block
/// list plus the set of [FakeBareWorklet]s currently sharing this exact
/// object (see [FakeBareWorklet._cores]'s field doc for how two worklets'
/// independently-opened views get merged onto one instance).
class _FakeCore {
  _FakeCore(this.keyHex);

  final String keyHex;
  final List<Uint8List> blocks = [];
  final Set<FakeBareWorklet> _owners = {};

  /// The worklet that created this core via `store.get(name:)` -- the only
  /// one allowed to [append] to it (see `PearMethod.coreAppend`'s writer
  /// check). Null until a name:-derived open claims it; a `key:`-derived
  /// open never sets this, matching a real non-owning Corestore session's
  /// read-only status.
  FakeBareWorklet? writer;

  void append(List<Uint8List> newBlocks) {
    blocks.addAll(newBlocks);
    for (final owner in _owners) {
      owner._emitEvent(
        PearEventName.coreUpdate,
        {'key': keyHex, 'length': blocks.length},
      );
    }
  }
}

/// Whether every block in [prefix] equals the block at the same index in
/// [full] -- the only shape two independently-appended core views can
/// safely merge into one without discarding real data (see
/// `PearMethod.coreReplicate`'s merge step).
bool _isPrefix(List<Uint8List> prefix, List<Uint8List> full) {
  if (prefix.length > full.length) return false;
  for (var i = 0; i < prefix.length; i++) {
    if (!_bytesEqual(prefix[i], full[i])) return false;
  }
  return true;
}

bool _bytesEqual(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// E5.3 -- one in-memory Hyperbee's worth of state: an ordered key/value map
/// (keyed by [_hexOf]'s hex encoding, which sorts identically to
/// byte-lexicographic order -- see [_rangeOf]) plus the set of
/// [FakeBareWorklet]s currently sharing this exact object, same merge
/// mechanics as [_FakeCore].
class _FakeBee {
  _FakeBee(this.keyHex);

  final String keyHex;
  final SplayTreeMap<String, Uint8List> entries = SplayTreeMap<String, Uint8List>();
  final Set<FakeBareWorklet> _owners = {};
  final Set<_FakeBeeWatch> _watches = {};

  /// The worklet that created this bee via `bee.open(name:)` -- the only
  /// one allowed to [put]/[del] (see `PearMethod.beePut`/`beeDel`'s writer
  /// check). Same read-only-unless-owner rule as `_FakeCore.writer`.
  FakeBareWorklet? writer;

  void put(Uint8List key, Uint8List value) {
    entries[_hexOf(key)] = value;
    _notify();
  }

  void del(Uint8List key) {
    if (entries.remove(_hexOf(key)) != null) _notify();
  }

  void _notify() {
    // ponytail: fires every active watch on ANY change to this bee,
    // regardless of that watch's own gt/gte/lt/lte bounds -- a
    // conservative (occasionally-redundant, never-missing) approximation
    // of real Hyperbee's own bounds-aware diffing. Upgrade to precise
    // bounds-filtering if a test ever needs to assert a watch does NOT
    // fire for an out-of-range change.
    for (final w in _watches.toList()) {
      w.owner._emitEvent(
          PearEventName.beeUpdate, {'bee': keyHex, 'watch': w.watchId});
    }
  }
}

/// One [PearMethod.beeWatch] subscription -- tracked both on the owning
/// [FakeBareWorklet] (by watchId, for [FakeBareWorklet.activeBeeWatchCount]
/// and [PearMethod.beeUnwatch]/[PearMethod.beeClose] lookups) and on the
/// [_FakeBee] itself (for [_FakeBee._notify] and replicate-merge
/// carryover).
class _FakeBeeWatch {
  _FakeBeeWatch(this.owner, this.watchId, this.bee);

  final FakeBareWorklet owner;
  final String watchId;

  /// The [_FakeBee] this watch currently belongs to -- mutable, not final:
  /// a `PearMethod.beeReplicate` merge repoints this to the canonical
  /// object (see that handling above), so a later
  /// [PearMethod.beeUnwatch]/[PearMethod.beeClose] removes this watch from
  /// the live shared object instead of the orphaned pre-merge one.
  _FakeBee bee;
}

/// E5.5 -- one in-memory Hyperdrive's worth of state: virtual path -> file
/// content, plus the set of [FakeBareWorklet]s currently sharing this exact
/// object, same merge mechanics as [_FakeCore]/[_FakeBee]. No ordering
/// requirement (unlike [_FakeBee.entries]) since `PearMethod.driveList`
/// sorts its own result.
class _FakeDrive {
  _FakeDrive(this.keyHex);

  final String keyHex;
  final Map<String, Uint8List> files = {};
  final Set<FakeBareWorklet> _owners = {};

  /// The worklet that created this drive via `drive.open(name:)` -- the
  /// only one allowed to [PearMethod.drivePut]/[PearMethod.driveDelete] on
  /// it. Same read-only-unless-owner rule as `_FakeCore.writer`/
  /// `_FakeBee.writer`.
  FakeBareWorklet? writer;
}

/// Whether [path] falls under [folder] (see `PearMethod.driveList`) --
/// `/` matches everything; any other folder must match as a path segment
/// prefix (`/docs` matches `/docs/x.txt`, not `/docsomething/x.txt`).
bool _isUnderDriveFolder(String path, String folder) {
  if (folder == '/') return true;
  final normalized = folder.endsWith('/') ? folder : '$folder/';
  return path.startsWith(normalized);
}

/// Joins a local directory with a drive's virtual path (always `/`-rooted)
/// for `PearMethod.driveMirrorToDisk` -- avoids a doubled separator when
/// [localDir] already ends with one.
String _joinDrivePath(String localDir, String virtualPath) {
  final base = localDir.endsWith('/')
      ? localDir.substring(0, localDir.length - 1)
      : localDir;
  return '$base$virtualPath';
}

/// Whether every entry in [subset] is present in [full] with an identical
/// value -- the KV-store analogue of [_isPrefix]: the only shape two
/// independently-mutated bee/drive views can safely merge into one without
/// discarding real data (see `PearMethod.beeReplicate`/`driveReplicate`'s
/// merge steps). Takes a plain `Map` so it works for both `_FakeBee.entries`
/// (a `SplayTreeMap`, for ordering) and `_FakeDrive.files` (order doesn't
/// matter there).
bool _isSubsetWithMatchingValues(
    Map<String, Uint8List> subset, Map<String, Uint8List> full) {
  for (final e in subset.entries) {
    final other = full[e.key];
    if (other == null || !_bytesEqual(other, e.value)) return false;
  }
  return true;
}

/// Entries of [bee] within the base64-encoded `gt`/`gte`/`lt`/`lte` bounds
/// in [params] (see `PearMethod.beeRange`), honoring `reverse`/`limit`.
Iterable<MapEntry<String, Uint8List>> _rangeOf(_FakeBee bee, Map params) {
  String? boundHex(String field) {
    final v = params[field] as String?;
    return v == null ? null : _hexOf(base64Decode(v));
  }

  final gt = boundHex('gt');
  final gte = boundHex('gte');
  final lt = boundHex('lt');
  final lte = boundHex('lte');
  final reverse = params['reverse'] == true;
  final limit = params['limit'] as int?;

  var entries = bee.entries.entries.where((e) {
    if (gt != null && e.key.compareTo(gt) <= 0) return false;
    if (gte != null && e.key.compareTo(gte) < 0) return false;
    if (lt != null && e.key.compareTo(lt) >= 0) return false;
    if (lte != null && e.key.compareTo(lte) > 0) return false;
    return true;
  }).toList();
  if (reverse) entries = entries.reversed.toList();
  if (limit != null && entries.length > limit) {
    entries = entries.sublist(0, limit);
  }
  return entries;
}

/// Lower-case hex encoding of [bytes] -- unlike [PearKey.hex], works for any
/// length (KV entry keys aren't fixed at 32 bytes).
String _hexOf(Uint8List bytes) {
  final sb = StringBuffer();
  for (final b in bytes) {
    sb.write(b.toRadixString(16).padLeft(2, '0'));
  }
  return sb.toString();
}

/// Inverse of [_hexOf].
Uint8List _bytesOf(String hex) {
  final out = Uint8List(hex.length ~/ 2);
  for (var i = 0; i < out.length; i++) {
    out[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
  }
  return out;
}

String _randomHex(int byteLength) {
  final random = Random.secure();
  final bytes = List<int>.generate(byteLength, (_) => random.nextInt(256));
  return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
}
