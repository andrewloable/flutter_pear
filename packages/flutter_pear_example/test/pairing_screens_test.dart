import 'package:flutter/foundation.dart';
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

  group('QR/permission channel failure falls back to the manual paste path '
      '(5A)', () {
    testWidgets(
        'a MissingPluginException from checkCameraPermission (iOS, where '
        'the Kotlin-only channel is absent) shows the broad-catch fallback '
        'message, not a crash or a permanently spinning section',
        (tester) async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw MissingPluginException('No implementation found for method '
            'checkCameraPermission on channel flutter_pear_example/'
            'qr_scanner');
      });
      await tester.pumpWidget(const MaterialApp(home: JoinRoomScreen()));
      await tester.pumpAndSettle();

      expect(
        find.text(
            "Couldn't check camera permission -- use the code below instead."),
        findsOneWidget,
      );
      // Never-dead-ends: the manual paste path must still be fully usable.
      expect(find.widgetWithText(ElevatedButton, 'Join'), findsOneWidget);
      expect(find.byType(TextField), findsOneWidget);
    });

    testWidgets(
        'an ordinary PlatformException from checkCameraPermission also '
        'falls back to the same message (not just MissingPluginException)',
        (tester) async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        throw PlatformException(
            code: 'CAMERA_ERROR', message: 'simulated native failure');
      });
      await tester.pumpWidget(const MaterialApp(home: JoinRoomScreen()));
      await tester.pumpAndSettle();

      expect(
        find.text(
            "Couldn't check camera permission -- use the code below instead."),
        findsOneWidget,
      );
    });
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

    testWidgets(
      'the invalid-code error also tells the user to ask sender for a new '
      'code, alongside the existing check-it-and-try-again phrase',
      (tester) async {
        await pumpJoinScreen(tester, 'granted');

        await tester.enterText(find.byType(TextField), '!!!not-base64!!!');
        await tester.tap(find.widgetWithText(ElevatedButton, 'Join'));
        await tester.pumpAndSettle();

        expect(find.textContaining('check it and try again'), findsOneWidget);
        expect(
          find.textContaining('ask sender for a new code'),
          findsOneWidget,
        );
      },
    );
  });

  group('JoinRoomScreen platform-conditional ordering (paste-first on iOS)',
      () {
    // Reset debugDefaultTargetPlatformOverride inline, as the last thing the
    // test body does -- TestWidgetsFlutterBinding checks it (and every
    // other foundation debug var) is back to null right as each testWidgets
    // body finishes, before either a package:test tearDown() or an
    // addTearDown() callback would fire; this is the same pattern the
    // Flutter framework's own test suite uses (e.g. text_field_test.dart).
    testWidgets(
      'iOS renders the paste field before the QR/camera section, with the '
      'affirmative "Paste the invite code..." copy',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        try {
          await pumpJoinScreen(tester, 'granted');

          expect(
            find.text('Paste the invite code from the other device'),
            findsOneWidget,
          );
          final pasteY = tester.getTopLeft(find.byType(TextField)).dy;
          final scanY = tester
              .getTopLeft(
                  find.widgetWithText(ElevatedButton, 'Scan QR code'))
              .dy;
          expect(pasteY, lessThan(scanY));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );

    testWidgets(
      'mutation spot-check target: Android keeps the QR/camera section '
      'first, paste field second',
      (tester) async {
        debugDefaultTargetPlatformOverride = TargetPlatform.android;
        try {
          await pumpJoinScreen(tester, 'granted');

          final pasteY = tester.getTopLeft(find.byType(TextField)).dy;
          final scanY = tester
              .getTopLeft(
                  find.widgetWithText(ElevatedButton, 'Scan QR code'))
              .dy;
          expect(scanY, lessThan(pasteY));
        } finally {
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  });

  group('InviteCard (StartRoomScreen extraction -- Pear.start has no test '
      'seam, so this is pumped directly instead)', () {
    const code = 'dGVzdC1pbnZpdGUtY29kZQ==';

    testWidgets('shows the QR code, copy, and share affordances',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InviteCard(code: code, pairing: false)),
      ));

      expect(find.byIcon(Icons.copy), findsOneWidget);
      expect(find.text('Share'), findsOneWidget);
      expect(
          find.text('Waiting for a peer to scan or enter this code…'),
          findsOneWidget);
    });

    testWidgets('the copy button puts the code on the clipboard',
        (tester) async {
      // flutter_test ships no built-in clipboard mock (unlike the mocked
      // qr_scanner/file_picker/share_open channels this file and others
      // already set up) -- Clipboard.setData/getData ride
      // SystemChannels.platform, so it must be mocked the same way.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copied = (call.arguments as Map)['text'] as String?;
          }
          return null;
        },
      );
      addTearDown(() => tester.binding.defaultBinaryMessenger
          .setMockMethodCallHandler(SystemChannels.platform, null));

      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InviteCard(code: code, pairing: false)),
      ));

      await tester.tap(find.byIcon(Icons.copy));
      await tester.pump();

      expect(copied, code);
      expect(find.text('Copied'), findsOneWidget);
    });

    testWidgets('pairing:true swaps the waiting line for the pairing spinner',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InviteCard(code: code, pairing: true)),
      ));

      expect(find.text('Peer found -- pairing…'), findsOneWidget);
      expect(
          find.text('Waiting for a peer to scan or enter this code…'),
          findsNothing);
    });

    testWidgets('the full code stays reachable but starts collapsed',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(body: InviteCard(code: code, pairing: false)),
      ));

      expect(find.text(code), findsNothing);
      await tester.tap(find.text('Show full code'));
      await tester.pumpAndSettle();
      expect(find.text(code), findsOneWidget);
    });
  });

  group('ExpiringInviteCard (StartRoomScreen extraction -- drives the TTL '
      'timer directly, no real Pear/invite needed)', () {
    const code = 'dGVzdC1pbnZpdGUtY29kZQ==';
    const ttl = Duration(seconds: 5);

    testWidgets('shows the invite card, not the expired state, before ttl',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ExpiringInviteCard(
            code: code,
            pairing: false,
            ttl: ttl,
            onGenerateNewCode: _noopGenerateNewCode,
          ),
        ),
      ));

      expect(find.byType(InviteCard), findsOneWidget);
      expect(find.text('This invite expired'), findsNothing);
    });

    testWidgets(
        'flips to the expired state with a Generate new code button once '
        'the ttl elapses', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: ExpiringInviteCard(
            code: code,
            pairing: false,
            ttl: ttl,
            onGenerateNewCode: _noopGenerateNewCode,
          ),
        ),
      ));

      await tester.pump(ttl);

      expect(find.text('This invite expired'), findsOneWidget);
      expect(find.text('Generate new code'), findsOneWidget);
      expect(find.byType(InviteCard), findsNothing);
    });

    testWidgets('tapping Generate new code calls onGenerateNewCode',
        (tester) async {
      var calls = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ExpiringInviteCard(
            code: code,
            pairing: false,
            ttl: ttl,
            onGenerateNewCode: () async => calls++,
          ),
        ),
      ));
      await tester.pump(ttl);

      await tester.tap(find.text('Generate new code'));
      await tester.pump();

      expect(calls, 1);
    });

    testWidgets('a fresh code (post-regeneration) restarts the countdown',
        (tester) async {
      final key = GlobalKey();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ExpiringInviteCard(
            key: key,
            code: code,
            pairing: false,
            ttl: ttl,
            onGenerateNewCode: _noopGenerateNewCode,
          ),
        ),
      ));
      await tester.pump(ttl);
      expect(find.text('This invite expired'), findsOneWidget);

      // Same key, new code -- didUpdateWidget must notice the change and
      // restart the timer instead of staying stuck expired.
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ExpiringInviteCard(
            key: key,
            code: 'bmV3LWNvZGU=',
            pairing: false,
            ttl: ttl,
            onGenerateNewCode: _noopGenerateNewCode,
          ),
        ),
      ));

      expect(find.text('This invite expired'), findsNothing);
      expect(find.byType(InviteCard), findsOneWidget);
    });
  });
}

Future<void> _noopGenerateNewCode() async {}
