part of 'fake_worklet.dart';

/// Failure-injection hooks for [FakeBareWorklet] (E3.3) -- this is why the
/// fake earns its keep: every RPC-spine failure path (E2.2-E2.7) must be
/// drivable in a unit test, not just the happy path E3.2 already covers.
///
/// Each hook mirrors REAL wire behavior the schema already defines -- no
/// fake-only shortcuts. A `PearRpc`/`PearSwarm` wired to a [FakeBareWorklet]
/// can't tell the difference between one of these and the real worklet
/// misbehaving the same way.
extension FailureInjection on FakeBareWorklet {
  /// Simulates the worklet crashing -- fires the native crash-observation
  /// backstop ([WorkletIpc.onCrash]), mirroring
  /// `FlutterPearBarePlugin.kt`'s `reportUnexpectedExit` (E2.6). No detail
  /// is attached, matching the real backstop, which only knows the
  /// worklet's IPC ended, not why -- a real crash's detailed
  /// kind/message/stack travels over the ordinary `worklet.crash` EVENT
  /// path instead (ordinary events, unlike this backstop, require an
  /// established session -- see [sendStaleNonceEvent]'s doc for why that
  /// matters).
  void simulateNativeCrash({String reason = 'simulated crash'}) {
    _crash.add((reason: reason, detail: null));
  }

  /// Makes the next request this worklet receives (optionally restricted
  /// to [method]; any method otherwise) go unanswered -- exercises
  /// `PearRpc.call()`'s own bounded timeout (E2.2) instead of a real
  /// response ever arriving. One-shot: only the very next matching request
  /// is swallowed; later requests are answered normally.
  void swallowNextRequest({String? method}) {
    _swallowNextMethod = method ?? '*';
  }

  /// Sends [payload] as an [eventName] event stamped with a different,
  /// made-up session nonce instead of this worklet's real one -- simulates
  /// a straggler frame from a killed/replaced worklet generation (E2.5),
  /// which `PearRpc` must silently drop once ITS OWN session is already
  /// established (see `rpc.dart`'s `_onFrame` nonce gate). Has no effect
  /// before a session is established (the nonce gate doesn't apply yet) --
  /// call this after the caller's `attach.info` round trip, like any other
  /// stale-nonce test.
  void sendStaleNonceEvent(String eventName, Map<String, Object?> payload) {
    _emitEvent(eventName, payload, nonceOverride: _randomHex(16));
  }

  /// Pushes a frame with [frameType] as its discriminator byte (default
  /// [PearFrameType.raw], 0x01) -- exercises `PearRpc`'s unhandled-frame-type
  /// diagnostic path (E2.4), same as any byte value this schema version
  /// doesn't recognize (surfaced as [PearEventName.rpcDiagnostic], never
  /// silently dropped).
  void sendRawFrame(List<int> body, {int frameType = PearFrameType.raw}) {
    _incoming.add(Uint8List.fromList([frameType, ...body]));
  }

  /// Simulates the worklet reporting [topicHex] as
  /// [PearSwarmState.failed] with [reason] (default
  /// [PearErrorCode.udpBlocked]) -- mirrors pear-end's
  /// `swarm.on('error', ...)` -> `sendState(topicHex, FAILED, reason)` path
  /// (E2.7/E4.4). Independent of, and faster than, `PearSwarm.join`'s own
  /// bounded connect timeout -- use this to test the "worklet detected the
  /// failure itself" path specifically, rather than waiting out the bound.
  void simulateSwarmFailure(String topicHex,
      {String reason = PearErrorCode.udpBlocked}) {
    _sendState(topicHex, PearSwarmState.failed, reason: reason);
  }

  /// Injects a symlink entry at [path] into the drive [driveKeyHex] (opened
  /// via `PearMethod.driveOpen` already) -- simulates an untrusted peer's
  /// drive publishing one, without needing a real second worklet
  /// (flutter_pear-ovt.2.8). `PearMethod.driveMirrorToDisk` rejects every
  /// symlink entry unconditionally regardless of [linkTarget]'s shape,
  /// mirroring the real worklet's zip-slip hardening
  /// (flutter_pear-ovt.2.7) -- [linkTarget] is recorded for inspection
  /// only, never interpreted or followed by this fake.
  void injectDriveSymlink(String driveKeyHex, String path, String linkTarget) {
    _requireDrive(driveKeyHex).symlinks[path] = linkTarget;
  }

  // Connection-drop-mid-stream is intentionally NOT a new hook here --
  // disconnectFrom (fake_worklet.dart, added in E3.2) already IS this
  // hook: it simulates a live peer connection ending out from under an
  // otherwise-still-joined topic, at any point in the exchange, mirroring
  // a real Hyperswarm connection's 'close' firing mid-stream. See its doc
  // comment and fake_worklet_test.dart's "disconnectFrom sends a real
  // connection.close event over the wire" test.
}
