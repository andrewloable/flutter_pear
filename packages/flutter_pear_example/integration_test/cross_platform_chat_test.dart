// T2 smoke test (flutter_pear-ovt.1.8): cross-platform real chat, both
// directions, over a real Hyperswarm topic -- run the SAME file
// concurrently on both devices (flutter test
// integration_test/cross_platform_chat_test.dart -d <device>).
//
// The two sides need only be two peers that can REACH each other. Verified
// 2026-09-23 on Android emulator, iOS simulator and macOS desktop -- each
// paired with the headless host peer (flutter_pear_example/tool/peer.js),
// which is the recommended second peer.
//
// Do NOT pair an Android emulator with an iOS simulator on one Mac: both
// sides sit at `discovering` until this test's 90s timeout, because of NAT
// hairpinning (the Android emulator adds its own 10.0.2.x NAT on top of the
// host's). Measured, not assumed -- see README.md's "Two simulators on one
// Mac" section. A failure in that pairing is a network topology limit, not
// a flutter_pear bug.
//
// Each side sends one uniquely-tagged message and asserts it receives the OTHER
// platform's tagged message. Exercises the real PearSwarm/PearConnection
// API (same underlying wire traffic the ChatScreen widget uses) rather than
// UI-coordinate automation, which is unreliable across two independently
// launched real devices.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'semantics_settle.dart';

const _topicName = 'flutter-pear-ovt-1-8-t2-smoke';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  settleSemanticsBeforeBaseline();

  testWidgets(
      'T2: real chat message exchange between sim-iOS and physical-Android',
      (tester) async {
    // Platform.operatingSystem, not an isIOS/else guess: this test now runs
    // on macOS/Linux/Windows desktop too, where the old binary check
    // mislabelled the desktop side "Android" in every log line and, worse,
    // gave two genuinely different platforms the SAME tag -- which would
    // make the "did I receive the OTHER side?" assertion below unsound if
    // both were ever run against each other.
    final selfTag = Platform.operatingSystem;
    final ownMessage = '$selfTag says hi ${DateTime.now().millisecondsSinceEpoch}';
    // ignore: avoid_print
    print('T2-CHAT[$selfTag]: starting, will send: $ownMessage');

    final pear = await Pear.start().timeout(const Duration(seconds: 20));
    addTearDown(pear.dispose);

    final topic = PearCrypto.unsafeTopicFromString(_topicName);
    final swarm = await pear.join(topic);
    addTearDown(swarm.leave);

    final connection =
        await swarm.connections.first.timeout(const Duration(seconds: 90));
    // ignore: avoid_print
    print('T2-CHAT[$selfTag]: connected to '
        '${connection.remotePublicKey.hex.substring(0, 8)}...');

    final receivedOther = Completer<String>();
    connection.data.listen((bytes) {
      final text = utf8.decode(bytes);
      // ignore: avoid_print
      print('T2-CHAT[$selfTag]: received: $text');
      if (!text.startsWith(selfTag) && !receivedOther.isCompleted) {
        receivedOther.complete(text);
      }
    });

    await connection.write(utf8.encode(ownMessage));
    // ignore: avoid_print
    print('T2-CHAT[$selfTag]: sent: $ownMessage');

    final otherMessage =
        await receivedOther.future.timeout(const Duration(seconds: 60));
    // ignore: avoid_print
    print('T2-CHAT[$selfTag]: SUCCESS, received other side: $otherMessage');

    expect(otherMessage, isNot(startsWith(selfTag)));
  });
}
