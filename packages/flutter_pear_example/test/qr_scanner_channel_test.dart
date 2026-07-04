import 'package:flutter/services.dart';
import 'package:flutter_pear_example/qr_scanner_channel.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pure-logic coverage for E7.2's native QR scanner bridge -- no real
/// camera/native channel involved, only the Dart-side string<->enum
/// contract and error propagation (mirrors flutter_pear_bare's own
/// `setMockMethodCallHandler` pattern in `bare_worklet_test.dart`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_pear_example/qr_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('CameraPermissionStatus round-trips through the channel', () {
    const cases = {
      'granted': CameraPermissionStatus.granted,
      'denied': CameraPermissionStatus.denied,
      'permanentlyDenied': CameraPermissionStatus.permanentlyDenied,
      'notDetermined': CameraPermissionStatus.notDetermined,
    };

    for (final entry in cases.entries) {
      test('checkPermission parses "${entry.key}"', () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'checkCameraPermission');
          return entry.key;
        });
        expect(await QrScannerChannel.checkPermission(), entry.value);
      });

      test('requestPermission parses "${entry.key}"', () async {
        messenger.setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'requestCameraPermission');
          return entry.key;
        });
        expect(await QrScannerChannel.requestPermission(), entry.value);
      });
    }

    test('an unrecognized raw value throws FormatException, not a silent '
        'wrong status', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => 'bogus');
      expect(QrScannerChannel.checkPermission(), throwsFormatException);
    });
  });

  group('scanQrCode', () {
    test('returns the decoded payload on a successful scan', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'scanQrCode');
        return 'the-decoded-qr-payload';
      });
      expect(await QrScannerChannel.scanQrCode(), 'the-decoded-qr-payload');
    });

    test('returns null when the user backs out without scanning anything',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      expect(await QrScannerChannel.scanQrCode(), isNull);
    });

    test('a PERMISSION_DENIED PlatformException travels to the caller',
        () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(code: 'PERMISSION_DENIED');
      });
      expect(
        QrScannerChannel.scanQrCode(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'PERMISSION_DENIED'),
        ),
      );
    });
  });

  group('openAppSettings', () {
    test('invokes the native "openAppSettings" method', () async {
      var invoked = false;
      messenger.setMockMethodCallHandler(channel, (call) async {
        invoked = true;
        expect(call.method, 'openAppSettings');
        return true;
      });
      await QrScannerChannel.openAppSettings();
      expect(invoked, isTrue);
    });
  });
}
