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
  /// Creates an empty hub with no topics or invites yet.
  FakeSwarmHub();

  final Map<String, Set<FakeBareWorklet>> _topics = {};

  // E5.6 -- blind-pairing conformance. Unlike cores/bees/drives, an invite
  // is a single shared resource from the moment it's created (real
  // DHT-based discovery makes it globally reachable to anyone holding the
  // invite bytes) -- no per-worklet duplicate-then-merge-on-replicate
  // machinery needed, just one shared map every worklet on this hub reads
  // and writes directly.
  final Map<String, _FakeInvite> _invites = {};

  // E5.8 -- a hub-wide monotonic counter stamped on every orderedLog append
  // at APPLY time, purely to give two independently-grown logs a stable
  // merge order (see _FakeBase.log's doc). NOT used for lww/crdtMap conflict
  // resolution -- those use each writer's own local seq instead (see
  // _FakeBase.writerSeq's doc for why a hub-wide/call-order counter would
  // pick a different winner than the real recipes' isNewer/causal-order
  // semantics do).
  int _baseOpSeq = 0;
  int _nextBaseOpSeq() => _baseOpSeq++;

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
/// nothing else awaited in between, before awaiting any of them -- or sidestep
/// the ordering entirely with `PearSwarm.establishedConnections`, a
/// synchronous snapshot that can't be raced by subscription timing.
///
/// ```dart
/// import 'package:flutter_pear/flutter_pear.dart';
/// import 'package:flutter_pear/src/rpc.dart';
/// import 'package:flutter_pear/src/schema.dart';
///
/// final hub = FakeSwarmHub();
/// final rpcA = PearRpc(FakeBareWorklet(hub: hub));
/// final rpcB = PearRpc(FakeBareWorklet(hub: hub));
/// await rpcA.call(PearMethod.attachInfo);
/// await rpcB.call(PearMethod.attachInfo);
///
/// final topic = PearCrypto.unsafeTopicFromString('test-topic');
/// final swarmA = await PearSwarm.join(rpcA, topic);
/// final swarmB = await PearSwarm.join(rpcB, topic);
/// // swarmA/swarmB now see each other via swarmA.connections/swarmB.connections.
/// ```
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
  // Topics that have reached PearSwarmState.connected at least once --
  // mirrors pear-end/index.js's per-topic `everConnected` flag, needed for
  // the idempotent-rejoin replay below to pick RECONNECTING over
  // DISCOVERING when correct.
  final Set<String> _everConnectedTopics = {};

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

  // E5.8 -- Autobase conformance. Same registry SHAPE as _cores/_bees/
  // _drives above (per-worklet _bases holding THIS worklet's view, becoming
  // a shared _FakeBase object once PearMethod.baseReplicate binds it to a
  // peer that also has that key open; _closedBases per-worklet;
  // _baseWatches this worklet's own outstanding PearMethod.baseWatch
  // subscriptions) -- but the MERGE itself is fundamentally different: see
  // _FakeBase's own doc for why a base can't reuse the single-writer
  // prefix/subset-check pattern the others use.
  final Map<String, _FakeBase> _bases = {}; // base key hex -> base
  final Set<String> _closedBases = {}; // base key hex
  final Map<String, _FakeBaseWatch> _baseWatches = {}; // watchId -> watch
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
        } else {
          // Conformance fix (flutter_pear-doi hardware finding, matches
          // pear-end/index.js's identical fix): a repeat join of an
          // already-joined topic -- e.g. a fresh PearSwarm created after a
          // real Dart hot restart, talking to a worklet that never
          // stopped -- must replay the CURRENT state, not silently no-op.
          // Without this, a caller that (re)joins an already-connected
          // topic never learns about it and eventually times out via
          // PearSwarmDefaults.joinTimeout despite nothing actually being
          // wrong.
          final connectedPeers = _connectionTopics.entries
              .where((e) => e.value.contains(topicHex))
              .map((e) => e.key)
              .toList();
          if (connectedPeers.isNotEmpty) {
            for (final peerHex in connectedPeers) {
              _emitEvent(PearEventName.swarmConnection,
                  {'topic': topicHex, 'peer': peerHex});
            }
            _sendState(topicHex, PearSwarmState.connected);
          } else if (_everConnectedTopics.contains(topicHex)) {
            _sendState(topicHex, PearSwarmState.reconnecting);
          } else {
            _sendState(topicHex, PearSwarmState.discovering);
          }
        }
        return {'joined': topicHex};
      case PearMethod.swarmLeave:
        final topicHex = params['topic'] as String;
        if (_joinedTopics.remove(topicHex)) {
          // Mirrors pear-end/index.js's SWARM_LEAVE (`topics.delete(p.topic)`
          // -- a clean slate, not just a membership flag flip): a later
          // rejoin of the same topic must start genuinely fresh at
          // DISCOVERING, not incorrectly replay RECONNECTING for a topic
          // that was properly left.
          _everConnectedTopics.remove(topicHex);
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
        _closedCores
            .remove(keyHex); // a fresh session, even if a prior one closed
        final core = _cores.putIfAbsent(
            keyHex, () => _FakeCore(keyHex).._owners.add(this));
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
          throw FakeRpcError('core is not writable from this worklet: $keyHex',
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
        _closedBees
            .remove(beeKeyHex); // a fresh session, even if a prior one closed
        final bee = _bees.putIfAbsent(
            beeKeyHex, () => _FakeBee(beeKeyHex).._owners.add(this));
        if (keyParam == null) bee.writer ??= this;
        return {'key': beeKeyHex};
      case PearMethod.beeGet:
        final bee = _requireOpenBee(params['bee'] as String);
        final value =
            bee.entries[_hexOf(base64Decode(params['key'] as String))];
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
              w.owner._emitEvent(PearEventName.beeUpdate,
                  {'bee': beeKeyHex, 'watch': w.watchId});
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
              {
                'key': base64Encode(_bytesOf(e.key)),
                'value': base64Encode(e.value)
              }
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
          for (final watchId in _beeWatches.keys
              .where((id) => _beeWatches[id]!.bee.keyHex == beeKeyHex)
              .toList()) {
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
        _closedDrives
            .remove(driveKeyHex); // a fresh session, even if a prior one closed
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
        final bytes =
            await File(params['localSourcePath'] as String).readAsBytes();
        drive.files[params['path'] as String] = bytes;
        return null;
      case PearMethod.driveGet:
        final drive = _requireOpenDrive(params['drive'] as String);
        final virtualPath = params['path'] as String;
        final bytes = drive.files[virtualPath];
        if (bytes == null) {
          throw FakeRpcError(
              'file not found: $virtualPath', PearErrorCode.fileNotFound);
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
        var rejected = 0;
        // Zip-slip hardening (flutter_pear-ovt.2.7/2.8): every injected
        // symlink is rejected unconditionally, same as the real worklet --
        // never written, never followed.
        for (final path in drive.symlinks.keys) {
          rejected++;
          _emitEvent(PearEventName.driveMirrorWarning, {
            'drive': drive.keyHex,
            'path': path,
            'reason': 'symlink-rejected',
          });
        }
        for (final entry in drive.files.entries) {
          // A simplified stand-in for the real containment check (which
          // resolves the destination path and compares it against
          // localDir): this fake has no on-disk symlinks to pre-position a
          // real escape through, so a literal `..` segment in the entry's
          // OWN key is the fake's whole hostile-path surface -- sufficient
          // to reproduce the OBSERVABLE contract (rejection + event +
          // count) app-dev tests need, without re-implementing real
          // filesystem path resolution.
          if (entry.key.contains('..')) {
            rejected++;
            _emitEvent(PearEventName.driveMirrorWarning, {
              'drive': drive.keyHex,
              'path': entry.key,
              'reason': 'path-escape',
            });
            continue;
          }
          final target = File(_joinDrivePath(localDir, entry.key));
          final existedBefore = await target.exists();
          if (!existedBefore) added++;
          await target.create(recursive: true);
          await target.writeAsBytes(entry.value);
        }
        return {'added': added, 'changed': 0, 'removed': 0, 'rejected': rejected};
      case PearMethod.driveClose:
        final driveKeyHex = params['drive'] as String;
        _requireDrive(driveKeyHex); // throws unknownDrive if never opened
        _closedDrives.add(driveKeyHex);
        return null;
      case PearMethod.baseOpen:
        final keyParam = params['key'] as String?;
        final nameParam = params['name'] as String?;
        if ((keyParam == null) == (nameParam == null)) {
          throw FakeRpcError('base.open needs exactly one of name/key',
              PearErrorCode.storageUnavailable);
        }
        final recipeParam = params['recipe'] as String?;
        PearRecipe? recipe;
        for (final r in PearRecipe.values) {
          if (r.name == recipeParam) {
            recipe = r;
            break;
          }
        }
        if (recipe == null) {
          throw FakeRpcError(
              'unknown recipe: $recipeParam', PearErrorCode.unknownRecipe);
        }
        // Recipe is NOT folded into the salt -- matches pear-end/index.js's
        // real key derivation (`namespaceSeed = p.key || p.name`, recipe
        // never enters it), so reopening the SAME name with a DIFFERENT
        // recipe aliases onto the SAME base/key here too (and _bases'
        // putIfAbsent below then silently keeps the original recipe,
        // exactly like the real worklet silently keeps the original
        // Autobase instance's open/apply pair).
        final baseKeyHex =
            keyParam ?? PearCrypto.hash(utf8.encode('$peerKey:$nameParam')).hex;
        _closedBases
            .remove(baseKeyHex); // a fresh session, even if a prior one closed
        final base = _bases.putIfAbsent(baseKeyHex,
            () => _FakeBase(baseKeyHex, recipe!).._owners.add(this));
        // writerKey: derived per (worklet, base) -- a real Autobase writer
        // key (base.local.key) is namespaced per-base, so the SAME worklet
        // opening two DIFFERENT bases must get two DIFFERENT writerKeys
        // (see _writerKeyFor's doc).
        final writerKeyHex = _writerKeyFor(baseKeyHex);
        // A name-derived open is always the genesis writer AND indexer; a
        // key-derived attach is read-only until a PearMethod.baseAppend
        // addWriter op admits this worklet's own writerKey (see that
        // handling below) -- a SET of admitted writers, unlike
        // core/bee/drive's single immutable `writer` field, since a base
        // can admit more than one.
        if (keyParam == null) {
          base.writers.add(writerKeyHex);
          base.indexers.add(writerKeyHex);
        }
        return {'key': baseKeyHex, 'writerKey': writerKeyHex};
      case PearMethod.baseReplicate:
        final baseKeyHex = params['base'] as String;
        final peerHex = params['peer'] as String;
        final other = _connections[peerHex];
        if (other == null) {
          throw FakeRpcError(
              'unknown peer: $peerHex', PearErrorCode.unknownPeer);
        }
        final mine = _requireOpenBase(baseKeyHex);
        _replicateOffered.add('$baseKeyHex:$peerHex');
        if (!other._replicateOffered.contains('$baseKeyHex:$peerKey')) {
          // Same two-sided handshake as PearMethod.coreReplicate/
          // beeReplicate/driveReplicate -- see coreReplicate's handling.
          return null;
        }
        final theirs = other._bases[baseKeyHex];
        if (theirs != null && !identical(theirs, mine)) {
          // UNLIKE core/bee/drive: no "throw if not a clean prefix/subset"
          // gate -- two independently-evolved bases are EXPECTED to
          // diverge (that's the whole point of multi-writer) and always
          // merge safely (see _mergeBases's doc). Every current owner of
          // EITHER side gets repointed at the one canonical merged object.
          //
          // NOTE (known fake limitation): this fusion is PERMANENT -- once
          // merged, every owner shares the one canonical object with no way
          // to "unreplicate", so this fake can't model a real Autobase
          // pair's repeated diverge/reconnect/reconcile cycle (only a
          // single reconciliation). Fine for "two writers converge" tests;
          // not for "sync, disconnect, diverge again, resync" ones.
          final beforeMine = _baseDataSize(mine);
          final beforeTheirs = _baseDataSize(theirs);
          final canonical = _mergeBases(mine, theirs);
          for (final owner in {...mine._owners, ...theirs._owners}) {
            owner._bases[baseKeyHex] = canonical;
            canonical._owners.add(owner);
          }
          for (final w in [...mine._watches, ...theirs._watches]) {
            mine._watches.remove(w);
            theirs._watches.remove(w);
            canonical._watches.add(w);
            w.base = canonical;
          }
          // Only notify if the merge actually changed something -- matches
          // coreReplicate/beeReplicate's own "did the size actually change"
          // convention, so e.g. two freshly-opened, still-empty bases
          // replicating for the first time doesn't fire a spurious update.
          final afterSize = _baseDataSize(canonical);
          if (afterSize != beforeMine || afterSize != beforeTheirs) {
            canonical._notify();
          }
        }
        return null;
      case PearMethod.baseAppend:
        final baseKeyHex = params['base'] as String;
        final base = _requireOpenBase(baseKeyHex);
        final myWriterKey = _writerKeyFor(baseKeyHex);
        if (!base.writers.contains(myWriterKey)) {
          throw FakeRpcError(
              'base is not writable from this worklet: $baseKeyHex',
              PearErrorCode.storageUnavailable);
        }
        final value = params['value'] as Map;
        // Shared cross-cutting op shape every recipe recognizes identically
        // -- see pear-end's real recipes module's own doc. Gated behind the
        // SAME writer check above as any other op: admitting/removing a
        // writer is how a non-writer BECOMES one, but the admitter/remover
        // itself must already be an admitted writer (a real, non-admitted
        // Autobase writer's self-authored ops are never linearized/
        // observed by anyone else -- self-admission is structurally
        // impossible there, so it must be here too).
        if (value['addWriter'] != null) {
          final target = value['addWriter'] as String;
          base.writers.add(target);
          if (value['indexer'] != false) base.indexers.add(target);
          return null;
        }
        if (value['removeWriter'] != null) {
          final target = value['removeWriter'] as String;
          // Autobase itself refuses to remove the last remaining indexer
          // -- see PearBase.removeWriter's doc.
          if (base.indexers.contains(target) && base.indexers.length <= 1) {
            throw FakeRpcError(
                'cannot remove the last remaining indexer: $baseKeyHex',
                PearErrorCode.storageUnavailable);
          }
          base.writers.remove(target);
          base.indexers.remove(target);
          return null;
        }
        switch (base.recipe) {
          case PearRecipe.lww:
            // This writer's OWN local seq -- never a hub-wide counter, see
            // writerSeq's doc for why that distinction is load-bearing.
            final seq = (base.writerSeq[myWriterKey] =
                (base.writerSeq[myWriterKey] ?? 0) + 1);
            final type = value['type'] as String;
            final keyHex = _hexOf(base64Decode(value['key'] as String));
            base.lwwEntries[keyHex] = type == 'put'
                ? (
                    value: base64Decode(value['value'] as String),
                    deleted: false,
                    seq: seq,
                    writer: myWriterKey,
                  )
                : (value: null, deleted: true, seq: seq, writer: myWriterKey);
          case PearRecipe.orderedLog:
            // Hub-wide is fine here -- see `log`'s own doc.
            final seq = hub._nextBaseOpSeq();
            base.log
                .add((entry: base64Decode(value['entry'] as String), seq: seq));
          case PearRecipe.crdtMap:
            final seq = (base.writerSeq[myWriterKey] =
                (base.writerSeq[myWriterKey] ?? 0) + 1);
            final type = value['type'] as String;
            final keyHex = _hexOf(base64Decode(value['key'] as String));
            if (type == 'put') {
              final tag = '$myWriterKey:$seq';
              base.crdtTags.putIfAbsent(keyHex, () => {})[tag] =
                  base64Decode(value['value'] as String);
            } else {
              // A caller (PearBase.del) never has to read tags itself --
              // auto-filled from THIS worklet's own currently-observed
              // tags for `key` if not already given, mirroring pear-end's
              // real recipes module's normalizeAppend hook exactly.
              final removes = (value['removes'] as List?)?.cast<String>() ??
                  base.crdtTags[keyHex]?.keys.toList() ??
                  const <String>[];
              base.crdtTombstones.addAll(removes);
              base.crdtTags[keyHex]
                  ?.removeWhere((tag, _) => removes.contains(tag));
            }
        }
        base._notify();
        return null;
      case PearMethod.baseGet:
        final base = _requireOpenBase(params['base'] as String);
        if (base.recipe != PearRecipe.lww &&
            base.recipe != PearRecipe.crdtMap) {
          throw FakeRpcError(
              'base.get is not supported by the ${base.recipe.name} recipe',
              PearErrorCode.storageUnavailable);
        }
        final keyHex = _hexOf(base64Decode(params['key'] as String));
        if (base.recipe == PearRecipe.lww) {
          final entry = base.lwwEntries[keyHex];
          if (entry == null || entry.deleted) return {'exists': false};
          return {'exists': true, 'value': base64Encode(entry.value!)};
        }
        final tags = base.crdtTags[keyHex];
        if (tags == null || tags.isEmpty) return {'exists': false};
        // Same canonical-pick rule as the real crdtMap recipe's isNewer --
        // see _tagIsNewer's doc.
        String? winnerTag;
        for (final tag in tags.keys) {
          if (winnerTag == null || _tagIsNewer(tag, winnerTag)) {
            winnerTag = tag;
          }
        }
        return {'exists': true, 'value': base64Encode(tags[winnerTag]!)};
      case PearMethod.baseRange:
        final base = _requireOpenBase(params['base'] as String);
        if (base.recipe != PearRecipe.orderedLog) {
          throw FakeRpcError(
              'base.range is only supported by the orderedLog recipe',
              PearErrorCode.storageUnavailable);
        }
        final start = params['start'] as int? ?? 0;
        final end = params['end'] as int? ?? base.log.length;
        return {
          'entries': base.log
              .sublist(start, end)
              .map((e) => base64Encode(e.entry))
              .toList(),
        };
      case PearMethod.baseWatch:
        final base = _requireOpenBase(params['base'] as String);
        final watchId = params['watch'] as String;
        final watch = _FakeBaseWatch(this, watchId, base);
        _baseWatches[watchId] = watch;
        base._watches.add(watch);
        return null;
      case PearMethod.baseUnwatch:
        final watchId = params['watch'] as String;
        final watch = _baseWatches[watchId];
        // Scoped by base, same as baseClose's cleanup loop below.
        if (watch != null && watch.base.keyHex == params['base']) {
          _baseWatches.remove(watchId);
          watch.base._watches.remove(watch);
        } else if (watch != null) {
          throw FakeRpcError(
              'watch $watchId does not belong to base ${params['base']}',
              PearErrorCode.unknownBase);
        }
        return null;
      case PearMethod.baseClose:
        final baseKeyHex = params['base'] as String;
        _requireBase(baseKeyHex); // throws unknownBase if never opened
        if (_closedBases.add(baseKeyHex)) {
          for (final watchId in _baseWatches.keys
              .where((id) => _baseWatches[id]!.base.keyHex == baseKeyHex)
              .toList()) {
            final watch = _baseWatches.remove(watchId);
            watch?.base._watches.remove(watch);
          }
        }
        return null;
      case PearMethod.pairingCreateInvite:
        final inviteId = _randomHex(16);
        final expiresAt = params['expiresAt'] as int? ?? 0;
        hub._invites[inviteId] = _FakeInvite(inviteId, expiresAt, this);
        // The fake's "invite bytes" are just the id itself, opaque to
        // Dart -- unlike the real blind-pairing wire format, nothing here
        // needs decoding beyond that id, since PearMethod.pairingAcceptInvite
        // below looks the invite straight up in the shared hub.
        return {
          'invite': base64Encode(utf8.encode(inviteId)),
          'inviteId': inviteId,
        };
      case PearMethod.pairingConfirmCandidate:
        final inviteId = params['inviteId'] as String;
        final invite = hub._invites[inviteId];
        // Both checks mirror the real worklet's per-process `invites` Map:
        // real PAIRING_REVOKE does invites.delete(...), so a post-revoke
        // confirm hits getInviteOrThrow's UNKNOWN_INVITE outright -- the
        // fake keeps a revoked entry around (see pairingRevoke's doc below)
        // so accept can still time out realistically, but confirm must
        // still treat it as gone. Likewise a real worklet's `invites` map
        // is private to the process that ran pairingCreateInvite -- any
        // OTHER worklet confirming the same inviteId would find no entry
        // at all and hit the same UNKNOWN_INVITE; hub._invites is shared
        // hub-wide with no such privacy, so the owner check reproduces it
        // (E5.6 review fix -- both gaps let the fake diverge from the real
        // worklet).
        if (invite == null ||
            invite.revoked ||
            !identical(invite.owner, this)) {
          throw FakeRpcError(
              'unknown invite: $inviteId', PearErrorCode.unknownInvite);
        }
        final candidateId = params['candidateId'] as String;
        final candidate = invite.pending.remove(candidateId);
        if (candidate == null) {
          throw FakeRpcError('unknown candidate: $candidateId',
              PearErrorCode.unknownCandidate);
        }
        candidate.confirmed.complete(base64Decode(params['key'] as String));
        return null;
      case PearMethod.pairingRevoke:
        // Marks revoked rather than removing the entry -- a revoked
        // invite's BYTES stay just as decodable as before (mirrors real
        // blind-pairing: decodeInvite is a pure function of the invite
        // bytes with no dependency on whether a Member is still
        // listening). What actually changes is nobody responds to a new
        // accept attempt anymore, exactly like a real closed Member
        // registration never seeing/answering a fresh request -- see
        // PearMethod.pairingAcceptInvite's handling below.
        hub._invites[params['inviteId'] as String]?.revoked = true;
        return null;
      case PearMethod.pairingAcceptInvite:
        final String inviteId;
        try {
          inviteId = utf8.decode(base64Decode(params['invite'] as String));
        } catch (_) {
          throw FakeRpcError('invalid invite', PearErrorCode.invalidInvite);
        }
        final invite = hub._invites[inviteId];
        if (invite == null) {
          throw FakeRpcError('invalid invite', PearErrorCode.invalidInvite);
        }
        if (invite.expiresAt != 0 &&
            DateTime.now().millisecondsSinceEpoch > invite.expiresAt) {
          throw FakeRpcError('invite expired', PearErrorCode.inviteExpired);
        }
        final timeoutMs = params['timeoutMs'] as int? ?? 30000;
        Uint8List? key;
        if (!invite.revoked) {
          final candidateId = _randomHex(8);
          final userData = params['userData'] != null
              ? base64Decode(params['userData'] as String)
              : Uint8List(0);
          final candidate = _FakePendingCandidate(userData);
          invite.pending[candidateId] = candidate;
          invite.owner._emitEvent(PearEventName.pairingCandidate, {
            'inviteId': inviteId,
            'candidateId': candidateId,
            'userData': base64Encode(userData),
          });
          key = await candidate.confirmed.future.timeout(
            Duration(milliseconds: timeoutMs),
            onTimeout: () => null,
          );
        } else {
          // Revoked: nobody is listening, so this waits out the SAME
          // bound with nothing to ever complete it -- matching a real
          // closed Member never responding at all.
          await Future<void>.delayed(Duration(milliseconds: timeoutMs));
        }
        if (key == null) {
          throw FakeRpcError('pairing timed out', PearErrorCode.pairingTimeout);
        }
        return {'key': base64Encode(key)};
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

  _FakeBase _requireBase(String keyHex) {
    final base = _bases[keyHex];
    if (base == null) {
      throw FakeRpcError('unknown base: $keyHex', PearErrorCode.unknownBase);
    }
    return base;
  }

  _FakeBase _requireOpenBase(String keyHex) {
    final base = _requireBase(keyHex);
    if (_closedBases.contains(keyHex)) {
      throw FakeRpcError('base is closed: $keyHex', PearErrorCode.baseClosed);
    }
    return base;
  }

  /// This worklet's own writer identity for the base keyed by [baseKeyHex]
  /// -- a real Autobase writer key (`base.local.key`) is namespaced
  /// per-base, so the SAME worklet must get a DIFFERENT writerKey for each
  /// distinct base it opens (unlike [peerKey], which is fixed per worklet).
  /// Deterministic in both inputs: the same worklet reopening the same base
  /// always derives the same writerKey, matching every other wrapper's
  /// deterministic-reopen convention.
  String _writerKeyFor(String baseKeyHex) =>
      PearCrypto.hash(utf8.encode('$peerKey:writer:$baseKeyHex')).hex;

  void _connectTo(FakeBareWorklet other, String topicHex) {
    final peerHex = other.peerKey;
    // isNew is scoped per (peer, topic) -- NOT per peer alone -- mirroring
    // pear-end/index.js's real `announce()` exactly: `t.connectedPeers` is
    // a PER-TOPIC Set (`topics.get(topicHex)`), so a peer already connected
    // via one shared topic still gets a fresh SWARM_CONNECTION + CONNECTED
    // for a SECOND topic it's discovered on afterward (Hyperswarm shares
    // one physical connection across every topic that finds it -- see
    // pear-end/index.js's own comment on `info.topics`/`info.on('topic',
    // ...)`). Set.add returns true only the first time topicHex is added
    // for this peer, giving exactly that per-(peer,topic) semantics.
    // Both the event AND the state gate on it (E6.5 conformance fix) so a
    // redundant FakeSwarmHub.join() call for an ALREADY-connected (peer,
    // topic) pair (e.g. a test simulating the OTHER peer's reconnect) never
    // emits a spurious extra CONNECTED transition for a side that was
    // never actually dropped.
    final isNew =
        _connectionTopics.putIfAbsent(peerHex, () => <String>{}).add(topicHex);
    _connections[peerHex] = other;
    if (isNew) {
      _everConnectedTopics.add(topicHex);
      _emitEvent(
          PearEventName.swarmConnection, {'topic': topicHex, 'peer': peerHex});
      _sendState(topicHex, PearSwarmState.connected);
    }
  }

  /// Simulates this peer disconnecting from [other] -- the in-memory
  /// equivalent of a real Hyperswarm connection ending. Emits
  /// [PearEventName.connectionClose] on this side only; call it on both
  /// sides to simulate a mutual disconnect, or one side only to simulate
  /// whichever peer detects the drop first. If this was the last peer THIS
  /// worklet was connected to on a shared, still-joined topic, also sends
  /// [PearSwarmState.reconnecting] for that topic (E6.5) -- mirrors
  /// pear-end/index.js's own `conn.on('close', ...)` handler exactly
  /// (`if (t.connectedPeers.size === 0) sendState(topicHex, RECONNECTING)`).
  /// A later [FakeSwarmHub.join]/[_connectTo] call for the same or a
  /// different peer on that topic re-emits [PearEventName.swarmConnection]
  /// + [PearSwarmState.connected] -- the same "ephemeral connection object,
  /// state reflects reconnecting->connected" contract the real worklet
  /// gives, matching this fake's own conformance-consumer mandate.
  void disconnectFrom(FakeBareWorklet other) {
    final peerHex = other.peerKey;
    if (_connections.remove(peerHex) == null) return;
    final topics = _connectionTopics.remove(peerHex) ?? const <String>{};
    for (final topicHex in topics) {
      // Both the event AND the reconnecting state gate on the SAME
      // still-joined check -- mirrors pear-end/index.js's conn.on('close',
      // ...) handler exactly (`const t = topics.get(topicHex); if (!t ||
      // ...) continue` skips BOTH the CONNECTION_CLOSE send and the
      // RECONNECTING state together once a topic has been left via
      // swarm.leave, which deletes it from `topics`). Without this check,
      // a topic already left via [FakeSwarmHub.leave] (which deliberately
      // leaves existing peer connections alone, per its own doc) would
      // still get a spurious connectionClose event the real worklet would
      // never send for it.
      if (!_joinedTopics.contains(topicHex)) continue;
      _emitEvent(
          PearEventName.connectionClose, {'topic': topicHex, 'peer': peerHex});
      final stillConnected =
          _connectionTopics.values.any((t) => t.contains(topicHex));
      if (!stillConnected) {
        _sendState(topicHex, PearSwarmState.reconnecting);
      }
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
  final SplayTreeMap<String, Uint8List> entries =
      SplayTreeMap<String, Uint8List>();
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

  /// Hostile symlink entries injected via [FailureInjection.injectDriveSymlink]
  /// (flutter_pear-ovt.2.8) -- virtual path -> the symlink's (never
  /// followed) target. `PearMethod.driveMirrorToDisk` rejects every one of
  /// these unconditionally, mirroring the real worklet's zip-slip
  /// hardening (flutter_pear-ovt.2.7).
  final Map<String, String> symlinks = {};

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

/// E5.6 -- one in-memory blind-pairing invite's worth of state, shared via
/// [FakeSwarmHub.invites] (see that field's doc for why this needs no
/// per-worklet merge machinery, unlike [_FakeCore]/[_FakeBee]/[_FakeDrive]).
class _FakeInvite {
  _FakeInvite(this.id, this.expiresAt, this.owner);

  final String id;

  /// Epoch milliseconds; 0 means never expires.
  final int expiresAt;

  /// The worklet that created this invite -- `PearMethod.pairingAcceptInvite`
  /// emits [PearEventName.pairingCandidate] on this one specifically.
  final FakeBareWorklet owner;

  /// Candidates awaiting `PearMethod.pairingConfirmCandidate`, by candidateId.
  final Map<String, _FakePendingCandidate> pending = {};

  /// Set by `PearMethod.pairingRevoke` -- see that case's handling for why
  /// this doesn't remove the invite outright.
  bool revoked = false;
}

/// One `PearMethod.pairingAcceptInvite` call waiting on
/// `PearMethod.pairingConfirmCandidate` -- [confirmed] completes with the
/// confirmed key, or is left incomplete forever if the invite is revoked or
/// nobody ever confirms (the accept side's own bounded timeout is what
/// turns that into a clean failure instead of a real hang, mirroring
/// blind-pairing's own unbounded polling loop -- see
/// `PearMethod.pairingAcceptInvite`'s handling).
class _FakePendingCandidate {
  _FakePendingCandidate(this.userData);

  final Uint8List userData;
  final Completer<Uint8List?> confirmed = Completer<Uint8List?>();
}

/// E5.8 -- one in-memory Autobase's worth of state, covering all three
/// [PearRecipe]s with the SAME class (dispatched on [recipe] by the
/// methods that touch it) since a base's identity/replication/writer-
/// admission mechanics are identical regardless of recipe -- only the
/// merge/materialization logic differs.
///
/// UNLIKE [_FakeCore]/[_FakeBee]/[_FakeDrive] (single writer; merging two
/// views throws unless one is a clean prefix/subset of the other -- see
/// [_isPrefix]/[_isSubsetWithMatchingValues]), a base is GENUINELY
/// multi-writer by design: two independently-evolved views are EXPECTED to
/// diverge and must merge, never be rejected. Each recipe's merge (see
/// [_mergeBases]) is a simple, always-safe operation (lww: highest-seq-wins
/// per key; orderedLog: sort-by-seq interleave; crdtMap: a plain OR-Set
/// union) -- there's no data-loss failure mode a `StateError` guard would
/// even need to catch here, unlike the single-writer wrappers' fakes.
///
/// Only the fields the open [recipe] actually uses are ever non-empty.
class _FakeBase {
  _FakeBase(this.keyHex, this.recipe);

  final String keyHex;
  final PearRecipe recipe;
  final Set<FakeBareWorklet> _owners = {};
  final List<_FakeBaseWatch> _watches = [];

  /// Admitted writers, by [FakeBareWorklet._writerKeyFor] -- a SET, unlike
  /// core/bee/drive's single immutable `writer` field, since a base can
  /// admit more than one (see `PearMethod.baseAppend`'s addWriter/
  /// removeWriter handling).
  final Set<String> writers = {};

  /// The subset of [writers] that also participate in quorum signing --
  /// mirrors the real recipes module's `{indexer}` flag on an addWriter op
  /// (default true unless explicitly `false`). Autobase itself refuses to
  /// remove the last remaining indexer; `PearMethod.baseAppend`'s
  /// removeWriter handling mirrors that refusal.
  final Set<String> indexers = {};

  /// Per-writer local append counter for THIS base -- mirrors the real
  /// crdtMap/lww recipes' use of `node.length` (a writer's own local
  /// sequence number, never comparable across DIFFERENT writers as a
  /// causal "happened later" signal -- see autobase-recipes.js's `isNewer`
  /// doc). Used (with a writer-key tiebreak on an exact tie) so a lww/
  /// crdtMap conflict resolves the SAME way regardless of which peer's
  /// test code happens to call append() first -- unlike a hub-wide
  /// call-order counter, which the real system has no equivalent of.
  final Map<String, int> writerSeq = {};

  /// lww only: key hex -> current entry. `seq`/`writer` are this entry's
  /// author's OWN local seq (see [writerSeq]) -- never a hub-wide counter.
  final Map<String, ({Uint8List? value, bool deleted, int seq, String writer})>
      lwwEntries = {};

  /// orderedLog only: every entry ever appended, tagged with the hub-wide
  /// seq it was applied at (see [FakeSwarmHub._nextBaseOpSeq]) so two
  /// independently-grown logs can be merged into one deterministic order.
  /// Unlike lww/crdtMap, exact interleave order isn't part of this
  /// recipe's real contract (only the merged SET of entries is), so a
  /// hub-wide counter is a fine stand-in here.
  final List<({Uint8List entry, int seq})> log = [];

  /// crdtMap only: key hex -> {tag -> value}, mirroring the real recipe's
  /// OR-Set-of-(tag,value)-per-key shape. Tags are `'writer:localSeq'`
  /// (see [writerSeq]), matching the real recipe's `writerHex:node.length`
  /// exactly.
  final Map<String, Map<String, Uint8List>> crdtTags = {};

  /// crdtMap only: every tag ever removed, hub-wide -- checked before any
  /// tag is allowed to (re)appear in [crdtTags], same reorder-safety
  /// rationale as the real recipe's tombstone check.
  final Set<String> crdtTombstones = {};

  void _notify() {
    for (final w in _watches.toList()) {
      w.owner._emitEvent(
          PearEventName.baseUpdate, {'base': keyHex, 'watch': w.watchId});
    }
  }
}

/// E5.8 -- one outstanding `PearMethod.baseWatch` subscription.
class _FakeBaseWatch {
  _FakeBaseWatch(this.owner, this.watchId, this.base);

  final FakeBareWorklet owner;
  final String watchId;

  /// Mutable, not final -- a `PearMethod.baseReplicate` merge repoints
  /// this to the canonical object (see that handling above), same
  /// rationale as [_FakeBeeWatch.bee].
  _FakeBase base;
}

/// A crdtMap tag (`'writer:localSeq'`) split into its parts -- see
/// [_FakeBase.crdtTags]'s doc.
({String writer, int seq}) _parseTag(String tag) {
  final sep = tag.lastIndexOf(':');
  return (
    writer: tag.substring(0, sep),
    seq: int.parse(tag.substring(sep + 1))
  );
}

/// Whether tag [a] is the canonical pick over tag [b] among an
/// already-converged, still-live set of crdtMap tags for the same key --
/// mirrors autobase-recipes.js's `isNewer` EXACTLY (higher writer-LOCAL seq
/// wins; an exact tie breaks on the writer's own hex string, greater wins)
/// so the fake picks the same representative the real recipe would for the
/// identical writer-history, regardless of which peer's test code happens
/// to call append() first (see [_FakeBase.writerSeq]'s doc for why that
/// matters).
bool _tagIsNewer(String a, String b) {
  final pa = _parseTag(a), pb = _parseTag(b);
  if (pa.seq != pb.seq) return pa.seq > pb.seq;
  return pa.writer.compareTo(pb.writer) > 0;
}

/// A cheap proxy for "how much data does this base hold", used only to
/// decide whether a merge actually changed anything (see
/// `PearMethod.baseReplicate`'s handling) -- same "did the count change"
/// precision level as coreReplicate/beeReplicate's own change-detection, not
/// a full content diff (an update that replaces an existing lww/crdtMap
/// entry's VALUE without changing the entry count would be missed, same
/// caveat those wrappers already accept).
int _baseDataSize(_FakeBase b) {
  switch (b.recipe) {
    case PearRecipe.lww:
      return b.lwwEntries.length;
    case PearRecipe.orderedLog:
      return b.log.length;
    case PearRecipe.crdtMap:
      return b.crdtTags.values.fold(0, (n, tags) => n + tags.length) +
          b.crdtTombstones.length;
  }
}

/// Merges two independently-evolved views of the SAME base into one
/// canonical object -- see [_FakeBase]'s own doc for why this is always
/// safe (a plain union/interleave, never a "does one subsume the other"
/// check).
_FakeBase _mergeBases(_FakeBase a, _FakeBase b) {
  final canonical = _FakeBase(a.keyHex, a.recipe)
    ..writers.addAll(a.writers)
    ..writers.addAll(b.writers)
    ..indexers.addAll(a.indexers)
    ..indexers.addAll(b.indexers);

  // Each writer's own local counter only ever grows -- take the max either
  // side has observed for it, so an append after this merge continues from
  // the right point instead of restarting at 0 (see writerSeq's doc).
  for (final side in [a.writerSeq, b.writerSeq]) {
    for (final e in side.entries) {
      final existing = canonical.writerSeq[e.key];
      if (existing == null || e.value > existing) {
        canonical.writerSeq[e.key] = e.value;
      }
    }
  }

  switch (a.recipe) {
    case PearRecipe.lww:
      for (final entry in [...a.lwwEntries.entries, ...b.lwwEntries.entries]) {
        final existing = canonical.lwwEntries[entry.key];
        if (existing == null ||
            entry.value.seq > existing.seq ||
            (entry.value.seq == existing.seq &&
                entry.value.writer.compareTo(existing.writer) > 0)) {
          canonical.lwwEntries[entry.key] = entry.value;
        }
      }
    case PearRecipe.orderedLog:
      final merged = [...a.log, ...b.log]
        ..sort((x, y) => x.seq.compareTo(y.seq));
      canonical.log.addAll(merged);
    case PearRecipe.crdtMap:
      canonical.crdtTombstones
        ..addAll(a.crdtTombstones)
        ..addAll(b.crdtTombstones);
      for (final entry in [...a.crdtTags.entries, ...b.crdtTags.entries]) {
        final tags = canonical.crdtTags.putIfAbsent(entry.key, () => {});
        tags.addAll(entry.value);
      }
      for (final tags in canonical.crdtTags.values) {
        tags.removeWhere((tag, _) => canonical.crdtTombstones.contains(tag));
      }
  }
  return canonical;
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
