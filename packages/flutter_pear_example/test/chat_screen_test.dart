import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_pear_example/main.dart';
import 'package:flutter_test/flutter_test.dart';

PearSwarmStatus _status(PearSwarmState state, {PearException? error}) =>
    (state: state, error: error);

void main() {
  group('describeSwarmState', () {
    test('covers every state with a distinct message', () {
      expect(describeSwarmState(_status(PearSwarmState.discovering)),
          contains('Looking for a peer'));
      expect(describeSwarmState(_status(PearSwarmState.connecting)),
          contains('connecting'));
      expect(
          describeSwarmState(_status(PearSwarmState.connected)), 'Connected.');
      expect(describeSwarmState(_status(PearSwarmState.reconnecting)),
          contains('Peer dropped'));
      expect(describeSwarmState(_status(PearSwarmState.suspended)),
          contains('Suspended'));
    });

    test('failed includes the error message when present', () {
      final withError = describeSwarmState(_status(
        PearSwarmState.failed,
        error: PearException('no route to peer'),
      ));
      expect(withError, 'Failed: no route to peer');

      final withoutError =
          describeSwarmState(_status(PearSwarmState.failed));
      expect(withoutError, 'Failed');
    });
  });

  group('SwarmStatusBanner', () {
    Future<void> pumpBanner(
      WidgetTester tester,
      PearSwarmStatus status,
    ) =>
        tester.pumpWidget(MaterialApp(
          home: SwarmStatusBanner(status: status),
        ));

    testWidgets('shows the failure reason honestly, not just a spinner',
        (tester) async {
      await pumpBanner(
        tester,
        _status(PearSwarmState.failed,
            error: PearException('UDP blocked on this network')),
      );

      expect(
          find.text('Failed: UDP blocked on this network'), findsOneWidget);
    });

    testWidgets('connected reads as a plain, unambiguous label',
        (tester) async {
      await pumpBanner(tester, _status(PearSwarmState.connected));
      expect(find.text('Connected'), findsOneWidget);
    });

    testWidgets('discovering/connecting/reconnecting/suspended all render',
        (tester) async {
      for (final (state, label) in [
        (PearSwarmState.discovering, 'Discovering…'),
        (PearSwarmState.connecting, 'Connecting…'),
        (PearSwarmState.reconnecting, 'Reconnecting…'),
        (PearSwarmState.suspended, 'Suspended'),
      ]) {
        await pumpBanner(tester, _status(state));
        expect(find.text(label), findsOneWidget, reason: 'state: $state');
      }
    });
  });
}
