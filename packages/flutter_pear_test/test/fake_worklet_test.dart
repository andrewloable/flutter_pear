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
  late FakeSwarmHub hub;
  late PearKey topic;

  setUp(() {
    hub = FakeSwarmHub();
    topic = PearCrypto.topicFromString('fake-worklet-test-topic');
  });

  /// Wraps [worklet] in a real [PearRpc] and completes the attach.info round
  /// trip -- establishes the session nonce, exactly like Pear.start() always
  /// does before anything else, matching how every real caller's PearRpc
  /// gets into a state where ordinary events are accepted (E2.5).
  Future<PearRpc> connectedRpc(FakeBareWorklet worklet) async {
    final rpc = PearRpc(worklet);
    await rpc.call(PearMethod.attachInfo);
    return rpc;
  }

  test('two fake peers joining the same topic both get a connection to '
      'each other', () async {
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = await connectedRpc(workletA);
    final rpcB = await connectedRpc(workletB);

    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;

    final connA = await firstConnA;
    final connB = await firstConnB;
    expect(connA.remotePublicKey.hex, workletB.peerKey);
    expect(connB.remotePublicKey.hex, workletA.peerKey);
  });

  test('a write on one peer delivers data on the other', () async {
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = await connectedRpc(workletA);
    final rpcB = await connectedRpc(workletB);

    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    final connB = await firstConnB;

    final received = connB.data.first;
    await connA.write(Uint8List.fromList(utf8.encode('hello from A')));
    expect(utf8.decode(await received), 'hello from A');
  });

  test('leaving closes the local connection data stream', () async {
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = await connectedRpc(workletA);
    final rpcB = await connectedRpc(workletB);

    final swarmA = await PearSwarm.join(rpcA, topic);
    // Subscribed to .connections.first for BOTH swarms immediately after
    // EACH swarm's own join() resolves, with no other await in between --
    // this fake connects an already-present peer synchronously-ish (no
    // real network discovery delay), so inserting an unrelated await here
    // (e.g. awaiting firstConnA before even creating firstConnB) risks
    // subscribing to swarmB.connections AFTER its own swarm.connection
    // event already fired and was lost -- a plain broadcast stream never
    // replays to a late subscriber. Await both .first futures together
    // afterward, never interleaved with more work.
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;

    await firstConnA;
    final connB = await firstConnB;

    var dataClosed = false;
    connB.data.listen((_) {}, onDone: () => dataClosed = true);

    await swarmB.leave();
    await Future<void>.delayed(Duration.zero);
    expect(dataClosed, isTrue);
  });

  test('disconnectFrom sends a real connection.close event over the wire',
      () async {
    // Distinct from the "leaving" test above, which only proves
    // PearSwarm.leave()'s own LOCAL cleanup closes _byKey's connections --
    // that never actually exercises the wire-level connection.close event
    // (STEP 1's third listed event) at all. This one does: disconnectFrom
    // is the fake's stand-in for a peer connection ending out from under an
    // otherwise-still-joined topic (e.g. the peer went away, matching what
    // E3.3's failure-injection hooks will trigger).
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = await connectedRpc(workletA);
    final rpcB = await connectedRpc(workletB);

    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    await firstConnA;
    final connB = await firstConnB;

    var closed = false;
    connB.data.listen((_) {}, onDone: () => closed = true);

    // disconnectFrom only reports the CALLER's own side of the connection
    // ending (see its doc comment) -- B "detects" its connection to A
    // ending, so it's B's own PearConnection (connB) that closes, not A's.
    workletB.disconnectFrom(workletA);
    await Future<void>.delayed(Duration.zero);

    expect(closed, isTrue);
  });

  test('the swarm state stream reaches connected when a peer joins',
      () async {
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = await connectedRpc(workletA);
    final rpcB = await connectedRpc(workletB);

    final swarmA = await PearSwarm.join(rpcA, topic);
    expect(swarmA.currentState.state, PearSwarmState.discovering);

    final states = <PearSwarmStatus>[];
    swarmA.state.listen(states.add);
    await PearSwarm.join(rpcB, topic);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state), contains(PearSwarmState.connected));
  });

  test('write() to an unknown peer fails with a typed PearConnectionException',
      () async {
    final workletA = FakeBareWorklet(hub: hub);
    final rpcA = await connectedRpc(workletA);
    final swarmA = await PearSwarm.join(rpcA, topic);

    // Fabricate a peer that was never actually connected.
    final ghostPeer = PearCrypto.hash(Uint8List.fromList(utf8.encode('ghost')));
    swarmA.connections.listen((_) {}); // no-op; nothing will arrive
    final result = rpcA.call(PearMethod.connectionWrite, {
      'peer': ghostPeer.hex,
      'data': base64Encode(utf8.encode('nope')),
    });

    await expectLater(
      result,
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownPeer)),
    );
  });
}
