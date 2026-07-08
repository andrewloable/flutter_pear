import 'package:flutter/services.dart';
import 'package:flutter_pear_example/share_open_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-logic coverage for the open/share native bridge -- no real
/// FileProvider/UIDocumentInteractionController involved, only the Dart-side
/// method/argument contract and the false-means-no-handler convention
/// (mirrors file_picker_channel_test.dart's `setMockMethodCallHandler`
/// pattern).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_pear_example/share_open');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('openFile', () {
    test('invokes openFile with the path and returns true when handled',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'openFile');
        expect(call.arguments, {'path': '/received/alice/photo.png'});
        return true;
      });
      expect(await ShareOpenChannel.openFile('/received/alice/photo.png'),
          isTrue);
    });

    test('returns false when no app can handle the file', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await ShareOpenChannel.openFile('/received/alice/doc.pdf'),
          isFalse);
    });

    test('a PlatformException travels to the caller', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'INVALID_ARGS');
      });
      expect(
        ShareOpenChannel.openFile('/received/alice/photo.png'),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'INVALID_ARGS'),
        ),
      );
    });
  });

  group('shareFile', () {
    test('invokes shareFile with the path and returns true when handled',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'shareFile');
        expect(call.arguments, {'path': '/received/alice/photo.png'});
        return true;
      });
      expect(await ShareOpenChannel.shareFile('/received/alice/photo.png'),
          isTrue);
    });

    test('returns false when no app can handle the share', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await ShareOpenChannel.shareFile('/received/alice/doc.pdf'),
          isFalse);
    });
  });

  group('shareText', () {
    test('invokes shareText with the text and returns true when handled',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'shareText');
        expect(call.arguments, {'text': 'pear://invite/abc123'});
        return true;
      });
      expect(await ShareOpenChannel.shareText('pear://invite/abc123'),
          isTrue);
    });

    test('returns false when no app can handle the share', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => false);
      expect(await ShareOpenChannel.shareText('some text'), isFalse);
    });
  });
}
