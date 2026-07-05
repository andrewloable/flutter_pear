// Real device/emulator integration test for BareWorklet's lifecycle (E6.1
// suspend/resume, E6.3 reattach-or-kill) -- runs against a REAL Bare Kit
// worklet process and the REAL Android platform-channel bridge, unlike
// flutter_pear_bare/test/bare_worklet_test.dart's
// TestDefaultBinaryMessengerBinding-based tests, which mock every "native"
// response and so can only ever prove the Dart-side decision logic in
// isolation -- never the actual native companion-object state
// (FlutterPearBarePlugin.kt's `worklet`/`workletIpc`/`workletGeneration`)
// that E6.3's reattach-across-a-hot-restart guarantee actually lives in.
// See bare_worklet_test.dart's own "start() while already running" test
// doc comment, which says exactly this.
//
// Run: flutter test integration_test/lifecycle_test.dart -d <device>
import 'package:flutter/services.dart';
import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'suspend() then resume() returns the worklet to a running, functional '
      'state (E6.1)', (tester) async {
    final worklet = await BareWorklet.start().timeout(const Duration(seconds: 10));
    expect(worklet.state, WorkletState.running);

    await worklet.suspend();
    expect(worklet.state, WorkletState.suspended);

    await worklet.resume();
    expect(worklet.state, WorkletState.running);

    // Prove the worklet is not just "running" by name but genuinely
    // functional post-resume: Pear.start() reattaches to this SAME
    // already-running singleton (BareWorklet.start's own within-isolate
    // reattach guard -- no second native worklet is booted) and, while
    // doing so, always performs a real attach.info RPC round trip. That
    // round trip completing successfully is the most direct real-worklet
    // evidence available that suspend()/resume() didn't leave the IPC pipe
    // or the pear-end JS side wedged.
    final pear = await Pear.start().timeout(const Duration(seconds: 10));
    expect(identical(pear.worklet, worklet), isTrue,
        reason: 'Pear.start() must reattach to the SAME already-running '
            'worklet started above, not boot a second one');

    await pear.dispose(); // also terminates worklet; resets BareWorklet's
    // singleton so the next test starts from a clean slate.
  });

  testWidgets(
      'a "start" call while a previous worklet is still alive natively '
      'reports reattached: true and reuses its generation, never spawning a '
      'second worklet -- the E6.3 decision a real Dart hot restart depends '
      'on', (tester) async {
    // This test deliberately talks to the raw `flutter_pear_bare/control`
    // platform channel instead of BareWorklet.start(), for both calls
    // below. That's the only way to reach the interesting native code path
    // from a single running integration_test process:
    //
    // A genuine Dart hot restart tears down and recreates the Dart VM
    // (resetting BareWorklet's private static `_instance` to null) while
    // leaving the Android process -- and FlutterPearBarePlugin.kt's JVM-
    // static companion `worklet` field -- alive. An integration_test run
    // cannot trigger a real hot restart against itself mid-test (there is
    // no API for a test to tear down and recreate its own isolate and keep
    // running its own `main()` afterward), so calling `BareWorklet.start()`
    // a second time within this same test would never even reach native:
    // its own Dart-side singleton guard
    // (`if (existing != null && existing._state != WorkletState.stopped)
    // return existing;`) short-circuits first -- exactly what
    // bare_worklet_test.dart's mocked "start() while already running"
    // test already covers, and explicitly documents as NOT proving the
    // native-side guarantee.
    //
    // Invoking the platform channel directly, twice, bypasses that Dart-side
    // guard entirely and lands both calls on
    // FlutterPearBarePlugin.onMethodCall("start") fresh each time -- which
    // is exactly what happens after a real hot restart (a new/reset Dart
    // caller, no memory of the first call) reaching a native companion
    // object that never went away. This exercises the real
    // `if (worklet != null) { relayFromWorklet(); return true }` decision
    // in startWorklet(), on-device, over the real channel -- something no
    // mocked-channel test can do.
    const control = MethodChannel('flutter_pear_bare/control');

    final first = await control
        .invokeMethod<Map<Object?, Object?>>('start', {'bundlePath': null})
        .timeout(const Duration(seconds: 10));
    expect(first?['reattached'], isFalse,
        reason: 'the very first start on a clean device/app process must be '
            'a genuine cold boot');
    final firstGeneration = first?['generationId'] as int?;
    expect(firstGeneration, isNotNull);

    final second = await control
        .invokeMethod<Map<Object?, Object?>>('start', {'bundlePath': null})
        .timeout(const Duration(seconds: 10));
    expect(second?['reattached'], isTrue,
        reason: 'native must report a reattach, not a fresh boot, when its '
            'own worklet is still alive -- this is the exact signal '
            "Pear.start()'s reattach-health-probe timeout choice (E6.3) "
            'depends on');
    expect(second?['generationId'], firstGeneration,
        reason: 'a reattach must reuse the SAME generation id -- a '
            'different one would mean a second worklet was booted alongside '
            'the first instead of reattaching to it');

    await control.invokeMethod<void>('terminate');
  });
}
