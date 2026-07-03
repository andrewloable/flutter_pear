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

/// A running Bare runtime worklet and the binary IPC pipe to it.
///
/// This is the low-level surface — [start] / [terminate] / [suspend] /
/// [resume] plus [send] and the [incoming] byte-frame stream. High-level Pear
/// APIs (PearSwarm, PearStore, …) in the `flutter_pear` package are built on
/// top of this.
///
/// One worklet per app. [start] is hot-restart-safe: after a Dart hot restart
/// the native worklet keeps running and [start] reattaches to it.
class BareWorklet {
  BareWorklet._();

  /// Lifecycle control (start/terminate/suspend/resume).
  static const MethodChannel _control =
      MethodChannel('flutter_pear_bare/control');

  /// Bidirectional binary frames to/from the worklet.
  static const BasicMessageChannel<ByteData> _ipc =
      BasicMessageChannel('flutter_pear_bare/ipc', BinaryCodec());

  static BareWorklet? _instance;

  final StreamController<Uint8List> _incoming =
      StreamController<Uint8List>.broadcast();
  WorkletState _state = WorkletState.stopped;

  /// Current lifecycle state.
  WorkletState get state => _state;

  /// Frames emitted by the worklet (its `IPC.write` on the pear-end side).
  Stream<Uint8List> get incoming => _incoming.stream;

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
    await _control.invokeMethod<void>('start', {'bundlePath': bundlePath});
    w._state = WorkletState.running;
    return w;
  }

  Future<ByteData>? _onIpc(ByteData? message) {
    if (message != null) {
      _incoming.add(message.buffer
          .asUint8List(message.offsetInBytes, message.lengthInBytes));
    }
    return null; // no reply; frames flow through [incoming]
  }

  /// Sends one binary frame to the worklet.
  Future<void> send(Uint8List frame) async {
    if (_state != WorkletState.running) {
      throw StateError('worklet is not running (state: $_state)');
    }
    await _ipc.send(ByteData.sublistView(frame));
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

  /// Terminates the worklet and closes [incoming].
  Future<void> terminate() async {
    if (_state == WorkletState.stopped) return;
    await _control.invokeMethod<void>('terminate');
    _ipc.setMessageHandler(null);
    _state = WorkletState.stopped;
    await _incoming.close();
    if (identical(_instance, this)) _instance = null;
  }
}
