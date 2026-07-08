import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_pear_example/local_network_banner.dart';
import 'package:flutter_test/flutter_test.dart';

/// CEO review CRITICAL: the iOS Simulator does not enforce the Local
/// Network TCC prompt at all, and this dev environment has no physical
/// iPhone -- so [shouldShowLocalNetworkBanner]'s pure-function matrix and a
/// widget test driving [LocalNetworkTroubleBanner] directly are the only
/// coverage available for this failure mode (see the epic's acceptance
/// line: "denial path demonstrated by code-path tests").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('shouldShowLocalNetworkBanner', () {
    test('iOS, stuck 20s (>= the 15s threshold) -> true', () {
      expect(
        shouldShowLocalNetworkBanner(
          state: PearSwarmState.connecting,
          stuckFor: const Duration(seconds: 20),
          platform: TargetPlatform.iOS,
        ),
        isTrue,
      );
    });

    test('iOS, stuck only 5s (under the threshold) -> false', () {
      expect(
        shouldShowLocalNetworkBanner(
          state: PearSwarmState.connecting,
          stuckFor: const Duration(seconds: 5),
          platform: TargetPlatform.iOS,
        ),
        isFalse,
      );
    });

    test('Android, stuck 60s -> false (iOS-only heuristic)', () {
      expect(
        shouldShowLocalNetworkBanner(
          state: PearSwarmState.reconnecting,
          stuckFor: const Duration(seconds: 60),
          platform: TargetPlatform.android,
        ),
        isFalse,
      );
    });

    test('iOS, connected (not peerless) -> false regardless of duration', () {
      expect(
        shouldShowLocalNetworkBanner(
          state: PearSwarmState.connected,
          stuckFor: const Duration(minutes: 5),
          platform: TargetPlatform.iOS,
        ),
        isFalse,
      );
    });

    test('iOS, discovering (never found a candidate, not "peerless" in the '
        'connecting/reconnecting sense) -> false', () {
      expect(
        shouldShowLocalNetworkBanner(
          state: PearSwarmState.discovering,
          stuckFor: const Duration(seconds: 60),
          platform: TargetPlatform.iOS,
        ),
        isFalse,
      );
    });

    test('iOS, reconnecting 20s -> true (the was-connected-then-dropped '
        'case, not just the never-connected case)', () {
      expect(
        shouldShowLocalNetworkBanner(
          state: PearSwarmState.reconnecting,
          stuckFor: const Duration(seconds: 20),
          platform: TargetPlatform.iOS,
        ),
        isTrue,
      );
    });

    test('exactly at the 15s threshold -> true (inclusive)', () {
      expect(
        shouldShowLocalNetworkBanner(
          state: PearSwarmState.connecting,
          stuckFor: const Duration(seconds: 15),
          platform: TargetPlatform.iOS,
        ),
        isTrue,
      );
    });
  });

  group('LocalNetworkTroubleBanner widget', () {
    const qrChannel = MethodChannel('flutter_pear_example/qr_scanner');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    tearDown(() => messenger.setMockMethodCallHandler(qrChannel, null));

    testWidgets(
        'appears once the stuck-peerless state has held for 15+ seconds, '
        'tapping Open Settings invokes the channel, and it clears the '
        'moment a connected status arrives', (tester) async {
      String? invokedMethod;
      messenger.setMockMethodCallHandler(qrChannel, (call) async {
        invokedMethod = call.method;
        return true;
      });

      late StateSetter setInnerState;
      PearSwarmStatus status = (state: PearSwarmState.connecting, error: null);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setter) {
              setInnerState = setter;
              return LocalNetworkTroubleBanner(
                status: status,
                platform: TargetPlatform.iOS,
              );
            },
          ),
        ),
      ));

      // Not yet 15s stuck -- no banner.
      expect(find.byType(MaterialBanner), findsNothing);

      await tester.pump(const Duration(seconds: 16));
      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(
        find.text('Having trouble connecting over the local network'),
        findsOneWidget,
      );

      await tester.tap(find.text('Open Settings'));
      await tester.pump();
      expect(invokedMethod, 'openAppSettings');

      // A real connection arrives -- the banner must clear automatically,
      // no restart, no manual dismissal needed (design fix's in-flow
      // recovery requirement).
      setInnerState(
          () => status = (state: PearSwarmState.connected, error: null));
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing);
    });

    testWidgets('Dismiss hides the banner without touching Settings',
        (tester) async {
      late StateSetter setInnerState;
      PearSwarmStatus status = (state: PearSwarmState.connecting, error: null);

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: StatefulBuilder(
            builder: (context, setter) {
              setInnerState = setter;
              return LocalNetworkTroubleBanner(
                status: status,
                platform: TargetPlatform.iOS,
              );
            },
          ),
        ),
      ));
      await tester.pump(const Duration(seconds: 16));
      expect(find.byType(MaterialBanner), findsOneWidget);

      await tester.tap(find.text('Dismiss'));
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing);

      // Still stuck (no state change) -- stays dismissed, doesn't reappear
      // on its own.
      setInnerState(() {});
      await tester.pump(const Duration(seconds: 5));
      expect(find.byType(MaterialBanner), findsNothing);
    });

    testWidgets('never appears on Android even when stuck well past 15s',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: LocalNetworkTroubleBanner(
            status: (state: PearSwarmState.reconnecting, error: null),
            platform: TargetPlatform.android,
          ),
        ),
      ));
      await tester.pump(const Duration(seconds: 30));
      expect(find.byType(MaterialBanner), findsNothing);
    });
  });
}
