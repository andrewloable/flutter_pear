import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';
import 'rpc.dart';
import 'schema.dart';
import 'swarm.dart';

/// One entry read from [PearBee.range] — a snapshot key/value pair, not a
/// live view (see [PearBee.range]'s doc).
typedef PearBeeEntry = ({Uint8List key, Uint8List value});

/// A Hyperbee key/value store opened via [PearBee.open] (E5.3) — wrapper 2
/// of 5 in the data-structure family, built on the same Corestore substrate
/// as [PearStore]/[PearCore] (E5.2).
///
/// `Future`s for point calls, a bounded [range] `Stream`, and a live
/// [watch] broadcast `Stream` — matching every other Pear wrapper's shape.
class PearBee {
  PearBee._(this._rpc, this.key);

  final PearRpc _rpc;

  /// This bee's public key (its underlying core's key).
  final PearKey key;

  /// Opens the bee known locally as [name] (creating it on first use), or
  /// attaches to an existing bee by its public [key] — exactly one of
  /// [name]/[key] must be given, same contract as `PearStore.get`. Prefer
  /// `Pear.bee` over calling this directly.
  static Future<PearBee> open(
    PearRpc rpc, {
    String? name,
    PearKey? key,
  }) async {
    assert((name == null) != (key == null),
        'PearBee.open needs exactly one of name/key');
    final result = await rpc.call(PearMethod.beeOpen, {
      if (name != null) 'name': name,
      if (key != null) 'key': key.hex,
    }) as Map;
    return PearBee._(rpc, PearKey.fromHex(result['key'] as String));
  }

  /// Reads the value at [key], or `null` if [key] isn't present.
  Future<Uint8List?> get(Uint8List key) async {
    final result = await _rpc.call(
        PearMethod.beeGet, {'bee': this.key.hex, 'key': base64Encode(key)}) as Map;
    return result['found'] == true
        ? base64Decode(result['value'] as String)
        : null;
  }

  /// Writes [value] at [key], overwriting any existing value.
  Future<void> put(Uint8List key, Uint8List value) => _rpc.call(
        PearMethod.beePut,
        {'bee': this.key.hex, 'key': base64Encode(key), 'value': base64Encode(value)},
      );

  /// Deletes [key]. A no-op, not an error, if [key] isn't present.
  Future<void> del(Uint8List key) =>
      _rpc.call(PearMethod.beeDel, {'bee': this.key.hex, 'key': base64Encode(key)});

  /// Replicates this bee's underlying core over [connection] — call on both
  /// peers, same contract as `PearCore.replicate` (watching alone never
  /// moves bytes; this is what lets a peer's [put]/[del] ever reach the
  /// other side).
  Future<void> replicate(PearConnection connection) => _rpc.call(
        PearMethod.beeReplicate,
        {'bee': key.hex, 'peer': connection.remotePublicKey.hex},
      );

  /// Reads every entry within the given bounds as a single bounded
  /// snapshot, taken at the moment this call reaches the worklet — NOT a
  /// live view (see [watch] for that). The whole range is fetched in one
  /// request/response round trip and buffered before this `Stream` starts
  /// emitting; fine for a KV range, but a very large one inflates through
  /// JSON/base64 like any other control-plane call until a real streaming
  /// primitive lands (M3) — see `PearConnection.write`'s similar note.
  Stream<PearBeeEntry> range({
    Uint8List? gt,
    Uint8List? gte,
    Uint8List? lt,
    Uint8List? lte,
    bool reverse = false,
    int? limit,
  }) async* {
    final result = await _rpc.call(PearMethod.beeRange, {
      'bee': key.hex,
      if (gt != null) 'gt': base64Encode(gt),
      if (gte != null) 'gte': base64Encode(gte),
      if (lt != null) 'lt': base64Encode(lt),
      if (lte != null) 'lte': base64Encode(lte),
      if (reverse) 'reverse': true,
      if (limit != null) 'limit': limit,
    }) as Map;
    for (final entry in result['entries'] as List) {
      final e = entry as Map;
      yield (
        key: base64Decode(e['key'] as String),
        value: base64Decode(e['value'] as String),
      );
    }
  }

  /// Fires whenever an entry within the given bounds changes — a live
  /// notification, unlike [range]'s one-shot snapshot. Carries no payload;
  /// re-read via [get]/[range] to see what changed. The underlying worklet
  /// subscription starts when the first listener attaches and stops when
  /// the last one cancels (broadcast semantics); a subsequent re-listen
  /// (all listeners cancel, then a new one attaches) starts a genuinely new
  /// worklet-side watch with its own id — see [onListen]'s `watchId`
  /// generation below for why that matters.
  Stream<void> watch({
    Uint8List? gt,
    Uint8List? gte,
    Uint8List? lt,
    Uint8List? lte,
  }) {
    late final StreamController<void> controller;
    String? watchId;
    StreamSubscription<PearEvent>? sub;
    controller = StreamController<void>.broadcast(
      onListen: () {
        // Generated fresh on EVERY listen cycle, not once per watch() call
        // (E5.3 review fix): a cancel-then-relisten on this same Stream
        // (listener count 1->0->1, e.g. a rebuilt widget) fires onCancel
        // then onListen in that order, but onCancel's own beeUnwatch call
        // is NOT awaited by subscription.cancel() (see onCancel's doc) --
        // it can still be in flight when this onListen runs. Reusing one
        // id across cycles would let that stale, still-in-flight unwatch
        // land AFTER this fresh watch's ack and kill it instead (pear-end's
        // BEE_WATCH would have already overwritten its own registry entry
        // for that id with THIS cycle's watcher). A fresh id per cycle
        // means the stale unwatch can only ever match its own,
        // already-superseded entry.
        final id = _randomWatchId();
        watchId = id;
        sub = _rpc.events.listen((e) {
          if (e.name != PearEventName.beeUpdate) return;
          final p = e.payload;
          if (p is Map && p['bee'] == key.hex && p['watch'] == id) {
            controller.add(null);
          }
        });
        // Not awaited -- onListen itself must return synchronously -- but
        // routed to the controller as an error rather than left as an
        // unhandled Future rejection (e.g. BEE_CLOSED if the bee closed
        // between open() and watch(), or WORKLET_DISPOSED in a racing
        // teardown): a caller with no Future to inspect here should still
        // learn a watch never actually started, via the same Stream it's
        // already listening to.
        _rpc.call(PearMethod.beeWatch, {
          'bee': key.hex,
          'watch': id,
          if (gt != null) 'gt': base64Encode(gt),
          if (gte != null) 'gte': base64Encode(gte),
          if (lt != null) 'lt': base64Encode(lt),
          if (lte != null) 'lte': base64Encode(lte),
        }).catchError((Object error) {
          controller.addError(error);
          return null;
        });
      },
      onCancel: () async {
        // Captured before any `await` -- a subsequent onListen (see its
        // doc above) reassigns the outer `watchId` the moment this
        // continuation's first `await` yields, so reading it again after
        // that point would send THIS cycle's unwatch under the NEXT
        // cycle's id instead of its own.
        final id = watchId;
        await sub?.cancel();
        if (id == null) return;
        // A broadcast StreamController's onCancel is NOT awaited by
        // subscription.cancel() -- it runs detached, so nothing here has a
        // caller left to report a failure to (e.g. WORKLET_DISPOSED, if
        // dispose() races this cancel). Best-effort: if the worklet is
        // already gone or the bee already closed, there's nothing left to
        // unwatch anyway.
        try {
          await _rpc.call(PearMethod.beeUnwatch, {'bee': key.hex, 'watch': id});
        } catch (_) {
          // Deliberately swallowed -- see comment above.
        }
      },
    );
    return controller.stream;
  }

  /// Closes this bee. Also stops every outstanding [watch] on it. Further
  /// [get]/[put]/[del]/[range]/[watch] calls fail with
  /// [PearErrorCode.beeClosed].
  Future<void> close() => _rpc.call(PearMethod.beeClose, {'bee': key.hex});
}

String _randomWatchId() {
  final random = Random();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}
