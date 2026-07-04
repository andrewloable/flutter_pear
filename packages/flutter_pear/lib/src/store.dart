import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'rpc.dart';
import 'schema.dart';
import 'swarm.dart';

/// Opens append-only [PearCore] logs backed by the worklet's Corestore
/// (E5.2) — wrapper 1 of 5 in the data-structure family ([PearBee],
/// [PearDrive], [PearBase] follow on top of this substrate).
///
/// Reachable via `Pear.store`; nothing about opening the underlying
/// Corestore itself is async — it's already running inside the worklet by
/// the time [Pear.start] returns.
///
/// ```dart
/// final pear = await Pear.start();
/// final core = await pear.store.get(name: 'my-log');
/// await core.append([utf8.encode('hello')]);
/// print(await core.get(0)); // the appended block
/// ```
class PearStore {
  /// Wraps `rpc`. Prefer `Pear.store` over constructing this directly.
  PearStore(this._rpc);

  final PearRpc _rpc;

  /// Opens the core known locally as [name] (creating it on first use), or
  /// attaches to an existing core by its public [key] — exactly one of
  /// [name]/[key] must be given.
  ///
  /// A core opened by [key] that hasn't replicated any data yet (see
  /// [PearCore.replicate]) starts at [PearCore.length] 0, same as a brand
  /// new local core — Corestore itself doesn't distinguish the two until
  /// data actually arrives.
  Future<PearCore> get({String? name, PearKey? key}) async {
    assert((name == null) != (key == null),
        'PearStore.get needs exactly one of name/key');
    final result = await _rpc.call(PearMethod.storeGet, {
      if (name != null) 'name': name,
      if (key != null) 'key': key.hex,
    }) as Map;
    return PearCore._(
      _rpc,
      PearKey.fromHex(result['key'] as String),
      result['length'] as int,
    );
  }
}

/// One append-only Hypercore log opened via [PearStore.get].
///
/// `Future`s for calls, a broadcast [updates] stream for watch semantics —
/// matching every other Pear wrapper's shape.
class PearCore {
  PearCore._(this._rpc, this.key, int initialLength) : _length = initialLength {
    _eventSub = _rpc.events.listen((e) {
      if (e.name != PearEventName.coreUpdate) return;
      final p = e.payload;
      if (p is! Map || p['key'] != key.hex) return;
      _length = p['length'] as int;
      _updates.add(_length);
    });
  }

  final PearRpc _rpc;

  /// This core's public key.
  final PearKey key;

  int _length;
  final StreamController<int> _updates = StreamController<int>.broadcast();
  late final StreamSubscription<PearEvent> _eventSub;

  /// The number of blocks appended so far, as of the last known update —
  /// reflects both local [append]s and blocks received via [replicate]. Read
  /// this first if you need the length before subscribing to [updates]: like
  /// [PearSwarm.currentState], a plain broadcast stream can't replay a past
  /// event to a late listener.
  int get length => _length;

  /// Fires the new [length] every time a block is appended — locally, or
  /// received from a replicating peer.
  Stream<int> get updates => _updates.stream;

  /// Appends [blocks] and returns the new length.
  ///
  /// Throws with [PearErrorCode.coreClosed] if [close] already ran.
  Future<int> append(List<Uint8List> blocks) async {
    final result = await _rpc.call(PearMethod.coreAppend, {
      'key': key.hex,
      'data': [for (final b in blocks) base64Encode(b)],
    }) as Map;
    return result['length'] as int;
  }

  /// Returns the block at [index].
  ///
  /// Throws with [PearErrorCode.indexOutOfRange] if [index] is at or past
  /// [length], or [PearErrorCode.coreClosed] if [close] already ran.
  Future<Uint8List> get(int index) async {
    final result = await _rpc.call(PearMethod.coreGet, {
      'key': key.hex,
      'index': index,
    }) as Map;
    return base64Decode(result['data'] as String);
  }

  /// Replicates this core over [connection] — call on both peers so each
  /// side's writes reach the other. [connection] must already be open (see
  /// [PearSwarm.connections]).
  Future<void> replicate(PearConnection connection) => _rpc.call(
        PearMethod.coreReplicate,
        {'key': key.hex, 'peer': connection.remotePublicKey.hex},
      );

  /// Closes this core. Further [append]/[get]/[replicate] calls fail with
  /// [PearErrorCode.coreClosed].
  Future<void> close() async {
    await _rpc.call(PearMethod.coreClose, {'key': key.hex});
    await _eventSub.cancel();
    await _updates.close();
  }
}
