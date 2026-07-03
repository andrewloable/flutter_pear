import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_pear_bare/flutter_pear_bare.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
