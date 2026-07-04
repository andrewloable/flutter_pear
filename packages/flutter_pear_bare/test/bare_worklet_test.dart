import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_pear_bare/flutter_pear_bare.dart';
import 'package:flutter_test/flutter_test.dart';

// flutter_pear-5rl codec-conformance note: the tests below that round-trip
// bytes through `messenger.handlePlatformMessage`/`setMockMessageHandler`
// using the REAL `StandardMessageCodec` (not a hand-rolled stub) are a cheap
// regression guard against a future accidental codec/channel change -- but
// they run host-side only and can NEVER reach the real Android engine/JNI
// bridge, which is exactly where the BinaryCodec bug this project already
// hit once (E1.3-E2.5: silently delivered empty data on every native-to-Dart
// send) actually lived. That real-device coverage lives in
// flutter_pear_example/integration_test/ipc_transport_test.dart instead --
// see its doc comment.

/// Prefixes [bytes] with the 4-byte big-endian length BareWorklet.send/
/// _onIpc use on the wire (E4.4) -- mirrors pear-end/index.js's writeFramed.
Uint8List _framed(List<int> bytes) {
  final prefixed = Uint8List(4 + bytes.length);
  ByteData.sublistView(prefixed).setUint32(0, bytes.length, Endian.big);
  prefixed.setRange(4, prefixed.length, bytes);
  return prefixed;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const control = MethodChannel('flutter_pear_bare/control');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    // Native side is faked: every control call succeeds.
    messenger.setMockMethodCallHandler(control, (_) async => null);
  });

  tearDown(() => messenger.setMockMethodCallHandler(control, null));

  test('start → running, terminate → stopped', () async {
    final w = await BareWorklet.start();
    expect(w.state, WorkletState.running);

    await w.terminate();
    expect(w.state, WorkletState.stopped);
  });

  test(
      'start() while already running (same isolate) reattaches to the SAME '
      'instance -- native "start" is never invoked a second time (E6.3)',
      () async {
    // NOTE: this only proves the Dart-side singleton guard (BareWorklet.
    // _instance) within ONE isolate -- a real Dart hot restart resets that
    // static field to null, so the actual "detect and reattach to an
    // already-running NATIVE worklet across a hot restart" guarantee lives
    // entirely in FlutterPearBarePlugin.kt's companion-object worklet/
    // workletIpc persistence (see its own doc comment), which no Dart-only
    // mocked-platform-channel test can exercise -- that needs a real
    // device/integration test.
    final calls = <String>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call.method);
      return {'reattached': false};
    });

    final first = await BareWorklet.start();
    final second = await BareWorklet.start();

    expect(identical(first, second), isTrue,
        reason: 'within the SAME isolate generation a second start() call '
            'must reattach to the already-running worklet, not reboot it');
    expect(calls, ['start']);
    await first.terminate();
  });

  test(
      'start() surfaces whether native reattached to an existing worklet or '
      'booted a fresh one, via BareWorklet.reattached (E6.3)', () async {
    messenger.setMockMethodCallHandler(
        control, (_) async => {'reattached': true});
    final reattached = await BareWorklet.start();
    expect(reattached.reattached, isTrue);
    await reattached.terminate();

    messenger.setMockMethodCallHandler(
        control, (_) async => {'reattached': false});
    final fresh = await BareWorklet.start();
    expect(fresh.reattached, isFalse);
    await fresh.terminate();
  });

  test('send while not running throws', () async {
    final w = await BareWorklet.start();
    await w.terminate();
    await expectLater(w.send(Uint8List(0)), throwsStateError);
  });

  test('suspend() → suspended, resume() → running (E6.1)', () async {
    final w = await BareWorklet.start();
    expect(w.state, WorkletState.running);

    await w.suspend();
    expect(w.state, WorkletState.suspended);

    await w.resume();
    expect(w.state, WorkletState.running);

    await w.terminate();
  });

  test(
      'suspend() while already suspended is a no-op -- native "suspend" is '
      'never invoked a second time (E6.1 idempotency)', () async {
    final w = await BareWorklet.start();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call.method);
      return null;
    });

    await w.suspend();
    await w.suspend();
    await w.suspend();

    expect(w.state, WorkletState.suspended);
    expect(calls, ['suspend']);
    await w.terminate();
  });

  test(
      'resume() while already running is a no-op -- native "resume" is '
      'never invoked (E6.1 idempotency)', () async {
    final w = await BareWorklet.start();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call.method);
      return null;
    });

    await w.resume();
    await w.resume();

    expect(w.state, WorkletState.running);
    expect(calls, isEmpty);
    await w.terminate();
  });

  test(
      'suspend()/resume() while stopped are no-ops -- neither reaches the '
      'native side (E6.1 idempotency)', () async {
    final w = await BareWorklet.start();
    await w.terminate();
    final calls = <String>[];
    messenger.setMockMethodCallHandler(control, (call) async {
      calls.add(call.method);
      return null;
    });

    await w.suspend();
    await w.resume();

    expect(w.state, WorkletState.stopped);
    expect(calls, isEmpty);
  });

  test(
      'a native onWorkletExit while suspended still stops the worklet -- '
      'the E2.6 backstop is not gated on state (E6.1)', () async {
    final w = await BareWorklet.start();
    await w.suspend();
    expect(w.state, WorkletState.suspended);

    var incomingClosed = false;
    w.incoming.listen((_) {}, onDone: () => incomingClosed = true);

    const codec = StandardMethodCodec();
    const call = MethodCall(
        'onWorkletExit', {'reason': 'worklet IPC ended unexpectedly'});
    await messenger.handlePlatformMessage(
      'flutter_pear_bare/control',
      codec.encodeMethodCall(call),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(w.state, WorkletState.stopped);
    expect(incomingClosed, isTrue);
  });

  test(
      'send() prefixes the frame with its 4-byte big-endian length '
      '(E4.4 framing)', () async {
    final w = await BareWorklet.start();
    const codec = StandardMessageCodec();
    Uint8List? sent;
    messenger.setMockMessageHandler('flutter_pear_bare/ipc', (message) async {
      sent = codec.decodeMessage(message) as Uint8List?;
      return null;
    });

    await w.send(Uint8List.fromList([7, 8, 9]));

    expect(sent, _framed([7, 8, 9]));
    messenger.setMockMessageHandler('flutter_pear_bare/ipc', null);
    await w.terminate();
  });

  test(
      'a native onWorkletExit control call fires onCrash and stops the '
      'worklet (E2.6 backstop)', () async {
    final w = await BareWorklet.start();
    expect(w.state, WorkletState.running);

    final crashes = <WorkletCrash>[];
    final crashSub = w.onCrash.listen(crashes.add);
    var incomingClosed = false;
    w.incoming.listen((_) {}, onDone: () => incomingClosed = true);

    const codec = StandardMethodCodec();
    const call = MethodCall(
        'onWorkletExit', {'reason': 'worklet IPC ended unexpectedly'});
    await messenger.handlePlatformMessage(
      'flutter_pear_bare/control',
      codec.encodeMethodCall(call),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(w.state, WorkletState.stopped);
    expect(crashes, hasLength(1));
    expect(crashes.single.reason, 'worklet IPC ended unexpectedly');
    expect(crashes.single.detail, isNull);
    expect(incomingClosed, isTrue);
    await crashSub.cancel();
  });

  test(
      'a stale generation\'s onWorkletExit reaching a NEWER generation\'s '
      'handler is dropped, not misattributed (flutter_pear-3vh)', () async {
    // _control/_ipc are static, shared across every BareWorklet instance --
    // Flutter buffers a channel message that arrives with no handler
    // currently registered and replays it to whichever handler registers
    // next, so a stale generation-1 exit report delayed past a kill+restart
    // could otherwise land on generation 2's handler. This simulates
    // exactly that delivery (not the race itself, which needs a real
    // platform channel) to prove the generationId mismatch drops it.
    messenger.setMockMethodCallHandler(
        control, (_) async => {'reattached': false, 'generationId': 1});
    final first = await BareWorklet.start();
    await first.terminate();

    messenger.setMockMethodCallHandler(
        control, (_) async => {'reattached': false, 'generationId': 2});
    final second = await BareWorklet.start();
    expect(second.state, WorkletState.running);

    final crashes = <WorkletCrash>[];
    final crashSub = second.onCrash.listen(crashes.add);

    const codec = StandardMethodCodec();
    const staleCall =
        MethodCall('onWorkletExit', {'reason': 'stale', 'generationId': 1});
    await messenger.handlePlatformMessage(
      'flutter_pear_bare/control',
      codec.encodeMethodCall(staleCall),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(second.state, WorkletState.running,
        reason: 'a stale generation\'s exit report must not stop a newer, '
            'healthy generation');
    expect(crashes, isEmpty);

    // A genuine exit naming generation 2's OWN id still works.
    const genuineCall = MethodCall('onWorkletExit',
        {'reason': 'worklet IPC ended unexpectedly', 'generationId': 2});
    await messenger.handlePlatformMessage(
      'flutter_pear_bare/control',
      codec.encodeMethodCall(genuineCall),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(second.state, WorkletState.stopped);
    expect(crashes, hasLength(1));
    await crashSub.cancel();
  });

  test(
      'onWorkletExit with no generationId at all (older native / no-generation '
      'fake) still works -- backward compatible when neither side sends one',
      () async {
    messenger.setMockMethodCallHandler(
        control, (_) async => {'reattached': false});
    final w = await BareWorklet.start();
    expect(w.state, WorkletState.running);

    final crashes = <WorkletCrash>[];
    final crashSub = w.onCrash.listen(crashes.add);

    const codec = StandardMethodCodec();
    const call = MethodCall(
        'onWorkletExit', {'reason': 'worklet IPC ended unexpectedly'});
    await messenger.handlePlatformMessage(
      'flutter_pear_bare/control',
      codec.encodeMethodCall(call),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(w.state, WorkletState.stopped);
    expect(crashes, hasLength(1));
    await crashSub.cancel();
  });

  test(
      'a frame split across two platform-channel deliveries is reassembled '
      '(E4.4 length-prefix framing)', () async {
    final w = await BareWorklet.start();
    final frames = <Uint8List>[];
    final sub = w.incoming.listen(frames.add);

    const codec = StandardMessageCodec();
    final prefixed = _framed([10, 20, 30, 40, 50]);
    final firstPart = prefixed.sublist(0, 3); // splits mid-length-prefix
    final secondPart = prefixed.sublist(3);

    await messenger.handlePlatformMessage(
        'flutter_pear_bare/ipc', codec.encodeMessage(firstPart), (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(frames, isEmpty,
        reason: 'an incomplete frame must not be delivered yet');

    await messenger.handlePlatformMessage(
        'flutter_pear_bare/ipc', codec.encodeMessage(secondPart), (_) {});
    await Future<void>.delayed(Duration.zero);
    expect(frames, hasLength(1));
    expect(frames.single, [10, 20, 30, 40, 50]);

    await sub.cancel();
    await w.terminate();
  });

  test(
      'two frames coalesced into a single platform-channel delivery are '
      'split apart correctly (E4.4 length-prefix framing)', () async {
    final w = await BareWorklet.start();
    final frames = <Uint8List>[];
    final sub = w.incoming.listen(frames.add);

    const codec = StandardMessageCodec();
    final combined = Uint8List.fromList([
      ..._framed([1, 2, 3]),
      ..._framed([4, 5])
    ]);

    await messenger.handlePlatformMessage(
        'flutter_pear_bare/ipc', codec.encodeMessage(combined), (_) {});
    await Future<void>.delayed(Duration.zero);

    expect(frames, hasLength(2));
    expect(frames[0], [1, 2, 3]);
    expect(frames[1], [4, 5]);

    await sub.cancel();
    await w.terminate();
  });
}
