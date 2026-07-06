// T2 smoke test (flutter_pear-ovt.1.8): sim-iOS <-> physical-Android real
// chat, both directions, over a real Hyperswarm topic -- run the SAME file
// concurrently on both devices (flutter test
// integration_test/cross_platform_chat_test.dart -d <device>). Each side
// sends one uniquely-tagged message and asserts it receives the OTHER
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

const _topicName = 'flutter-pear-ovt-1-8-t2-smoke';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'T2: real chat message exchange between sim-iOS and physical-Android',
      (tester) async {
    final selfTag = Platform.isIOS ? 'iOS' : 'Android';
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
