import 'dart:async';

import 'package:flutter/widgets.dart';

/// How `PearLifecycle` reacts to [AppLifecycleState] changes — see
/// `Pear.lifecycle`'s `policy` field.
enum PearLifecyclePolicy {
  /// Backgrounding the app suspends the worklet after
  /// [PearLifecycleDefaults.linger] with no foreground return in between;
  /// foregrounding resumes it. Default.
  auto,

  /// `PearLifecycle` never calls suspend/resume on its own — call
  /// `Pear.suspend`/`Pear.resume` yourself. They stay public either way,
  /// regardless of policy.
  manual,
}

/// Tuning knobs for [PearLifecyclePolicy.auto].
abstract final class PearLifecycleDefaults {
  /// How long the app can be backgrounded before the worklet actually
  /// suspends — absorbs a quick app-switch (notification pull-down,
  /// permission dialog, share sheet) without thrashing the worklet on every
  /// brief backgrounding. Chosen as a middle ground: long enough that a
  /// glance at another app doesn't cost a resync, short enough that a
  /// genuinely backgrounded app isn't still holding a live P2P connection
  /// (and battery/radio budget) minutes later.
  static const linger = Duration(seconds: 20);
}

/// Wires [AppLifecycleState] to worklet suspend/resume with a linger window
/// (E6.2) — constructed by `Pear.start`; access via `Pear.lifecycle.policy`
/// to switch to [PearLifecyclePolicy.manual].
///
/// Deliberately decoupled from `Pear` itself (via [onSuspend]/[onResume]
/// callbacks, not a `Pear` reference — `Pear`'s own suspend/resume already
/// go through the real Bare Kit worklet and a platform channel) so this
/// policy/timing logic — the actual bug-prone part (linger timers, not
/// thrashing on a quick app-switch, manual override) — is unit-testable
/// with no worklet or platform channel involved at all.
///
/// This only controls what THIS library does — it cannot make Android
/// itself keep a backgrounded process's networking alive (Doze, App
/// Standby, and OEM battery managers all apply regardless). See
/// `BACKGROUND_EXECUTION.md` for what Android actually allows, the
/// foreground-service escape hatch, and why "foreground is the supported
/// guarantee, background is best-effort" (E6.4).
class PearLifecycle extends WidgetsBindingObserver {
  /// Registers as a [WidgetsBinding] observer immediately — call [dispose]
  /// to detach.
  PearLifecycle({
    required this.onSuspend,
    required this.onResume,
    this.linger = PearLifecycleDefaults.linger,
  }) {
    WidgetsBinding.instance.addObserver(this);
  }

  /// Called at most once per background period, when [policy] is
  /// [PearLifecyclePolicy.auto] and the app has stayed backgrounded for
  /// longer than [linger] with no foreground return.
  final void Function() onSuspend;

  /// Called when [policy] is [PearLifecyclePolicy.auto] and the app returns
  /// to the foreground — whether or not [onSuspend] actually fired first
  /// (safe either way: `Pear.resume` is itself idempotent, a no-op if
  /// nothing was ever suspended).
  final void Function() onResume;

  /// How long the app can be backgrounded before [onSuspend] fires.
  final Duration linger;

  /// [PearLifecyclePolicy.auto] by default — set to
  /// [PearLifecyclePolicy.manual] to opt out of automatic suspend/resume
  /// entirely (manual `Pear.suspend`/`Pear.resume` calls still work).
  PearLifecyclePolicy policy = PearLifecyclePolicy.auto;

  Timer? _lingerTimer;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (policy != PearLifecyclePolicy.auto) return;
    switch (state) {
      case AppLifecycleState.resumed:
        _lingerTimer?.cancel();
        _lingerTimer = null;
        onResume();
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // `??=`, not unconditional: `hidden` then `paused` (or vice versa)
        // without an intervening `resumed` must not restart the linger
        // window — it's measured from the FIRST step away from the
        // foreground, not reset by every subsequent background-ish
        // transition.
        _lingerTimer ??= Timer(linger, () {
          _lingerTimer = null;
          onSuspend();
        });
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        // inactive is a brief transitional state on the way to
        // paused/resumed (e.g. a system dialog or the app-switcher
        // preview) — not itself a background/foreground edge. detached has
        // no meaningful worklet action here.
        break;
    }
  }

  /// Detaches from [WidgetsBinding] and cancels any pending linger timer.
  /// Called by `Pear.dispose`.
  void dispose() {
    _lingerTimer?.cancel();
    _lingerTimer = null;
    WidgetsBinding.instance.removeObserver(this);
  }
}
