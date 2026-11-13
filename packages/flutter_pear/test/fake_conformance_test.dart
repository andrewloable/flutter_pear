// E3.2 conformance check: PearSwarm/PearConnection (this package) run
// completely unmodified against FakeBareWorklet (flutter_pear_test) -- the
// fake is a conformance CONSUMER of the schema this package defines, so
// this test lives here (not in flutter_pear_test) to make that direction
// explicit: this package never imports the fake for anything but this one
// proof-of-conformance test.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'PearSwarm/PearConnection run end-to-end, unmodified, against two '
      'FakeBareWorklets', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final topic =
        PearCrypto.unsafeTopicFromString('flutter_pear-conformance-test');

    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;

    final connA = await firstConnA;
    final connB = await firstConnB;
    expect(connA.remotePublicKey.hex, workletB.peerKey);
    expect(connB.remotePublicKey.hex, workletA.peerKey);

    final received = connB.data.first;
    await connA.write(Uint8List.fromList(utf8.encode('hi from A')));
    expect(utf8.decode(await received), 'hi from A');

    await swarmA.leave();
    await swarmB.leave();
  });

  test('datagrams run end-to-end against two FakeBareWorklets', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);
    final topic =
        PearCrypto.unsafeTopicFromString('flutter_pear-datagram-conformance');

    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    final connB = await firstConnB;

    final streamBytes = <Uint8List>[];
    connB.data.listen(streamBytes.add);
    final received = connB.datagrams.first;
    await connA.sendDatagram(Uint8List.fromList([4, 5, 6]));
    expect(await received, [4, 5, 6]);
    await Future<void>.delayed(Duration.zero);
    expect(streamBytes, isEmpty, reason: 'a datagram never arrives on data');

    await swarmA.leave();
    await swarmB.leave();
  });
}
