import 'package:flutter/services.dart';
import 'package:flutter_pear_example/main.dart';
import 'package:flutter_pear_example/pairing_screens.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // JoinRoomScreen checks camera permission on mount -- without a mocked
  // response the native channel call never resolves in a widget test, and
  // its indeterminate CircularProgressIndicator then keeps pumpAndSettle()
  // from ever settling (same setup as pairing_screens_test.dart).
  const qrChannel = MethodChannel('flutter_pear_example/qr_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  setUp(() {
    messenger.setMockMethodCallHandler(qrChannel, (call) async {
      if (call.method == 'checkCameraPermission') return 'granted';
      return null;
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(qrChannel, null));

  group('ChatApp home screen', () {
    testWidgets('shows both demo entry points', (tester) async {
      await tester.pumpWidget(const ChatApp());
      expect(find.text('Chat demo'), findsOneWidget);
      expect(find.text('File drop demo'), findsOneWidget);
    });

    testWidgets('Chat demo navigates to the chat screen', (tester) async {
      await tester.pumpWidget(const ChatApp());
      await tester.tap(find.text('Chat demo'));
      await tester.pumpAndSettle();
      expect(find.text('flutter_pear chat'), findsOneWidget);
    });

    testWidgets('File drop demo navigates to the file-drop screen',
        (tester) async {
      await tester.pumpWidget(const ChatApp());
      await tester.tap(find.text('File drop demo'));
      await tester.pumpAndSettle();
      expect(find.text('flutter_pear file drop'), findsOneWidget);
    });

    testWidgets('shows all four QR pairing entry points', (tester) async {
      await tester.pumpWidget(const ChatApp());
      expect(find.text('Start Room (QR) — Chat'), findsOneWidget);
      expect(find.text('Join Room (QR) — Chat'), findsOneWidget);
      expect(find.text('Start Room (QR) — File drop'), findsOneWidget);
      expect(find.text('Join Room (QR) — File drop'), findsOneWidget);
    });

    // JoinRoomScreen is safe to mount and tap into here -- its initState only
    // checks camera permission over a mocked/absent channel, which its own
    // broad catch-all already tolerates. StartRoomScreen is NOT: its
    // initState unconditionally calls the real Pear.start(), which has no
    // native platform to answer it in a widget test and isn't caught by its
    // PearException-only catch clause -- see the plain-object checks below
    // for how its `destination` wiring is covered instead.
    testWidgets(
      'Join Room (QR) buttons land on JoinRoomScreen with the matching '
      'destination -- no separate pairing path for file-drop, only a '
      'different destination',
      (tester) async {
        await tester.pumpWidget(const ChatApp());
        await tester.tap(find.text('Join Room (QR) — Chat'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<JoinRoomScreen>(find.byType(JoinRoomScreen)).destination,
          PairingDestination.chat,
        );

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(find.text('Join Room (QR) — File drop'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<JoinRoomScreen>(find.byType(JoinRoomScreen)).destination,
          PairingDestination.fileDrop,
        );
      },
    );
  });

  group('StartRoomScreen/JoinRoomScreen destination wiring', () {
    // Plain object construction, deliberately never pumped/mounted -- see
    // the comment above on why StartRoomScreen can't be built in a widget
    // test.
    test('StartRoomScreen defaults to the chat destination', () {
      expect(const StartRoomScreen().destination, PairingDestination.chat);
    });

    test('StartRoomScreen honors an explicit destination', () {
      expect(
        const StartRoomScreen(destination: PairingDestination.fileDrop)
            .destination,
        PairingDestination.fileDrop,
      );
    });

    test('JoinRoomScreen defaults to the chat destination', () {
      expect(const JoinRoomScreen().destination, PairingDestination.chat);
    });

    test('JoinRoomScreen honors an explicit destination', () {
      expect(
        const JoinRoomScreen(destination: PairingDestination.fileDrop)
            .destination,
        PairingDestination.fileDrop,
      );
    });
  });
}
