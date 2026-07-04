import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pear_example/pairing_screens.dart';
import 'package:flutter_test/flutter_test.dart';

/// E7.2 coverage that doesn't need a real camera/native channel or worklet:
/// [JoinRoomScreen]'s three permission-state UI branches (mocked
/// "flutter_pear_example/qr_scanner" channel, same pattern as
/// `qr_scanner_channel_test.dart`) and the manual-code path's typed,
/// pre-network error for obviously-garbage input -- `base64Decode` throws
/// before `Pear.start()` is ever called, so this needs no worklet fake.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('flutter_pear_example/qr_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Future<void> pumpJoinScreen(
    WidgetTester tester,
    String permissionStatus,
  ) async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'checkCameraPermission') return permissionStatus;
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: JoinRoomScreen()));
    await tester.pumpAndSettle();
  }

  group('JoinRoomScreen permission-state branches', () {
    testWidgets('granted shows the Scan QR code button', (tester) async {
      await pumpJoinScreen(tester, 'granted');
      expect(find.text('Scan QR code'), findsOneWidget);
      expect(find.text('Enable camera'), findsNothing);
      expect(find.text('Grant camera access'), findsNothing);
      expect(find.text('Open Settings'), findsNothing);
    });

    testWidgets('notDetermined shows the Enable camera prompt',
        (tester) async {
      await pumpJoinScreen(tester, 'notDetermined');
      expect(find.text('Enable camera'), findsOneWidget);
      expect(find.text('Scan QR code'), findsNothing);
    });

    testWidgets('denied shows the Grant camera access prompt', (tester) async {
      await pumpJoinScreen(tester, 'denied');
      expect(find.text('Grant camera access'), findsOneWidget);
      expect(find.text('Scan QR code'), findsNothing);
    });

    testWidgets('permanentlyDenied shows the Open Settings prompt',
        (tester) async {
      await pumpJoinScreen(tester, 'permanentlyDenied');
      expect(find.text('Open Settings'), findsOneWidget);
      expect(find.text('Scan QR code'), findsNothing);
    });

    testWidgets(
      'the manual code field + Join button always render, regardless of '
      'permission state -- the never-dead-ends requirement',
      (tester) async {
        for (final status in [
          'granted',
          'denied',
          'permanentlyDenied',
          'notDetermined',
        ]) {
          await pumpJoinScreen(tester, status);
          expect(
            find.widgetWithText(ElevatedButton, 'Join'),
            findsOneWidget,
            reason: 'status: $status',
          );
          expect(
            find.byType(TextField),
            findsOneWidget,
            reason: 'status: $status',
          );
        }
      },
    );
  });

  group('manual code entry', () {
    testWidgets(
      'a garbage (non-base64) code shows a typed error immediately, never '
      'a hang',
      (tester) async {
        await pumpJoinScreen(tester, 'granted');

        await tester.enterText(find.byType(TextField), '!!!not-base64!!!');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Join'));
        await tester.pumpAndSettle();

        expect(find.textContaining('check it and try again'), findsOneWidget);
        // No spinner left behind -- the error resolved synchronously, before
        // ever reaching a Pear.start()/RPC round trip.
        expect(find.byType(CircularProgressIndicator), findsNothing);
      },
    );

    testWidgets('an empty code does nothing (no error, no crash)',
        (tester) async {
      await pumpJoinScreen(tester, 'granted');

      await tester.tap(find.widgetWithText(ElevatedButton, 'Join'));
      await tester.pumpAndSettle();

      expect(find.textContaining('check it and try again'), findsNothing);
    });
  });
}
