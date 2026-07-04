import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/services.dart';

/// Lifecycle state of a [BareWorklet].
enum WorkletState {
  /// Not started, or terminated.
  stopped,

  /// Running and able to send/receive IPC frames.
  running,

  /// Paused via [BareWorklet.suspend]; resumable with [BareWorklet.resume].
  suspended,
}

/// A worklet's own report that it's gone (or about to be): a short `reason`
/// category, plus `detail` (a message/stack) when the worklet managed to
/// self-report before dying -- null for the native-only backstop signal,
/// which knows only that the worklet's IPC ended, not why.
typedef WorkletCrash = ({String reason, String? detail});

/// The minimal binary-frame transport `PearRpc` needs from a worklet: send a
/// frame, receive a stream of frames, and observe if it dies unexpectedly.
///
/// [BareWorklet] implements this against a real Bare Kit worklet;
/// `flutter_pear_test`'s in-memory fake (E3) implements it without one, so
/// higher layers (`PearRpc`, `PearSwarm`, …) can be built and tested against
/// either.
abstract interface class WorkletIpc {
  /// Frames emitted by the other side.
  Stream<Uint8List> get incoming;

  /// Sends one binary frame.
  Future<void> send(Uint8List frame);

  /// Fires when the worklet's native side detects it's gone without an
  /// explicit `terminate()` call -- e.g. bare-kit's own IPC pipe ending
  /// unexpectedly. This is a low-level, detail-free backstop: most crashes
  /// (a JS exception the worklet catches on its own way down) are reported
  /// with real detail as an ordinary event over [incoming] instead -- see
  /// `PearRpc`'s handling of `PearEventName.workletCrash`.
  Stream<WorkletCrash> get onCrash;
}

/// A running Bare runtime worklet and the binary IPC pipe to it.
///
/// This is the low-level surface — [start] / [terminate] / [suspend] /
/// [resume] plus [send] and the [incoming] byte-frame stream. High-level Pear
/// APIs (PearSwarm, PearStore, …) in the `flutter_pear` package are built on
/// top of this.
///
/// One worklet per app. [start] is hot-restart-safe: after a Dart hot restart
/// the native worklet keeps running and [start] reattaches to it.
///
/// Most app code never touches this directly — `package:flutter_pear`'s
/// `Pear.start()` wraps it with the RPC contract, typed errors, and every
/// data-structure wrapper. This is the raw byte-frame transport underneath:
///
/// ```dart
/// final worklet = await BareWorklet.start();
/// worklet.incoming.listen((frame) => print('frame: $frame'));
/// worklet.onCrash.listen((crash) => print('crashed: ${crash.reason}'));
/// await worklet.send(myFrame);
/// // ... later
/// await worklet.terminate();
/// ```
class BareWorklet implements WorkletIpc {
  BareWorklet._();

  /// Lifecycle control (start/terminate/suspend/resume) -- and, in the
  /// other direction, the native side's `onWorkletExit` crash backstop (see
  /// [onCrash]).
  static const MethodChannel _control =
      MethodChannel('flutter_pear_bare/control');

  /// Bidirectional binary frames to/from the worklet, as raw `Uint8List`
  /// via [StandardMessageCodec] -- NOT [BinaryCodec]/`ByteBuffer`, which
  /// silently delivers empty data on native-to-Dart sends on this
  /// Flutter/Android combination (reproduced with a minimal hardcoded
  /// buffer; matches the long-standing flutter/flutter#19849 class of
  /// engine bug). StandardMessageCodec's byte[]<->Uint8List encoding is
  /// well-tested both directions; the extra type-tag byte is negligible
  /// overhead for these small control-plane frames.
  static const BasicMessageChannel<Object?> _ipc =
      BasicMessageChannel('flutter_pear_bare/ipc', StandardMessageCodec());

  static BareWorklet? _instance;

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  final StreamController<WorkletCrash> _crash =
      StreamController<WorkletCrash>.broadcast();
  WorkletState _state = WorkletState.stopped;
  bool _reattached = false;

  // The native side's id for the CURRENTLY RUNNING worklet process/IPC pair
  // (bumped there on every fresh boot, unchanged across a reattach) --
  // native echoes it back on [_onControlCall]'s `onWorkletExit` so this
  // instance can tell a genuine exit of ITS OWN worklet apart from a stale
  // straggler about some earlier generation (flutter_pear-3vh). Null if
  // native didn't supply one (an older native build, or a fake/mock in
  // tests) -- [_onControlCall] then falls back to the pre-3vh behavior of
  // trusting every call, unchanged.
  int? _generationId;

  // Bytes received but not yet resolved into a complete frame -- see
  // _onIpc's doc for why this accumulator exists at all.
  Uint8List _pending = Uint8List(0);

  /// Current lifecycle state.
  WorkletState get state => _state;

  /// Whether [start] reattached to an already-running native worklet (a
  /// Dart hot restart) rather than booting a fresh one (E6.3) — the native
  /// side is the only place this distinction can be observed (both cases
  /// look identical from Dart otherwise), which is why `Pear.start`'s
  /// attach.info health probe needs this exposed: a short timeout only
  /// makes sense against a possibly-already-running worklet, never against
  /// one known to have just cold-booted (real JS engine + native module
  /// init legitimately takes real time).
  bool get reattached => _reattached;

  /// Frames emitted by the worklet (its `IPC.write` on the pear-end side).
  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  /// The native-detected "worklet is gone" backstop -- see [WorkletIpc.onCrash].
  @override
  Stream<WorkletCrash> get onCrash => _crash.stream;

  /// Starts the worklet from the bundled pear-end, or from [bundlePath] if given.
  ///
  /// Returns the singleton worklet. Calling it again while one is already
  /// running returns the existing instance (and, across a hot restart,
  /// reattaches to the still-running native worklet rather than spawning a
  /// second one).
  static Future<BareWorklet> start({String? bundlePath}) async {
    final existing = _instance;
    if (existing != null && existing._state != WorkletState.stopped) {
      return existing;
    }
    final w = BareWorklet._();
    _instance = w;
    _ipc.setMessageHandler(w._onIpc);
    _control.setMethodCallHandler(w._onControlCall);
    final result = await _control.invokeMethod<Map<Object?, Object?>>(
        'start', {'bundlePath': bundlePath});
    w._reattached = result?['reattached'] == true;
    w._generationId = result?['generationId'] as int?;
    w._state = WorkletState.running;
    return w;
  }

  /// Resolves incoming bytes into complete frames using the 4-byte
  /// big-endian length prefix [send] stamps on every write (mirrored by
  /// pear-end's own `send`/`IPC.on('data', ...)` in index.js).
  ///
  /// Required because the underlying transport is a byte stream, not a
  /// message queue: nothing guarantees one native `IPC.write()` arrives as
  /// exactly one `_onIpc` call. Under rapid consecutive writes (confirmed
  /// with a 5-write burst during E4.4's real Hyperswarm join work -- the
  /// first traffic pattern dense enough to ever trigger it), multiple
  /// frames can coalesce into a single delivery, or one frame can split
  /// across more than one; without a length prefix, the receiver has no
  /// way to find the boundary and `jsonDecode` fails on the mashed-together
  /// bytes. [_pending] carries any leftover partial frame across calls.
  Future<Object?> _onIpc(Object? message) async {
    if (message is! Uint8List) return null;
    if (_pending.isEmpty) {
      _pending = message;
    } else {
      final combined = Uint8List(_pending.length + message.length)
        ..setRange(0, _pending.length, _pending)
        ..setRange(_pending.length, _pending.length + message.length, message);
      _pending = combined;
    }
    while (_pending.length >= 4) {
      final frameLength =
          ByteData.sublistView(_pending, 0, 4).getUint32(0, Endian.big);
      if (_pending.length < 4 + frameLength) break; // frame not fully here yet
      _incoming.add(Uint8List.sublistView(_pending, 4, 4 + frameLength));
      _pending = Uint8List.sublistView(_pending, 4 + frameLength);
    }
    return null; // no reply; frames flow through [incoming]
  }

  /// Handles native-initiated control-channel calls -- currently just
  /// `onWorkletExit`, the E2.6 crash backstop (see [onCrash]). The worklet
  /// is already gone by the time this fires (bare-kit has no
  /// exit/crash callback to hook -- see FlutterPearBarePlugin.kt's doc
  /// comment), so this tears down the same way [terminate] would, minus the
  /// now-pointless native `terminate` call.
  Future<void> _onControlCall(MethodCall call) async {
    if (call.method != 'onWorkletExit') return;
    // Defensive: nothing in the native plugin fires this twice for one
    // worklet generation today (relayFromWorklet's read loop never re-arms
    // after reporting an exit), but a second call landing here regardless
    // must not double-close already-closed streams.
    if (_state == WorkletState.stopped) return;
    final args = call.arguments as Map;
    // flutter_pear-3vh: _control is a STATIC MethodChannel shared across
    // every BareWorklet generation, and Flutter buffers a channel message
    // that arrives with no handler currently registered, replaying it to
    // whichever handler is registered next -- so a stale generation's
    // onWorkletExit call, delayed in flight past a kill+restart
    // (Pear.start's version-mismatch path), could otherwise reach a brand
    // new, healthy worklet's handler instead of being dropped. Native
    // stamps the generation id it captured at the moment it detected THIS
    // exit (see FlutterPearBarePlugin.kt's reportUnexpectedExit) -- if it
    // doesn't match ours, this call is about some earlier generation, not
    // us; drop it silently, same as any other stale-generation message.
    final callGeneration = args['generationId'] as int?;
    if (_generationId != null && callGeneration != _generationId) return;
    final reason = args['reason'] as String;
    _state = WorkletState.stopped;
    _ipc.setMessageHandler(null);
    _crash.add((reason: reason, detail: null));
    await _incoming.close();
    await _crash.close();
    if (identical(_instance, this)) _instance = null;
  }

  /// Sends one binary frame to the worklet, prefixed with its 4-byte
  /// big-endian length -- see [_onIpc]'s doc for why.
  @override
  Future<void> send(Uint8List frame) async {
    if (_state != WorkletState.running) {
      throw StateError('worklet is not running (state: $_state)');
    }
    final prefixed = Uint8List(4 + frame.length);
    ByteData.sublistView(prefixed).setUint32(0, frame.length, Endian.big);
    prefixed.setRange(4, prefixed.length, frame);
    await _ipc.send(prefixed);
  }

  /// Pauses the worklet (wired to app background by higher layers).
  Future<void> suspend() async {
    if (_state != WorkletState.running) return;
    await _control.invokeMethod<void>('suspend');
    _state = WorkletState.suspended;
  }

  /// Resumes a suspended worklet.
  Future<void> resume() async {
    if (_state != WorkletState.suspended) return;
    await _control.invokeMethod<void>('resume');
    _state = WorkletState.running;
  }

  /// Terminates the worklet and closes [incoming] and [onCrash].
  Future<void> terminate() async {
    if (_state == WorkletState.stopped) return;
    await _control.invokeMethod<void>('terminate');
    _ipc.setMessageHandler(null);
    _control.setMethodCallHandler(null);
    _state = WorkletState.stopped;
    await _incoming.close();
    await _crash.close();
    if (identical(_instance, this)) _instance = null;
  }
}
