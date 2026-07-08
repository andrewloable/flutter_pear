import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pear_example/local_network_banner.dart';
import 'package:flutter_pear_example/pairing_screens.dart';
import 'package:flutter_test/flutter_test.dart';

/// Pins the plan's design-review interaction state table (epic acceptance
/// line: "widget tests green") for the PAIRING half of the T3 screens --
/// see state_matrix_file_transfer_test.dart for the file send/receive and
/// connection-pill halves. Every row below either has its own testWidgets
/// case in this file, or is already pinned elsewhere by name -- listed here
/// so the full table stays traceable from one place without duplicating
/// coverage that already exists:
///
/// - join ERROR (invalid/expired code -> inline + "ask sender for a new
///   code") -- pairing_screens_test.dart, group "manual code entry",
///   test "the invalid-code error also tells the user to ask sender for a
///   new code...".
/// - join EMPTY ordering (paste-first on iOS, Android unchanged) --
///   pairing_screens_test.dart, group "JoinRoomScreen platform-conditional
///   ordering (paste-first on iOS)".
/// - start LOADING (Waiting for a peer... + invite card), start ERROR (TTL
///   expired -> Generate new code) -- pairing_screens_test.dart, groups
///   "InviteCard" and "ExpiringInviteCard".
/// - QR/permission channel failure never dead-ends -- pairing_screens_test.dart,
///   group "QR/permission channel failure falls back to the manual paste
///   path (5A)".
/// - connection: reconnecting pill, connected pill -- chat_screen_test.dart,
///   group "SwarmStatusBanner".
/// - connection: local-network banner + Settings hint (iOS code-path) --
///   local_network_banner_test.dart.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const qrChannel = MethodChannel('flutter_pear_example/qr_scanner');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  tearDown(() => messenger.setMockMethodCallHandler(qrChannel, null));

  Future<void> pumpJoinScreen(WidgetTester tester) async {
    messenger.setMockMethodCallHandler(qrChannel, (call) async {
      if (call.method == 'checkCameraPermission') return 'granted';
      return null;
    });
    await tester.pumpWidget(const MaterialApp(home: JoinRoomScreen()));
    await tester.pumpAndSettle();
  }

  group('join LOADING -- "Connecting..." with spinner', () {
    testWidgets(
        'tapping Join with a well-formed (but unresolvable) code shows '
        'Connecting... and a spinner, not a silent hang', (tester) async {
      await pumpJoinScreen(tester);

      // Well-formed base64 so _acceptCode gets past the fast-fail
      // FormatException path and into the async Pear.start() gap -- that
      // call has no platform channel handler in a widget test and simply
      // never resolves, which is exactly the LOADING window this row
      // describes; a single pump (not pumpAndSettle, which would wait
      // forever for that hung future) is enough to observe it.
      final wellFormedButFakeCode = base64Encode(Uint8List(32));
      await tester.enterText(find.byType(TextField), wellFormedButFakeCode);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Join'));
      await tester.pump();

      expect(find.text('Connecting...'), findsOneWidget);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      // Never a dead end mid-loading -- Cancel stays reachable.
      expect(find.text('Cancel'), findsOneWidget);
    });
  });

  group('join EMPTY -- paste field ready with the affirmative lead copy', () {
    testWidgets(
        'the paste field and its "Paste the invite code..." copy render '
        'immediately, before any send/join action', (tester) async {
      await pumpJoinScreen(tester);

      expect(
        find.text('Paste the invite code from the other device'),
        findsOneWidget,
      );
      expect(find.byType(TextField), findsOneWidget);
      expect(find.widgetWithText(ElevatedButton, 'Join'), findsOneWidget);
    });
  });

  group('join SUCCESS -- the "Paired" confirmation beat', () {
    testWidgets('shows a checkmark and the exact word "Paired"',
        (tester) async {
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: PairedBeat())),
      );

      expect(find.text('Paired'), findsOneWidget);
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });
  });

  group('connection -- local-network trouble banner renders inline while '
      'joining is in progress (iOS code-path)', () {
    testWidgets(
        'LocalNetworkTroubleBanner is present in the join-in-progress '
        'section, ready to react once a real join status streams in',
        (tester) async {
      await pumpJoinScreen(tester);

      final wellFormedButFakeCode = base64Encode(Uint8List(32));
      await tester.enterText(find.byType(TextField), wellFormedButFakeCode);
      await tester.tap(find.widgetWithText(ElevatedButton, 'Join'));
      await tester.pump();

      // No status has streamed in yet (pear.join() never got that far in
      // this widget test), so it renders nothing visible -- but the widget
      // itself must be mounted in the join-in-progress section, ready to
      // react the moment a real status does arrive. The heuristic's own
      // full behavior (appears after 15s stuck, Open Settings, auto-clears)
      // is pinned directly in local_network_banner_test.dart.
      expect(find.byType(LocalNetworkTroubleBanner), findsOneWidget);
    });
  });
}
