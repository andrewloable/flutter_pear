import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/src/exceptions.dart';
import 'package:flutter_pear/src/rpc.dart';
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_bare/flutter_pear_bare.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// A minimal [WorkletIpc] double: records sent frames, and lets a test push
/// a response frame onto [incoming] whenever it wants. No real worklet, no
/// platform channel -- exactly the fake `PearRpc` needs to test its own
/// timeout/dispose bookkeeping in isolation.
class _FakeWorklet implements WorkletIpc {
  final sentFrames = <Map<String, Object?>>[];
  final _incoming = StreamController<Uint8List>.broadcast();
  final _crash = StreamController<WorkletCrash>.broadcast();

  /// When set, the next [send] rejects with this instead of recording the
  /// frame -- simulates the worklet already being unreachable.
  Object? failNextSendWith;

  /// Stamped onto every frame [sendJsonFrame]/[respond] send, matching the
  /// real worklet's per-frame nonce (E2.5). Change it mid-test to simulate a
  /// different worklet generation.
  String sessionNonce = 'test-session-nonce';

  @override
  Stream<Uint8List> get incoming => _incoming.stream;

  @override
  Stream<WorkletCrash> get onCrash => _crash.stream;

  /// Simulates the native-detected crash backstop (E2.6) -- no detail, like
  /// the real one.
  void simulateNativeCrash(String reason) {
    _crash.add((reason: reason, detail: null));
  }

  @override
  Future<void> send(Uint8List frame) async {
    final failure = failNextSendWith;
    if (failure != null) {
      failNextSendWith = null;
      throw failure;
    }
    // Every real outbound call goes through this -- checking the
    // discriminator here gives every existing test in this file implicit
    // coverage of correct outbound framing, not just the tests that ask for
    // it explicitly.
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
    sendRawFrame(
      PearFrameType.json,
      utf8.encode(jsonEncode({
        ...body,
        PearHandshakeField.envelopeNonce: sessionNonce,
      })),
    );
  }

  /// Pushes a frame with an arbitrary [frameType] byte and [body] onto
  /// [incoming] -- for simulating [PearFrameType.raw], unknown bytes, or a
  /// [PearFrameType.json] frame with a deliberately malformed body.
  void sendRawFrame(int frameType, List<int> body) {
    _incoming.add(Uint8List.fromList([frameType, ...body]));
  }
}

void main() {
  late _FakeWorklet worklet;
  late PearRpc rpc;

  setUp(() {
    worklet = _FakeWorklet();
    rpc = PearRpc(worklet);
  });

  tearDown(() async => rpc.dispose());

  test('call completes with the ok payload on a normal response', () async {
    final future = rpc.call('echo', {'x': 1});
    worklet.respond(worklet.lastRequestId, ok: {'x': 1});
    expect(await future, {'x': 1});
  });

  test('call completes with a PearException on an err response', () async {
    final future = rpc.call('boom');
    worklet.respond(worklet.lastRequestId,
        err: {'message': 'kaboom', 'code': 'FORCED_ERROR'});
    await expectLater(
      future,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', 'FORCED_ERROR')
          .having((e) => e.message, 'message', 'kaboom')),
    );
  });

  test('a connection-class code routes to PearConnectionException', () async {
    final future = rpc.call('connection.write');
    worklet.respond(worklet.lastRequestId, err: {
      'message': 'unknown peer: abcd',
      'code': PearErrorCode.unknownPeer,
      'stack': 'Error: unknown peer\n    at handle',
    });
    await expectLater(
      future,
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownPeer)
          .having((e) => e.message, 'message', 'unknown peer: abcd')
          .having(
              (e) => e.stack, 'stack', 'Error: unknown peer\n    at handle')),
    );
  });

  test('a storage-class code routes to PearStorageException', () async {
    final future = rpc.call('store.get');
    worklet.respond(worklet.lastRequestId, err: {
      'message': 'corestore closed',
      'code': PearErrorCode.storageUnavailable,
      'stack': 'Error: corestore closed\n    at handle',
    });
    await expectLater(
      future,
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.storageUnavailable)
          .having((e) => e.message, 'message', 'corestore closed')
          .having((e) => e.stack, 'stack',
              'Error: corestore closed\n    at handle')),
    );
  });

  test('an unregistered code falls back to the base PearException safely',
      () async {
    final future = rpc.call('whatever');
    worklet.respond(worklet.lastRequestId, err: {
      'message': 'something else went wrong',
      'code': 'SOME_FUTURE_CODE_THIS_SCHEMA_DOES_NOT_KNOW',
    });
    await expectLater(
      future,
      throwsA(
        allOf(
          isA<PearException>().having((e) => e.code, 'code',
              'SOME_FUTURE_CODE_THIS_SCHEMA_DOES_NOT_KNOW'),
          isNot(isA<PearConnectionException>()),
          isNot(isA<PearStorageException>()),
        ),
      ),
    );
  });

  test('an unanswered call times out with a typed PearException', () async {
    final future =
        rpc.call('never.answers', null, const Duration(milliseconds: 20));
    await expectLater(
      future,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.rpcTimeout)),
    );
  });

  test('dispose fails all pending calls with a typed PearException', () async {
    final a = rpc.call('never.answers');
    final b = rpc.call('also.never.answers');
    // Attach the expectation before dispose() runs: dispose() completes
    // these with an error synchronously, and a Future that completes with
    // an error before anything is listening reports itself to the zone as
    // an unhandled error instead of waiting to be caught later.
    final expectA = expectLater(
      a,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletDisposed)),
    );
    final expectB = expectLater(
      b,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletDisposed)),
    );
    await rpc.dispose();
    await expectA;
    await expectB;
  });

  test('a response arriving after timeout is ignored, not a crash', () async {
    final future = rpc.call('slow', null, const Duration(milliseconds: 20));
    final id = worklet.lastRequestId;
    await expectLater(
      future,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.rpcTimeout)),
    );

    // Arrives after the timeout already resolved the call's Future. If this
    // wrongly tried to complete it again, Dart would throw "Future already
    // completed" inside the stream listener -- an uncaught async error that
    // flutter_test's zone would fail this test with.
    worklet.respond(id, ok: {'too': 'late'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test('a response arriving after dispose is ignored, not a crash', () async {
    final future = rpc.call('never.answers');
    final id = worklet.lastRequestId;
    final expectation = expectLater(
      future,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletDisposed)),
    );
    await rpc.dispose();
    await expectation;

    worklet.respond(id, ok: {'too': 'late'});
    await Future<void>.delayed(const Duration(milliseconds: 10));
  });

  test('a send failure settles the call immediately with SEND_FAILED',
      () async {
    worklet.failNextSendWith = StateError('worklet is not running');
    // A short timeout here is just insurance so a regression fails this
    // test fast (wrong code) instead of slow (right code, 10s late) --
    // the send failure itself should settle the call well before this
    // fires either way.
    final future = rpc.call(
        'never.reaches.worklet', null, const Duration(milliseconds: 200));
    await expectLater(
      future,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.sendFailed)),
    );
  });

  test('call() after dispose() fails immediately with WORKLET_DISPOSED',
      () async {
    await rpc.dispose();
    await expectLater(
      rpc.call('too.late'),
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletDisposed)),
    );
    // Never even reached _worklet.send.
    expect(worklet.sentFrames, isEmpty);
  });

  test('a raw (0x01) frame is surfaced as a diagnostic event, not dropped',
      () async {
    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    worklet.sendRawFrame(PearFrameType.raw, utf8.encode('some raw bytes'));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.rpcDiagnostic);
    expect((events.single.payload! as Map)['frameType'], PearFrameType.raw);
    await sub.cancel();
  });

  test('an unrecognized frame-type byte is surfaced as a diagnostic event',
      () async {
    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    worklet.sendRawFrame(0x7f, const []);
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.rpcDiagnostic);
    expect((events.single.payload! as Map)['frameType'], 0x7f);
    await sub.cancel();
  });

  test(
      'malformed JSON after a valid discriminator is surfaced, not silently '
      'dropped', () async {
    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    worklet.sendRawFrame(PearFrameType.json, utf8.encode('{not valid json'));
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.rpcDiagnostic);
    await sub.cancel();
  });

  test('a swarm event still round-trips through the discriminator byte',
      () async {
    // Events are only accepted once a session is established (see the
    // nonce tests below) -- a real response first, matching how
    // Pear.start's attach.info round trip always precedes anything else.
    final attach = rpc.call('attach.info');
    worklet.respond(worklet.lastRequestId, ok: {});
    await attach;

    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    worklet.sendJsonFrame({
      'ev': PearEventName.swarmConnection,
      'p': {'topic': 'abcd', 'peer': 'ef01'},
    });
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.swarmConnection);
    expect((events.single.payload! as Map)['peer'], 'ef01');
    await sub.cancel();
  });

  test(
      'a well-formed JSON object matching neither response nor event is '
      'surfaced, not silently dropped', () async {
    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    // Valid JSON, valid object -- but no numeric 'id' and no string 'ev',
    // so it's neither a response nor an event. Same "shape we don't
    // recognize" case as an unparseable body or a non-object, so it gets
    // the same diagnostic treatment rather than vanishing silently.
    worklet.sendJsonFrame({'unexpected': 'shape'});
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.rpcDiagnostic);
    await sub.cancel();
  });

  test('attach.info returns the worklet\'s nonce and bundle version',
      () async {
    final future = rpc.call(PearMethod.attachInfo);
    worklet.respond(worklet.lastRequestId, ok: {
      PearHandshakeField.nonce: 'abc123',
      PearHandshakeField.bundleVersion: 'v1',
    });
    final result = await future as Map;
    expect(result[PearHandshakeField.nonce], 'abc123');
    expect(result[PearHandshakeField.bundleVersion], 'v1');
  });

  test(
      'an event from a stale worklet generation is dropped without side '
      'effects, even arriving after the current session is established',
      () async {
    // Establish the session, exactly as Pear.start's attach.info round trip
    // does first.
    final attach = rpc.call(PearMethod.attachInfo);
    worklet.respond(worklet.lastRequestId, ok: {});
    await attach;

    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);

    // A straggler event from a DIFFERENT (killed/replaced) worklet
    // generation -- same shape as a real swarm.connection, wrong nonce.
    worklet.sessionNonce = 'a-different-stale-generation';
    worklet.sendJsonFrame({
      'ev': PearEventName.swarmConnection,
      'p': {'topic': 'stale', 'peer': 'stale-peer'},
    });
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty,
        reason: 'stale-generation event must be dropped silently, not '
            'forwarded and not even reported as a diagnostic');
    await sub.cancel();
  });

  test(
      'a response is accepted regardless of nonce -- protected by '
      'request-id uniqueness instead', () async {
    // Establish the session first.
    final attach = rpc.call(PearMethod.attachInfo);
    worklet.respond(worklet.lastRequestId, ok: {});
    await attach;

    // A DIFFERENT call, answered by a "stale generation" nonce. Still
    // settles correctly: request ids are randomly generated (see
    // PearRpc._generateId), so a response can only ever match the call
    // that's actually waiting on that specific id -- nonce-checking
    // responses would be redundant, not protective.
    final future = rpc.call('some.method');
    worklet.sessionNonce = 'a-different-stale-generation';
    worklet.respond(worklet.lastRequestId, ok: {'done': true});

    expect(await future, {'done': true});
  });

  test('a native-detected crash fails all pending calls with WORKLET_CRASHED',
      () async {
    final a = rpc.call('never.answers');
    final b = rpc.call('also.never.answers');
    final expectA = expectLater(
      a,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );
    final expectB = expectLater(
      b,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );
    worklet.simulateNativeCrash('worklet IPC ended unexpectedly');
    await expectA;
    await expectB;
  });

  test('a native-detected crash is surfaced as a workletCrash event',
      () async {
    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    worklet.simulateNativeCrash('worklet IPC ended unexpectedly');
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.workletCrash);
    expect((events.single.payload! as Map)['reason'],
        'worklet IPC ended unexpectedly');
    await sub.cancel();
  });

  test('a worklet-reported crash event fails pending calls and is exposed',
      () async {
    // Establish a session first -- crash events, like any other event,
    // need a nonce-matched session to be accepted.
    final attach = rpc.call(PearMethod.attachInfo);
    worklet.respond(worklet.lastRequestId, ok: {});
    await attach;

    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    final pending = rpc.call('never.answers');
    final expectPending = expectLater(
      pending,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );

    worklet.sendJsonFrame({
      'ev': PearEventName.workletCrash,
      'p': {
        'kind': 'uncaughtException',
        'message': 'boom',
        'stack': 'Error: boom\n    at somewhere',
      },
    });

    await expectPending;
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.workletCrash);
    final payload = events.single.payload! as Map;
    expect(payload['reason'], 'uncaughtException');
    expect(payload['detail'], contains('boom'));
    expect(payload['detail'], contains('at somewhere'));
    await sub.cancel();
  });

  test(
      'a worklet-reported crash event with a stale nonce is dropped once a '
      'session is established -- the pre-session exemption does not widen '
      'to an established one', () async {
    // Establish the session first, exactly like the "honored" tests above.
    final attach = rpc.call(PearMethod.attachInfo);
    worklet.respond(worklet.lastRequestId, ok: {});
    await attach;

    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    final pending = rpc.call('never.answers');

    // A straggler crash report from a DIFFERENT (killed/replaced) worklet
    // generation -- same shape as a real self-report, wrong nonce. Once a
    // session is established, this must be gated exactly like any other
    // event, not trusted just because its `ev` happens to be workletCrash.
    worklet.sessionNonce = 'a-different-stale-generation';
    worklet.sendJsonFrame({
      'ev': PearEventName.workletCrash,
      'p': {'kind': 'uncaughtException', 'message': 'not really'},
    });
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty,
        reason: 'stale-generation crash report must be dropped silently, '
            'not trusted just because it claims to be a crash');
    // The pending call is still alive -- unaffected by the dropped report.
    worklet.sessionNonce = 'test-session-nonce';
    worklet.respond(worklet.lastRequestId, ok: {'done': true});
    expect(await pending, {'done': true});
    await sub.cancel();
  });

  test('call() after a crash fails immediately with WORKLET_CRASHED',
      () async {
    worklet.simulateNativeCrash('worklet IPC ended unexpectedly');
    // onCrash is a broadcast stream; delivery to _crashSub's listener is
    // scheduled as a microtask, not synchronous -- give it a turn so
    // _crashed is actually set before probing call()'s guard.
    await Future<void>.delayed(Duration.zero);
    await expectLater(
      rpc.call('too.late'),
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );
    expect(worklet.sentFrames, isEmpty);
  });

  test(
      'a worklet-reported crash event is honored even before any session is '
      'established -- the highest-risk boot-time crash window', () async {
    // Deliberately no attach.info round trip first: this is the case where
    // the worklet throws before ever answering anything (a bug in
    // module-level JS, before its request handler is even reachable), so
    // _currentNonce is still null. The crash must not be silently dropped
    // by the ordinary event nonce gate (E2.5) -- see _onFrame's early,
    // nonce-gate-bypassing workletCrash check.
    final events = <PearEvent>[];
    final sub = rpc.events.listen(events.add);
    final pending = rpc.call('never.answers');
    final expectPending = expectLater(
      pending,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );

    worklet.sendJsonFrame({
      'ev': PearEventName.workletCrash,
      'p': {
        'kind': 'uncaughtException',
        'message': 'boot-time crash',
        'stack': 'Error: boot-time crash\n    at moduleLoad',
      },
    });

    await expectPending;
    await Future<void>.delayed(Duration.zero);
    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.workletCrash);
    final payload = events.single.payload! as Map;
    expect(payload['reason'], 'uncaughtException');
    expect(payload['detail'], contains('boot-time crash'));
    await sub.cancel();
  });

  test('two independent crash signals for the same crash are idempotent',
      () async {
    final future = rpc.call('never.answers');
    final expectation = expectLater(
      future,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );
    worklet.simulateNativeCrash('first signal');
    // A second, redundant signal (e.g. the JS self-report racing the
    // native backstop) must not attempt to re-settle already-settled
    // calls or emit a second event.
    worklet.simulateNativeCrash('second signal');
    await expectation;
  });

  test(
      'E3.3 fake-driven variant: a real FakeBareWorklet crash still fails '
      'pending calls with WORKLET_CRASHED (E2.6)', () async {
    // Same spine behavior as the hand-rolled _FakeWorklet tests above,
    // proven again here against flutter_pear_test's shared, conformance-
    // tested fake -- not just this file's own private test double.
    final fakeWorklet = FakeBareWorklet();
    final fakeRpc = PearRpc(fakeWorklet);
    await fakeRpc.call(PearMethod.attachInfo);

    final pending = fakeRpc.call('never.answers');
    final expectation = expectLater(
      pending,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );
    fakeWorklet.simulateNativeCrash(reason: 'test crash');
    await expectation;
    await fakeRpc.dispose();
  });

  test(
      'E3.3 fake-driven variant: a real FakeBareWorklet swallowing a '
      'request still times out with RPC_TIMEOUT, never hangs (E2.2)',
      () async {
    final fakeWorklet = FakeBareWorklet();
    final fakeRpc = PearRpc(fakeWorklet);
    await fakeRpc.call(PearMethod.attachInfo);

    fakeWorklet.swallowNextRequest();
    await expectLater(
      fakeRpc.call('never.answers', null, const Duration(milliseconds: 20)),
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.rpcTimeout)),
    );
    await fakeRpc.dispose();
  });

  test(
      'E3.3 fake-driven variant: a real FakeBareWorklet err.code still '
      'routes to the typed exception subtype (E2.3)', () async {
    final fakeWorklet = FakeBareWorklet();
    final fakeRpc = PearRpc(fakeWorklet);
    await fakeRpc.call(PearMethod.attachInfo);

    // The fake's own connection.write handler throws UNKNOWN_PEER for any
    // peer it never actually connected to -- a real err.code from real
    // fake logic, not an injected shortcut.
    await expectLater(
      fakeRpc.call(PearMethod.connectionWrite,
          {'peer': 'a' * 64, 'data': base64Encode(utf8.encode('x'))}),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownPeer)),
    );
    await fakeRpc.dispose();
  });

  test(
      'E3.3 fake-driven variant: a real FakeBareWorklet raw/unknown '
      'discriminator byte is still surfaced, not silently dropped (E2.4)',
      () async {
    final fakeWorklet = FakeBareWorklet();
    final fakeRpc = PearRpc(fakeWorklet);
    await fakeRpc.call(PearMethod.attachInfo);

    final events = <PearEvent>[];
    fakeRpc.events.listen(events.add);
    fakeWorklet.sendRawFrame(utf8.encode('whatever'));
    await Future<void>.delayed(Duration.zero);

    expect(events, hasLength(1));
    expect(events.single.name, PearEventName.rpcDiagnostic);
    await fakeRpc.dispose();
  });

  test(
      'E3.3 fake-driven variant: a real FakeBareWorklet stale-nonce event '
      'is still silently dropped once a session is established (E2.5)',
      () async {
    final fakeWorklet = FakeBareWorklet();
    final fakeRpc = PearRpc(fakeWorklet);
    await fakeRpc.call(PearMethod.attachInfo);

    final events = <PearEvent>[];
    fakeRpc.events.listen(events.add);
    fakeWorklet.sendStaleNonceEvent(
        PearEventName.swarmLifecycle, {'topic': 'abc', 'state': 'discovering'});
    await Future<void>.delayed(Duration.zero);

    expect(events, isEmpty);
    await fakeRpc.dispose();
  });
}
