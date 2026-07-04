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

  test(
      'PearRpc.notifyWorkletSuspended(true) transitions state to suspended '
      '(E6.2)', () async {
    final swarm = await joinSwarm();
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    sendLifecycle(PearSwarmState.connected.name);
    // notifyWorkletSuspended reaches PearSwarm one stream-hop sooner than a
    // worklet-sent frame does (_incoming -> _onFrame -> _events -> listener
    // vs. _workletSuspendedChanges -> listener directly) -- await here so
    // "connected" is fully delivered before "suspended" is triggered,
    // matching the order these two calls actually happen in real usage.
    await Future<void>.delayed(Duration.zero);
    rpc.notifyWorkletSuspended(true);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state),
        [PearSwarmState.connected, PearSwarmState.suspended]);
    expect(swarm.currentState.state, PearSwarmState.suspended);
    await sub.cancel();
  });

  test(
      'PearRpc.notifyWorkletSuspended(false) resumes to connected if a peer '
      'is still tracked (E6.2)', () async {
    final swarm = await joinSwarm();
    final peerKey = PearCrypto.topicFromString('peer-under-test');
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    worklet.sendJsonFrame({
      'ev': PearEventName.swarmConnection,
      'p': {'topic': topic.hex, 'peer': peerKey.hex},
    });
    await swarm.connections.first;
    rpc.notifyWorkletSuspended(true);
    rpc.notifyWorkletSuspended(false);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state),
        [PearSwarmState.suspended, PearSwarmState.connected]);
    await sub.cancel();
  });

  test(
      'PearRpc.notifyWorkletSuspended(false) resumes to reconnecting if this '
      'swarm was connected before, but has no tracked peer now (E6.2)',
      () async {
    final swarm = await joinSwarm();
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    // Reaches connected (setting _everConnected), then loses its only
    // peer, before ever suspending -- so PearSwarmState.reconnecting's own
    // "was connected at least once" contract is genuinely satisfied here,
    // unlike a swarm that suspends while still discovering.
    sendLifecycle(PearSwarmState.connected.name);
    await Future<void>.delayed(Duration.zero);
    rpc.notifyWorkletSuspended(true);
    rpc.notifyWorkletSuspended(false);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state), [
      PearSwarmState.connected,
      PearSwarmState.suspended,
      PearSwarmState.reconnecting,
    ]);
    await sub.cancel();
  });

  test(
      'PearRpc.notifyWorkletSuspended(false) resumes to discovering, not '
      'reconnecting, if this swarm was never connected before suspending '
      '(E6.2 -- reconnecting requires having been connected at least once)',
      () async {
    final swarm = await joinSwarm();
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    rpc.notifyWorkletSuspended(true);
    rpc.notifyWorkletSuspended(false);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state),
        [PearSwarmState.suspended, PearSwarmState.discovering]);
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

    // write() now fails LOCALLY (E6.5) the moment this connection's own
    // data stream has closed -- it never even reaches the RPC layer, so
    // there's no worklet response to simulate here anymore. That's the
    // point: asking the worklet would be unreliable anyway if the SAME
    // peer had already reconnected as a brand-new connection by the time
    // this call went out (see PearConnection's own doc for why).
    await expectLater(
      conn.write(Uint8List.fromList([1, 2, 3])),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.connectionClosed)),
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

  test(
      'the full reconnect cycle: a dropped peer connection is ephemeral (a '
      'NEW PearConnection arrives on reconnect, never the old one reused) '
      'and state goes connected -> reconnecting -> connected (E6.5)',
      () async {
    // This is RECONNECT_CONTRACT.md's decision, end to end: PearSwarm
    // itself adds no reconnect logic of its own -- Hyperswarm's own
    // automatic re-announce/re-discovery is what produces a fresh
    // PearEventName.swarmConnection after a drop; FakeSwarmHub.join()
    // (called again for an already-joined pair) is this fake's stand-in
    // for that automatic rediscovery.
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final swarmB = await PearSwarm.join(rpcB, topic);
    final states = <PearSwarmStatus>[];
    final sub = swarmB.state.listen(states.add);
    final firstConnB = swarmB.connections.first;
    await PearSwarm.join(rpcA, topic);
    final originalConn = await firstConnB;

    workletB.disconnectFrom(workletA);
    await Future<void>.delayed(Duration.zero);

    expect(states.map((s) => s.state),
        [PearSwarmState.connected, PearSwarmState.reconnecting]);
    var dataClosed = false;
    originalConn.data.listen((_) {}, onDone: () => dataClosed = true);
    await Future<void>.delayed(Duration.zero);
    expect(dataClosed, isTrue,
        reason: 'the dropped PearConnection must close, never silently '
            'keep working');
    // The old connection object must refuse to write even AFTER the same
    // peer reconnects (checked further down) -- but it must already refuse
    // right here, before any reconnect, since PearMethod.connectionWrite is
    // keyed only by peer public key and would otherwise have no way to
    // tell "stale object" apart from "peer not connected at all".
    await expectLater(
      originalConn.write(Uint8List.fromList([1])),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.connectionClosed)),
    );

    // Simulate Hyperswarm's own automatic re-discovery finding B again.
    final secondConnB = swarmB.connections.first;
    hub.join(topic.hex, workletB);
    await Future<void>.delayed(Duration.zero);
    final reconnectedConn = await secondConnB;

    expect(states.map((s) => s.state), [
      PearSwarmState.connected,
      PearSwarmState.reconnecting,
      PearSwarmState.connected,
    ]);
    expect(identical(reconnectedConn, originalConn), isFalse,
        reason: 'a reconnect is a NEW PearConnection object, never the old '
            '(already-closed) one reused -- connections are ephemeral');
    expect(reconnectedConn.remotePublicKey, originalConn.remotePublicKey,
        reason: 'same remote peer, new connection object');
    // The OLD connection must still refuse to write even now that the SAME
    // peer has a live, reconnected connection -- this is exactly the case
    // PearMethod.connectionWrite's peer-hex keying alone could not catch
    // (it would happily deliver to the peer's new connection instead).
    await expectLater(
      originalConn.write(Uint8List.fromList([2])),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.connectionClosed)),
    );
    // The NEW connection, meanwhile, must work normally.
    await reconnectedConn.write(Uint8List.fromList([3]));

    await sub.cancel();
    await rpcA.dispose();
    await rpcB.dispose();
  });

  test(
      'a peer already connected via one shared topic still gets connected '
      'on a SECOND shared topic -- FakeBareWorklet.isNew is scoped per '
      '(peer, topic), not per peer alone (E6.5 conformance fix)', () async {
    // Hyperswarm shares ONE physical connection across every topic that
    // finds it (see PearSwarm._wire's own doc, and pear-end/index.js's
    // info.topics/info.on('topic', ...) handling) -- so pear-end's real
    // announce() fires its own fresh SWARM_CONNECTION + CONNECTED for
    // EACH topic a peer is discovered on, even ones discovered after an
    // already-live connection to that same peer. A worklet that instead
    // gated this on "have I ever connected to this PEER before" (ignoring
    // which topic) would silently strand every topic after the first.
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final topic1 = topic;
    final topic2 = PearCrypto.topicFromString('swarm-test-second-topic');

    final swarm1B = await PearSwarm.join(rpcB, topic1);
    final firstConn1B = swarm1B.connections.first;
    await PearSwarm.join(rpcA, topic1);
    await firstConn1B; // topic1 connects normally first

    final swarm2B = await PearSwarm.join(rpcB, topic2);
    final states2 = <PearSwarmStatus>[];
    final sub2 = swarm2B.state.listen(states2.add);
    final firstConn2B = swarm2B.connections.first;
    await PearSwarm.join(rpcA, topic2);
    final conn2 = await firstConn2B.timeout(const Duration(seconds: 2));
    // connections.first resolving only proves the swarmConnection event
    // arrived -- _connectTo emits the swarmLifecycle CONNECTED event right
    // after it, but that's a separate stream hop (PearRpc._onFrame ->
    // PearRpc.events -> PearSwarm's own listener) that isn't guaranteed to
    // have finished routing yet just because connections.first's Future
    // already settled.
    await Future<void>.delayed(Duration.zero);

    expect(states2.map((s) => s.state), [PearSwarmState.connected]);
    expect(conn2.remotePublicKey.hex, workletA.peerKey);

    await sub2.cancel();
    await rpcA.dispose();
    await rpcB.dispose();
  });
}
