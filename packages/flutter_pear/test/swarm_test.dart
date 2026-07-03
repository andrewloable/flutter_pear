import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/src/crypto.dart';
import 'package:flutter_pear/src/exceptions.dart';
import 'package:flutter_pear/src/rpc.dart';
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear/src/swarm.dart';
import 'package:flutter_pear_bare/flutter_pear_bare.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal [WorkletIpc] double, same shape as rpc_test.dart's _FakeWorklet
/// (kept separate here -- there's no shared test-support package yet, that's
/// flutter_pear_test, E3) -- just enough to drive a real [PearRpc]/[PearSwarm]
/// pair without a real worklet.
class _FakeWorklet implements WorkletIpc {
  final sentFrames = <Map<String, Object?>>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _crash = StreamController<WorkletCrash>.broadcast();
  String sessionNonce = 'test-session-nonce';

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<WorkletCrash> get onCrash => _crash.stream;

  @override
  Future<void> send(Uint8List frame) async {
    expect(frame[0], PearFrameType.json,
        reason: 'PearRpc.call always sends JSON frames');
    sentFrames
        .add(jsonDecode(utf8.decode(frame.sublist(1))) as Map<String, Object?>);
  }

  /// The `id` of the most recently sent request.
  int get lastRequestId => sentFrames.last['id'] as int;

  /// Simulates the worklet responding to request [id] with a JSON frame.
  void respond(int id, {Object? ok, Map<String, Object?>? err}) {
    sendJsonFrame({
      'id': id,
      if (err != null) 'err': err else 'ok': ok,
    });
  }

  /// Pushes a well-formed [PearFrameType.json] frame onto [incoming],
  /// stamped with [sessionNonce] -- every real worklet-sent frame carries
  /// this (E2.5).
  void sendJsonFrame(Map<String, Object?> body) {
    final encoded = utf8.encode(jsonEncode({
      ...body,
      PearHandshakeField.envelopeNonce: sessionNonce,
    }));
    _incoming.add(Uint8List.fromList([PearFrameType.json, ...encoded]));
  }
}

void main() {
  late _FakeWorklet worklet;
  late PearRpc rpc;
  late PearKey topic;

  setUp(() async {
    worklet = _FakeWorklet();
    rpc = PearRpc(worklet);
    topic = PearCrypto.topicFromString('swarm-test-topic');
    // Establish a session first -- PearRpc drops ordinary events (including
    // swarm.lifecycle) sent before the first response is ever seen (E2.5),
    // exactly like Pear.start's real attach.info round trip always does.
    final attach = rpc.call(PearMethod.attachInfo);
    worklet.respond(worklet.lastRequestId, ok: {});
    await attach;
  });

  tearDown(() => rpc.dispose());

  /// Calls [PearSwarm.join] and immediately acks the worklet-side
  /// `swarm.join` RPC it sends -- every real call site does this in one
  /// synchronous burst (see _FakeWorklet.send's synchronous recording).
  Future<PearSwarm> joinSwarm({
    Duration joinTimeout = const Duration(seconds: 30),
  }) async {
    final future = PearSwarm.join(rpc, topic, joinTimeout: joinTimeout);
    worklet.respond(worklet.lastRequestId, ok: {'joined': topic.hex});
    return future;
  }

  void sendLifecycle(String state, {String? reason}) {
    worklet.sendJsonFrame({
      'ev': PearEventName.swarmLifecycle,
      'p': {
        'topic': topic.hex,
        'state': state,
        if (reason != null) 'reason': reason,
      },
    });
  }

  test('join() starts in discovering state, readable synchronously',
      () async {
    final swarm = await joinSwarm();
    expect(swarm.currentState.state, PearSwarmState.discovering);
    expect(swarm.currentState.error, isNull);
  });

  test(
      'the happy-path state sequence reaches connected and cancels the join '
      'timeout', () async {
    final swarm = await joinSwarm(joinTimeout: const Duration(milliseconds: 30));
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    sendLifecycle(PearSwarmState.connecting.name);
    sendLifecycle(PearSwarmState.connected.name);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state),
        [PearSwarmState.connecting, PearSwarmState.connected]);
    expect(swarm.currentState.state, PearSwarmState.connected);

    // The join timeout must NOT fire once connected -- wait past it and
    // confirm no failed transition shows up.
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(states.map((s) => s.state), isNot(contains(PearSwarmState.failed)));
    await sub.cancel();
  });

  test(
      'the join timeout reaches failed with a typed CONNECT_TIMEOUT reason '
      'if connected is never reached -- never an infinite wait', () async {
    final swarm = await joinSwarm(joinTimeout: const Duration(milliseconds: 20));
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(states, hasLength(1));
    expect(states.single.state, PearSwarmState.failed);
    expect(
      states.single.error,
      isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.connectTimeout),
    );
    expect(swarm.currentState.state, PearSwarmState.failed);
    await sub.cancel();
  });

  test('a reconnecting transition is emitted after all connections close',
      () async {
    final swarm = await joinSwarm();
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    sendLifecycle(PearSwarmState.connected.name);
    sendLifecycle(PearSwarmState.reconnecting.name);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state),
        [PearSwarmState.connected, PearSwarmState.reconnecting]);
    await sub.cancel();
  });

  test('a failed transition carries a typed PearConnectionException reason',
      () async {
    final swarm = await joinSwarm(joinTimeout: const Duration(seconds: 30));
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    sendLifecycle(PearSwarmState.failed.name, reason: PearErrorCode.udpBlocked);
    await Future<void>.delayed(Duration.zero);

    expect(states, hasLength(1));
    expect(states.single.state, PearSwarmState.failed);
    expect(
      states.single.error,
      isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.udpBlocked),
    );
    await sub.cancel();
  });

  test('an unrecognized lifecycle state is ignored, not a crash', () async {
    final swarm = await joinSwarm();
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    // An ad hoc diagnostic notice (no `state` field) and a `state` value
    // this version of the schema doesn't know about -- neither should
    // reach the state stream.
    worklet.sendJsonFrame({
      'ev': PearEventName.swarmLifecycle,
      'p': {'topic': topic.hex, 'event': 'joining'},
    });
    sendLifecycle('some-future-state-this-schema-does-not-know');
    await Future<void>.delayed(Duration.zero);

    expect(states, isEmpty);
    await sub.cancel();
  });

  test(
      'write() after the connection closes fails with a typed '
      'PearConnectionException, never a hang', () async {
    final swarm = await joinSwarm();
    final peerKey = PearCrypto.topicFromString('peer-under-test');

    worklet.sendJsonFrame({
      'ev': PearEventName.swarmConnection,
      'p': {'topic': topic.hex, 'peer': peerKey.hex},
    });
    final conn = await swarm.connections.first;

    worklet.sendJsonFrame({
      'ev': PearEventName.connectionClose,
      'p': {'topic': topic.hex, 'peer': peerKey.hex},
    });
    await Future<void>.delayed(Duration.zero);

    final future = conn.write(Uint8List.fromList([1, 2, 3]));
    worklet.respond(worklet.lastRequestId, err: {
      'message': 'unknown peer: ${peerKey.hex}',
      'code': PearErrorCode.unknownPeer,
    });
    await expectLater(
      future,
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownPeer)),
    );
  });

  test('leave() cancels the join timeout, so it never fires after leaving',
      () async {
    final swarm = await joinSwarm(joinTimeout: const Duration(milliseconds: 20));
    // leave() itself issues the swarm.leave RPC; ack it inline like join's
    // own helper does.
    final leaveFuture = swarm.leave();
    worklet.respond(worklet.lastRequestId, ok: {'left': topic.hex});
    await leaveFuture;

    // No explicit assertion below on purpose: if the join timeout weren't
    // cancelled, it would fire during this wait and call _state.add on the
    // now-closed controller (leave() already closed it above), which
    // throws synchronously inside the Timer callback -- an uncaught async
    // error that flutter_test's zone fails THIS test with, never actually
    // reaching any listener to check a flag against. Reaching the end of
    // this test cleanly IS the assertion.
    await Future<void>.delayed(const Duration(milliseconds: 40));
  });

  test(
      'E3.3 fake-driven variant: a real FakeBareWorklet swarm failure still '
      'reaches PearSwarmState.failed with a typed reason (E2.7/X8)',
      () async {
    // Same X8 spine behavior as this file's own hand-rolled-fake tests
    // above, proven again here against flutter_pear_test's shared,
    // conformance-tested fake.
    final fakeWorklet = FakeBareWorklet();
    final fakeRpc = PearRpc(fakeWorklet);
    await fakeRpc.call(PearMethod.attachInfo);

    final fakeSwarm = await PearSwarm.join(fakeRpc, topic);
    final states = <PearSwarmStatus>[];
    fakeSwarm.state.listen(states.add);
    fakeWorklet.simulateSwarmFailure(topic.hex);
    await Future<void>.delayed(Duration.zero);

    expect(states, hasLength(1));
    expect(states.single.state, PearSwarmState.failed);
    expect(
      states.single.error,
      isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.udpBlocked),
    );
    await fakeRpc.dispose();
  });
}
