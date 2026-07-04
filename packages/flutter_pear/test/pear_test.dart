import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/bundle_version.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_test/flutter_test.dart';

// E6.2/E6.3 coverage for Pear's own glue code -- unlike every other test in
// this package, this one goes through the FULL Pear.start() (a real
// BareWorklet, not FakeBareWorklet), with the native platform channels
// mocked directly (same technique as flutter_pear_bare's
// bare_worklet_test.dart), because what's covered here (suspend/resume/
// dispose serialization; the reattach-or-kill handshake) only exists in
// Pear's own glue code, unreachable through FakeBareWorklet (Pear.worklet
// is typed as the concrete BareWorklet class).

Uint8List _lengthPrefixed(Uint8List bytes) {
  final prefixed = Uint8List(4 + bytes.length);
  ByteData.sublistView(prefixed).setUint32(0, bytes.length, Endian.big);
  prefixed.setRange(4, prefixed.length, bytes);
  return prefixed;
}

Uint8List _jsonFrame(Map<String, Object?> body) {
  final encoded = utf8.encode(jsonEncode(body));
  return Uint8List(encoded.length + 1)
    ..[0] = PearFrameType.json
    ..setRange(1, encoded.length + 1, encoded);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const control = MethodChannel('flutter_pear_bare/control');
  const ipcChannel = 'flutter_pear_bare/ipc';
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const codec = StandardMessageCodec();
  const nonce = 'pear-test-session-nonce';

  // Per-test knobs for the attach.info response, keyed by the 1-indexed
  // count of attach.info calls made so far -- E6.3's reattach-or-kill tests
  // need the FIRST call to answer differently from a post-kill-restart
  // SECOND call (e.g. mismatched then matched, or unresponsive then
  // healthy), which a single fixed value every other test in this file
  // relies on can't express.
  late String Function(int callNumber) attachInfoVersion;
  late bool Function(int callNumber) attachInfoResponds;
  late int attachInfoCallCount;
  late List<String> controlCalls;
  // Whether the FIRST native "start" call in a given test reports a
  // reattach (the default -- most tests in this file simulate a hot
  // restart's reattach-or-kill decision) or a fresh boot (E6.3's
  // fresh-boot-gets-the-normal-timeout test overrides this to false).
  // A post-kill-restart's own "start" call is always reported as fresh,
  // matching real native behavior (nothing is "already running" once
  // BareWorklet.terminate() has run).
  late bool firstStartReattached;

  setUp(() {
    attachInfoVersion = (_) => kPearEndBundleVersion;
    attachInfoResponds = (_) => true;
    attachInfoCallCount = 0;
    controlCalls = [];
    firstStartReattached = true;
    var startCallCount = 0;
    messenger.setMockMethodCallHandler(control, (call) async {
      controlCalls.add(call.method);
      if (call.method == 'start') {
        startCallCount++;
        return {'reattached': startCallCount == 1 && firstStartReattached};
      }
      return null;
    });
    messenger.setMockMessageHandler(ipcChannel, (message) async {
      final bytes = codec.decodeMessage(message) as Uint8List;
      final length = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
      final frame = bytes.sublist(4, 4 + length);
      final decoded = jsonDecode(utf8.decode(frame.sublist(1))) as Map;
      final id = decoded['id'] as int;
      final method = decoded['m'] as String;
      if (method == PearMethod.attachInfo) {
        attachInfoCallCount++;
        final callNumber = attachInfoCallCount;
        if (!attachInfoResponds(callNumber)) {
          return null; // simulates an unresponsive worklet -- no reply ever arrives
        }
        scheduleMicrotask(() {
          messenger.handlePlatformMessage(
            ipcChannel,
            codec.encodeMessage(_lengthPrefixed(_jsonFrame({
              'id': id,
              'ok': {
                PearHandshakeField.bundleVersion: attachInfoVersion(callNumber)
              },
              'n': nonce,
            }))),
            (_) {},
          );
        });
        return null; // native's own reply.reply(null) -- BareWorklet.send discards it
      }
      // Delivered as its own native-initiated message, not this handler's
      // return value -- matches how BareWorklet actually receives RPC
      // responses (see bare_worklet.dart's own doc), and the microtask
      // scheduling keeps this genuinely asynchronous.
      scheduleMicrotask(() {
        messenger.handlePlatformMessage(
          ipcChannel,
          codec.encodeMessage(_lengthPrefixed(
              _jsonFrame({'id': id, 'ok': <String, Object?>{}, 'n': nonce}))),
          (_) {},
        );
      });
      return null; // native's own reply.reply(null) -- BareWorklet.send discards it
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(control, null);
    messenger.setMockMessageHandler(ipcChannel, null);
  });

  test('suspend() racing dispose() does not throw (E6.2 regression)', () async {
    // A Completer, not a fixed delay, gates the native "suspend" call so
    // this test deterministically controls exactly when it resolves --
    // relying on incidental timing (e.g. a short artificial delay) to
    // create the race window was tried first and turned out to NOT
    // reliably reproduce the bug (the mock control channel's scheduling
    // let dispose()'s "terminate" call and suspend()'s "suspend" call
    // settle together, masking the race).
    final suspendGate = Completer<void>();
    messenger.setMockMethodCallHandler(control, (call) async {
      if (call.method == 'suspend') await suspendGate.future;
      return null;
    });

    final pear = await Pear.start();
    final suspendFuture = pear.suspend();
    await Future<void>.delayed(Duration.zero); // let suspend() reach the gate
    final disposeFuture = pear.dispose();
    await Future<void>.delayed(
        Duration.zero); // let dispose() run as far as it can
    suspendGate.complete(); // now release the pending native "suspend" call
    await Future.wait([suspendFuture, disposeFuture]);
    // No explicit assertion beyond reaching here: before this fix,
    // notifyWorkletSuspended calling .add() on _rpc's already-closed
    // broadcast stream (closed by dispose() racing ahead of the still-
    // pending suspend()) threw an uncaught StateError that flutter_test's
    // zone fails THIS test with (same pattern as swarm_test.dart's "leave()
    // cancels..." test) -- so cleanly finishing the delay below IS the
    // assertion.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  test(
      'two overlapping unawaited suspend() calls notify PearSwarm.state '
      'exactly once, not twice (E6.2 regression)', () async {
    // Same Completer-gating rationale as the dispose race test above --
    // this lets the test assert, WHILE the gate is still held, that only
    // ONE native "suspend" invoke has started (proving the second
    // suspend() call is genuinely queued behind the first, not running
    // concurrently against a stale worklet.state snapshot).
    final gate = Completer<void>();
    var suspendInvokes = 0;
    messenger.setMockMethodCallHandler(control, (call) async {
      if (call.method == 'suspend') {
        suspendInvokes++;
        await gate.future;
      }
      return null;
    });

    final pear = await Pear.start();
    final swarm =
        await pear.join(PearCrypto.unsafeTopicFromString('pear-test-topic'));
    final states = <PearSwarmStatus>[];
    final sub = swarm.state.listen(states.add);

    final a = pear.suspend();
    final b = pear.suspend();
    await Future<void>.delayed(Duration.zero);
    expect(suspendInvokes, 1,
        reason: 'the second suspend() must be queued behind the first, not '
            'issue its own concurrent native invoke');
    gate.complete();
    await Future.wait([a, b]);
    await Future<void>.delayed(Duration.zero);

    expect(
      states.map((s) => s.state).where((s) => s == PearSwarmState.suspended),
      hasLength(1),
    );
    await sub.cancel();
    await pear.dispose();
  });

  test(
      'reattach: a healthy, version-matched worklet starts exactly once -- '
      'never killed and restarted (E6.3)', () async {
    final pear = await Pear.start();
    expect(controlCalls, ['start'],
        reason: 'a healthy, matched reattach must never call native '
            'terminate/start a second time');
    // BareWorklet._instance is a static field, shared across every test in
    // this file -- an undisposed pear here would leak into the NEXT test,
    // which would then silently reattach to this one instead of ever
    // calling native "start" itself.
    await pear.dispose();
  });

  test(
      'a fresh boot (never reattached) uses the normal callTimeout, not '
      'the short attachHealthTimeout -- a slow-but-legitimate cold boot '
      'must not be misclassified unhealthy (E6.3)', () async {
    firstStartReattached = false;
    final responseGate = Completer<void>();
    var attachInfoRequestSeen = false;
    messenger.setMockMessageHandler(ipcChannel, (message) async {
      final bytes = codec.decodeMessage(message) as Uint8List;
      final length = ByteData.sublistView(bytes, 0, 4).getUint32(0, Endian.big);
      final frame = bytes.sublist(4, 4 + length);
      final decoded = jsonDecode(utf8.decode(frame.sublist(1))) as Map;
      final id = decoded['id'] as int;
      if (decoded['m'] == PearMethod.attachInfo) {
        attachInfoRequestSeen = true;
        unawaited(responseGate.future.then((_) {
          messenger.handlePlatformMessage(
            ipcChannel,
            codec.encodeMessage(_lengthPrefixed(_jsonFrame({
              'id': id,
              'ok': {PearHandshakeField.bundleVersion: kPearEndBundleVersion},
              'n': nonce,
            }))),
            (_) {},
          );
        }));
      }
      return null;
    });

    final pearFuture = Pear.start();
    // Past attachHealthTimeout (3s) but well before callTimeout (10s) --
    // if the short bound governed this call (the bug this test guards
    // against), Pear.start() would already have failed with RPC_TIMEOUT
    // and taken the kill+restart branch by now, instead of still waiting
    // on this exact worklet's response.
    await Future<void>.delayed(const Duration(seconds: 4));
    expect(attachInfoRequestSeen, isTrue);
    responseGate.complete();
    final pear = await pearFuture;

    expect(controlCalls, ['start'],
        reason: 'the slow-but-eventually-answering fresh boot must not '
            'have been killed and restarted');
    await pear.dispose();
  });

  test(
      'a genuine worklet crash during the first attach.info propagates '
      'immediately -- it is NOT silently reinterpreted as merely unhealthy '
      'and retried (E6.3)', () async {
    // Never reply to attach.info -- the native onWorkletExit backstop
    // (simulated below) is what settles this pending call instead, not a
    // timeout.
    messenger.setMockMessageHandler(ipcChannel, (_) async => null);

    final pearFuture = Pear.start();
    await Future<void>.delayed(
        Duration.zero); // let attach.info actually go out

    const methodCodec = StandardMethodCodec();
    const crashCall = MethodCall(
        'onWorkletExit', {'reason': 'simulated crash during attach.info'});
    await messenger.handlePlatformMessage(
      'flutter_pear_bare/control',
      methodCodec.encodeMethodCall(crashCall),
      (_) {},
    );

    await expectLater(
      pearFuture,
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.workletCrashed)),
    );
    // No kill+restart was attempted -- a genuine crash is a materially
    // different problem than "just slow to answer" and must travel to the
    // caller immediately, not be silently papered over by a retry.
    expect(controlCalls, ['start']);
  });

  test(
      'reattach: a version mismatch on the first attach.info triggers '
      'exactly one kill+restart, then succeeds (E6.3)', () async {
    attachInfoVersion = (callNumber) =>
        callNumber == 1 ? 'a-stale-bundle-version' : kPearEndBundleVersion;

    final pear = await Pear.start();

    expect(controlCalls, ['start', 'terminate', 'start']);
    await pear.dispose();
  });

  test(
      'reattach: an unresponsive first attach.info (unhealthy) triggers '
      'exactly one kill+restart, then succeeds (E6.3)', () async {
    attachInfoResponds = (callNumber) => callNumber != 1;

    final pear = await Pear.start();

    expect(controlCalls, ['start', 'terminate', 'start']);
    await pear.dispose();
  });

  test(
      'reattach: a version mismatch that persists after the kill+restart '
      'throws BUNDLE_VERSION_MISMATCH (E6.3)', () async {
    attachInfoVersion = (_) => 'a-stale-bundle-version';

    await expectLater(
      Pear.start(),
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.bundleVersionMismatch)),
    );
    // Both attempts' worklets must be cleaned up (no leaked worklet/rpc) --
    // exactly two terminate calls, one per attempt.
    expect(controlCalls.where((m) => m == 'terminate'), hasLength(2));
  });

  test(
      'reattach: an unresponsive attach.info that persists after the '
      'kill+restart lets the failure propagate, not a masked mismatch '
      '(E6.3)', () async {
    attachInfoResponds = (_) => false;

    await expectLater(
      Pear.start(),
      throwsA(isA<PearException>()
          .having((e) => e.code, 'code', PearErrorCode.rpcTimeout)),
    );
    expect(controlCalls.where((m) => m == 'terminate'), hasLength(2));
  });
}
