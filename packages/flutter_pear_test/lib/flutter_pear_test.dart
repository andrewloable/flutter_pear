/// In-memory fakes (fake swarm, fake worklet) for unit-testing `flutter_pear`
/// apps without radios or real peers.
///
/// Start with [FakeBareWorklet]: it implements the same `WorkletIpc` seam a
/// real `BareWorklet` does, so `PearRpc`/`PearSwarm`/`PearConnection` run
/// completely unmodified against it. Join two instances to the same
/// [FakeSwarmHub] to simulate two peers finding each other over a topic.
///
/// The [FailureInjection] extension (E3.3) drives every RPC-spine failure
/// path in a unit test — a worklet crash, a swallowed request (timeout), a
/// stale-nonce frame, an unrecognized frame type, a mid-stream connection
/// drop (`FakeBareWorklet.disconnectFrom`), and a swarm reporting itself
/// failed (e.g. `PearErrorCode.udpBlocked`).
///
/// The fake conforms to `flutter_pear`'s RPC schema
/// (`package:flutter_pear/src/schema.dart`); it is a conformance consumer,
/// never a co-author — when the two disagree, the schema wins and the fake
/// is fixed to match.
///
/// `Pear.platformInfo` involves no worklet traffic at all (it's a
/// release-pinned platform constant, not an RPC round trip), so exercising
/// both platforms' values needs no fake worklet — just
/// `debugDefaultTargetPlatformOverride`:
///
/// ```dart
/// debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
/// expect(Pear.platformInfo.backgroundExecution,
///     PearBackgroundExecution.foregroundOnly);
/// debugDefaultTargetPlatformOverride = null; // reset in tearDown
/// ```
library;

export 'package:flutter_pear/flutter_pear.dart'
    show PearBackgroundExecution, PearPlatformInfo, PearValidationTier;

export 'src/fake_worklet.dart';
