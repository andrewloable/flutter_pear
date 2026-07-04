import 'package:flutter/widgets.dart';
import 'package:flutter_pear/src/lifecycle.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const linger = Duration(milliseconds: 100);

  /// A fresh [PearLifecycle] recording every [onSuspend]/[onResume] call --
  /// [PearLifecycle] is deliberately decoupled from `Pear`/`BareWorklet`
  /// (see its own doc), so this policy/timing logic is testable with no
  /// worklet or platform channel involved at all.
  ({PearLifecycle lifecycle, List<String> calls}) makeLifecycle() {
    final calls = <String>[];
    final lifecycle = PearLifecycle(
      onSuspend: () => calls.add('suspend'),
      onResume: () => calls.add('resume'),
      linger: linger,
    );
    return (lifecycle: lifecycle, calls: calls);
  }

  testWidgets(
      'auto policy: backgrounding past the linger window suspends '
      'exactly once', (tester) async {
    final t = makeLifecycle();
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    expect(t.calls, isEmpty, reason: 'must not suspend before linger elapses');

    await tester.pump(linger + const Duration(milliseconds: 10));

    expect(t.calls, ['suspend']);
    t.lifecycle.dispose();
  });

  testWidgets(
      'auto policy: a quick pause->resume before linger elapses never '
      'suspends (no thrash on a fast app-switch)', (tester) async {
    final t = makeLifecycle();
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(linger ~/ 2);
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);

    // Advance well past where the ORIGINAL linger window would have expired
    // -- resumed must have cancelled it, not just delayed it.
    await tester.pump(linger * 2);

    expect(t.calls, ['resume']);
    t.lifecycle.dispose();
  });

  testWidgets('auto policy: resumed after a real suspend calls onResume',
      (tester) async {
    final t = makeLifecycle();
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(linger + const Duration(milliseconds: 10));
    expect(t.calls, ['suspend']);

    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);
    expect(t.calls, ['suspend', 'resume']);
    t.lifecycle.dispose();
  });

  testWidgets(
      'auto policy: hidden then paused (no intervening resumed) does not '
      'restart the linger window', (tester) async {
    final t = makeLifecycle();
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.hidden);
    await tester.pump(linger ~/ 2);
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    // If this second call restarted the timer, onSuspend would fire only
    // at 1.5x linger from here on, not at the original 1x mark.
    await tester.pump(linger ~/ 2 + const Duration(milliseconds: 10));

    expect(t.calls, ['suspend']);
    t.lifecycle.dispose();
  });

  testWidgets('auto policy: inactive and detached are no-ops', (tester) async {
    final t = makeLifecycle();
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.inactive);
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.detached);
    await tester.pump(linger + const Duration(milliseconds: 10));

    expect(t.calls, isEmpty);
    t.lifecycle.dispose();
  });

  testWidgets('manual policy: never auto-fires suspend or resume',
      (tester) async {
    final t = makeLifecycle();
    t.lifecycle.policy = PearLifecyclePolicy.manual;

    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(linger + const Duration(milliseconds: 10));
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.resumed);

    expect(t.calls, isEmpty);
    t.lifecycle.dispose();
  });

  testWidgets('dispose() cancels a pending linger timer', (tester) async {
    final t = makeLifecycle();
    t.lifecycle.didChangeAppLifecycleState(AppLifecycleState.paused);
    t.lifecycle.dispose();

    await tester.pump(linger + const Duration(milliseconds: 10));

    expect(t.calls, isEmpty);
  });
}
