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

  test('send while not running throws', () async {
    final w = await BareWorklet.start();
    await w.terminate();
    await expectLater(w.send(Uint8List(0)), throwsStateError);
  });

  test('send() prefixes the frame with its 4-byte big-endian length '
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
    final combined = Uint8List.fromList([..._framed([1, 2, 3]), ..._framed([4, 5])]);

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
