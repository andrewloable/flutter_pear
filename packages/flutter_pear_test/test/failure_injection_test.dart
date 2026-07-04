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
  late FakeBareWorklet worklet;
  late PearRpc rpc;

  setUp(() async {
    worklet = FakeBareWorklet();
    rpc = PearRpc(worklet);
    await rpc.call(PearMethod.attachInfo); // establish the session (E2.5)
  });

  tearDown(() => rpc.dispose());

  test(
      'simulateNativeCrash fails all pending calls with WORKLET_CRASHED '
      '(E2.6)', () async {
    final pending = rpc.call('never.answers');
    final expectation = expectLater(
      pending,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );
    worklet.simulateNativeCrash(reason: 'test crash');
    await expectation;
  });

  test(
      'swallowNextRequest causes PearRpc.call() to time out instead of '
      'ever hanging silently (E2.2)', () async {
    worklet.swallowNextRequest();
    await expectLater(
      rpc.call('never.answers', null, const Duration(milliseconds: 20)),
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.rpcTimeout)),
    );
  });

  test(
      'swallowNextRequest is one-shot -- a later request is answered '
      'normally', () async {
    worklet.swallowNextRequest();
    await expectLater(
      rpc.call('never.answers', null, const Duration(milliseconds: 20)),
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.rpcTimeout)),
    );

    final result = await rpc.call(PearMethod.attachInfo);
    expect(result, isNotNull);
  });

  test(
      'sendStaleNonceEvent is silently dropped once a session is '
      'established (E2.5)', () async {
    final events = <PearEvent>[];
    rpc.events.listen(events.add);
    worklet.sendStaleNonceEvent(
        PearEventName.swarmLifecycle, {'topic': 'abc', 'state': 'discovering'});
    await Future<void>.delayed(Duration.zero);
    expect(events, isEmpty);
  });

  test(
      'sendRawFrame surfaces an unrecognized frame type as a diagnostic, '
      'not silently dropped (E2.4)', () async {
    final events = <PearEvent>[];
    rpc.events.listen(events.add);
    worklet.sendRawFrame(utf8.encode('whatever'));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.rpcDiagnostic);
  });

  test(
      'disconnectFrom drops a connection mid-stream -- with data already '
      'flowing, not just idle -- still closing the local PearConnection '
      'data stream', () async {
    final other = FakeBareWorklet(hub: worklet.hub);
    final rpcOther = PearRpc(other);
    await rpcOther.call(PearMethod.attachInfo);
    final topic =
        PearCrypto.unsafeTopicFromString('failure-injection-drop-test');

    final swarm = await PearSwarm.join(rpc, topic);
    final firstConn = swarm.connections.first;
    final swarmOther = await PearSwarm.join(rpcOther, topic);
    final firstConnOther = swarmOther.connections.first;
    final conn = await firstConn;
    final connOther = await firstConnOther;

    // Data is actively flowing through the connection first -- a genuine
    // mid-stream drop, not an idle connection that happens to close.
    final received = <Uint8List>[];
    conn.data.listen(received.add);
    await connOther.write(Uint8List.fromList(utf8.encode('in flight')));
    await Future<void>.delayed(Duration.zero);
    expect(received, hasLength(1));

    var closed = false;
    conn.data.listen((_) {}, onDone: () => closed = true);

    worklet.disconnectFrom(other);
    await Future<void>.delayed(Duration.zero);
    expect(closed, isTrue);

    await rpcOther.dispose();
  });

  test(
      'simulateSwarmFailure reaches PearSwarmState.failed with the given '
      'reason (E2.7/E4.4)', () async {
    final topic =
        PearCrypto.unsafeTopicFromString('failure-injection-blocked-test');
    final swarm = await PearSwarm.join(rpc, topic);

    final states = <PearSwarmStatus>[];
    swarm.state.listen(states.add);
    worklet.simulateSwarmFailure(topic.hex);
    await Future<void>.delayed(Duration.zero);

    expect(states, hasLength(1));
    expect(states.single.state, PearSwarmState.failed);
    expect(
      states.single.error,
      isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.udpBlocked),
    );
  });
}
