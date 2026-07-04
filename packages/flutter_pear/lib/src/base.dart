import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'crypto.dart';
import 'rpc.dart';
import 'schema.dart';
import 'swarm.dart';

/// The result of [PearBase.get] — lww/crdtMap only (see that method's doc).
typedef PearBaseGetResult = ({bool exists, Uint8List? value});

/// An Autobase multi-writer data structure opened via [PearBase.open]
/// (E5.8) — wrapper 5 of 5 in the data-structure family, and the only one
/// backed by a NAMED merge recipe rather than a raw Corestore substrate.
///
/// LOCKED (project decision, "codex #2"): there is no generic Dart-driven
/// open/apply here — a custom worklet with its own hand-written Autobase
/// wiring is a documented advanced path only
/// (`BareWorklet.start(customBundle)`). [open] instead picks one of the
/// built-in [PearRecipe]s (pear-end's own recipes module, E5.7), each with
/// its own guaranteed convergence behavior:
///
/// - [PearRecipe.lww] — a last-writer-wins `key -> value` map. Use
///   [put]/[del]/[get].
/// - [PearRecipe.orderedLog] — an append-only merged log. Use
///   [append]/[range].
/// - [PearRecipe.crdtMap] — an add-wins observed-remove `key -> value` map
///   (a concurrent, not-yet-observed put survives a delete). Use
///   [put]/[del]/[get] — [del]'s "which tags have I observed" bookkeeping
///   happens entirely in the worklet; nothing here has to read state first.
///
/// [put]/[del]/[get] only make sense for [PearRecipe.lww]/
/// [PearRecipe.crdtMap]; [append]/[range] only for [PearRecipe.orderedLog].
/// Calling [put]/[del]/[append]/[addWriter]/[removeWriter] with the wrong
/// shape for this base's recipe fails synchronously with
/// [PearErrorCode.malformedOp] — pear-end validates op shape before ever
/// appending. [get]/[range] are plain reads, not appended ops, so calling
/// the wrong one for this base's recipe instead fails with a generic
/// `PearStorageException` (no specific [PearErrorCode]).
class PearBase {
  PearBase._(this._rpc, this.key, this.recipe, this.writerKey);

  final PearRpc _rpc;

  /// This base's public key — share it so another peer can [open] the SAME
  /// base by `key` and, once [addWriter] admits them, write to it too.
  final PearKey key;

  /// Which merge recipe this base was opened with.
  final PearRecipe recipe;

  /// THIS worklet generation's own local writer identity for this base —
  /// share it (out of band, e.g. over a `PearPairing` confirm) with a peer
  /// you want to admit, so THEY can pass it to their own [addWriter].
  /// Distinct from [key]: [key] identifies the base itself (the same for
  /// everyone), [writerKey] identifies YOU as one of its writers.
  final PearKey writerKey;

  /// Opens the Autobase known locally as [name] (creating it on first use,
  /// as the sole initial writer), or attaches to an existing one by its
  /// public [key] — exactly one of [name]/[key] must be given, same
  /// contract as `PearStore.get`. [recipe] is required even when
  /// reattaching by [key]: the worklet has no other way to know which
  /// recipe's open/apply pair to construct this generation's Autobase
  /// instance with (see pear-end's recipes module for why that can't be
  /// discovered from the key alone). Prefer `Pear.base` over calling this
  /// directly.
  static Future<PearBase> open(
    PearRpc rpc, {
    required PearRecipe recipe,
    String? name,
    PearKey? key,
  }) async {
    assert((name == null) != (key == null),
        'PearBase.open needs exactly one of name/key');
    final result = await rpc.call(PearMethod.baseOpen, {
      'recipe': recipe.name,
      if (name != null) 'name': name,
      if (key != null) 'key': key.hex,
    }) as Map;
    return PearBase._(
      rpc,
      PearKey.fromHex(result['key'] as String),
      recipe,
      PearKey.fromHex(result['writerKey'] as String),
    );
  }

  /// Replicates this base's underlying cores over [connection] — call on
  /// both peers, same contract as `PearCore.replicate`/`PearBee.replicate`/
  /// `PearDrive.replicate` (watching or appending alone never moves bytes;
  /// this is what lets another writer's ops ever reach this peer).
  Future<void> replicate(PearConnection connection) => _rpc.call(
        PearMethod.baseReplicate,
        {'base': key.hex, 'peer': connection.remotePublicKey.hex},
      );

  Future<void> _append(Map<String, Object?> value) =>
      _rpc.call(PearMethod.baseAppend, {'base': key.hex, 'value': value});

  /// Writes [value] at [key] — [PearRecipe.lww]/[PearRecipe.crdtMap] only.
  /// Overwrites any existing value; for [PearRecipe.crdtMap] a concurrent
  /// put on another writer that hasn't observed this one survives instead
  /// (see this class's own doc).
  Future<void> put(Uint8List key, Uint8List value) => _append({
        'type': 'put',
        'key': base64Encode(key),
        'value': base64Encode(value),
      });

  /// Deletes [key] — [PearRecipe.lww]/[PearRecipe.crdtMap] only. A no-op,
  /// not an error, if [key] isn't present. For [PearRecipe.crdtMap] this
  /// removes only the values THIS worklet generation has currently
  /// observed for [key] (computed server-side at append time) — a
  /// concurrent put neither side has seen yet still survives.
  Future<void> del(Uint8List key) => _append({
        'type': 'del',
        'key': base64Encode(key),
      });

  /// Reads the current materialized value for [key], or
  /// `(exists: false, value: null)` if never put (or, for
  /// [PearRecipe.crdtMap], every put's tag has since been deleted) —
  /// [PearRecipe.lww]/[PearRecipe.crdtMap] only.
  Future<PearBaseGetResult> get(Uint8List key) async {
    final result = await _rpc.call(
        PearMethod.baseGet, {'base': this.key.hex, 'key': base64Encode(key)}) as Map;
    return (
      exists: result['exists'] == true,
      value: result['exists'] == true
          ? base64Decode(result['value'] as String)
          : null,
    );
  }

  /// Appends [entry] to the merged log — [PearRecipe.orderedLog] only.
  Future<void> append(Uint8List entry) =>
      _append({'entry': base64Encode(entry)});

  /// Reads log entries `[start, end)` (default: the whole log) as a single
  /// bounded snapshot — [PearRecipe.orderedLog] only. Same
  /// bounded-snapshot-not-a-live-view caveat as `PearBee.range`/
  /// `PearDrive.list`; see [watch] for live change notifications.
  Stream<Uint8List> range({int? start, int? end}) async* {
    final result = await _rpc.call(PearMethod.baseRange, {
      'base': key.hex,
      if (start != null) 'start': start,
      if (end != null) 'end': end,
    }) as Map;
    for (final entry in result['entries'] as List) {
      yield base64Decode(entry as String);
    }
  }

  /// Fires whenever this base's merged view changes — a live notification,
  /// unlike [range]'s one-shot snapshot. Carries no payload; re-read via
  /// [get]/[range] to see what changed. Same subscribe-lifecycle contract
  /// as `PearBee.watch` (the underlying worklet subscription starts on the
  /// first listener and stops when the last one cancels; a fresh watchId is
  /// generated every listen cycle, not once per [watch] call, for the same
  /// stale-unwatch-race reason documented on `PearBee.watch`).
  Stream<void> watch() {
    late final StreamController<void> controller;
    String? watchId;
    StreamSubscription<PearEvent>? sub;
    controller = StreamController<void>.broadcast(
      onListen: () {
        final id = _randomWatchId();
        watchId = id;
        sub = _rpc.events.listen((e) {
          if (e.name != PearEventName.baseUpdate) return;
          final p = e.payload;
          if (p is Map && p['base'] == key.hex && p['watch'] == id) {
            controller.add(null);
          }
        });
        _rpc.call(PearMethod.baseWatch, {'base': key.hex, 'watch': id}).catchError(
            (Object error) {
          controller.addError(error);
          return null;
        });
      },
      onCancel: () async {
        final id = watchId;
        await sub?.cancel();
        if (id == null) return;
        try {
          await _rpc.call(PearMethod.baseUnwatch, {'base': key.hex, 'watch': id});
        } catch (_) {
          // Best-effort -- see PearBee.watch's identical doc for why.
        }
      },
    );
    return controller.stream;
  }

  /// Admits [key] as a new writer on this base — the counterpart shares
  /// their own base's local writer key with you (out of band, e.g. via
  /// `PearPairing`) and you call this with it. [indexer] controls whether
  /// the new writer also participates in quorum signing (default `true`;
  /// see pear-end's Autobase usage for what that gates).
  Future<void> addWriter(PearKey key, {bool indexer = true}) => _append({
        'addWriter': key.hex,
        'indexer': indexer,
      });

  /// Removes [key] as a writer on this base. Autobase itself refuses to
  /// remove the last remaining indexer — pear-end registers an error
  /// handler on this base specifically so that refusal closes just THIS
  /// base (same effect as [close]) instead of crashing the whole worklet
  /// (Autobase's own default with no listener). This call itself may
  /// resolve successfully or reject depending on timing (the refusal can
  /// surface after this call's own append already completed), but every
  /// subsequent call on this base fails with [PearErrorCode.baseClosed]
  /// either way — avoid removing the last remaining writer.
  Future<void> removeWriter(PearKey key) => _append({'removeWriter': key.hex});

  /// Closes this base. Also stops every outstanding [watch] on it. Further
  /// [put]/[del]/[get]/[append]/[range]/[watch] calls fail with
  /// [PearErrorCode.baseClosed].
  Future<void> close() => _rpc.call(PearMethod.baseClose, {'base': key.hex});
}

String _randomWatchId() {
  final random = Random();
  return List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'))
      .join();
}
