import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pear_example/main.dart';
import 'package:flutter_pear_example/pairing_screens.dart';
import 'package:flutter_test/flutter_test.dart';

/// Finds the button labeled [buttonText] inside the [Card] whose title is
/// [cardTitle] -- both demo cards share the same "Start room"/"Join room"
/// button text (TD-D1), so a plain `find.text(...)` would match twice.
Finder _buttonInCard(String cardTitle, String buttonText) => find.descendant(
      of: find.ancestor(
        of: find.text(cardTitle),
        matching: find.byType(Card),
      ),
      matching: find.text(buttonText),
    );

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

  group('ChatApp home screen (TD-D1: exactly two demo cards)', () {
    testWidgets('shows exactly two demo cards, Chat and File drop',
        (tester) async {
      await tester.pumpWidget(const ChatApp());
      expect(find.text('Chat'), findsOneWidget);
      expect(find.text('File drop'), findsOneWidget);
      expect(find.byType(Card), findsNWidgets(2));
    });

    testWidgets(
        'no six-route wall -- none of the old flat demo-shortcut labels '
        'remain', (tester) async {
      await tester.pumpWidget(const ChatApp());
      expect(find.text('Chat demo'), findsNothing);
      expect(find.text('File drop demo'), findsNothing);
      expect(find.text('Start Room (QR) — Chat'), findsNothing);
      expect(find.text('Join Room (QR) — Chat'), findsNothing);
      expect(find.text('Start Room (QR) — File drop'), findsNothing);
      expect(find.text('Join Room (QR) — File drop'), findsNothing);
    });

    testWidgets('each card has a Start room and a Join room action',
        (tester) async {
      await tester.pumpWidget(const ChatApp());
      expect(_buttonInCard('Chat', 'Start room'), findsOneWidget);
      expect(_buttonInCard('Chat', 'Join room'), findsOneWidget);
      expect(_buttonInCard('File drop', 'Start room'), findsOneWidget);
      expect(_buttonInCard('File drop', 'Join room'), findsOneWidget);
    });

    testWidgets(
      'Join room buttons land on JoinRoomScreen with the matching '
      'destination -- no separate pairing path for file-drop, only a '
      'different destination',
      (tester) async {
        await tester.pumpWidget(const ChatApp());
        await tester.tap(_buttonInCard('Chat', 'Join room'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<JoinRoomScreen>(find.byType(JoinRoomScreen)).destination,
          PairingDestination.chat,
        );

        await tester.pageBack();
        await tester.pumpAndSettle();
        await tester.tap(_buttonInCard('File drop', 'Join room'));
        await tester.pumpAndSettle();
        expect(
          tester.widget<JoinRoomScreen>(find.byType(JoinRoomScreen)).destination,
          PairingDestination.fileDrop,
        );
      },
    );
  });

  group('StartRoomScreen/JoinRoomScreen destination wiring', () {
    // Plain object construction, deliberately never pumped/mounted --
    // StartRoomScreen's initState unconditionally calls the real
    // Pear.start(), which has no native platform to answer it in a widget
    // test and isn't caught by its PearException-only catch clause.
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
