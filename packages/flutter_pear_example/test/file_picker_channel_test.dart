import 'package:flutter/services.dart';
import 'package:flutter_pear_example/file_picker_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-logic coverage for the hand-rolled SAF file picker bridge -- no real
/// document picker/native channel involved, only the Dart-side map<->record
/// contract and error propagation (mirrors qr_scanner_channel_test.dart's
/// `setMockMethodCallHandler` pattern).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_pear_example/file_picker');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('pickFile', () {
    test('returns the picked path and name on a successful pick', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'pickFile');
        return {'path': '/cache/picked_files/photo.png', 'name': 'photo.png'};
      });
      final picked = await FilePickerChannel.pickFile();
      expect(picked, isNotNull);
      expect(picked!.path, '/cache/picked_files/photo.png');
      expect(picked.name, 'photo.png');
    });

    test('returns null when the user backs out without picking anything',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await FilePickerChannel.pickFile(), isNull);
    });

    test('a FILE_PICK_FAILED PlatformException travels to the caller',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'FILE_PICK_FAILED');
      });
      expect(
        FilePickerChannel.pickFile(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'FILE_PICK_FAILED'),
        ),
      );
    });
  });
}
