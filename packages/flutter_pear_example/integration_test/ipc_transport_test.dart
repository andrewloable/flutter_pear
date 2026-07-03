// Real device/emulator integration test for the flutter_pear_bare IPC
// transport (flutter_pear-5rl). Runs against a REAL worklet + the REAL
// Android engine/platform-channel bridge -- unlike bare_worklet_test.dart's
// TestDefaultBinaryMessengerBinding-based tests, which only exercise the
// codec's encode/decode logic host-side and can never reach the actual
// native engine bridge where E2.5's BinaryCodec bug actually lived (it
// silently delivered EMPTY data to Dart on every native-to-Dart send,
// confirmed present since E1.3 and undetected by every prior "clean boot,
// no crash" check because nothing waited past the RPC timeout for a real
// response). This test would have caught that bug: it fails loudly (a
// timeout, well before the full RPC timeout elapses) if the platform
// channel silently drops worklet-to-Dart data again.
//
// Run: flutter test integration_test/ipc_transport_test.dart -d <device>
import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'Pear.start() completes a real attach.info round trip well within '
      'the RPC timeout', (tester) async {
    final stopwatch = Stopwatch()..start();
    // Pear.start() always does an attach.info round trip immediately after
    // booting the worklet (E2.5) -- its own 10s default RPC timeout is the
    // ceiling this call could silently hang against if native-to-Dart IPC
    // is broken. A generous but much-tighter-than-10s bound here means a
    // regression fails this test in seconds, not by hanging the whole run.
    final pear = await Pear.start().timeout(const Duration(seconds: 8));

    stopwatch.stop();
    expect(stopwatch.elapsed, lessThan(const Duration(seconds: 8)),
        reason: 'a real response must arrive well before the RPC timeout; '
            'hitting it means native-to-Dart IPC silently dropped data '
            '(the exact class of bug this test exists to catch)');

    await pear.dispose();
  });
}
