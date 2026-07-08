import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';

import 'qr_scanner_channel.dart';

/// Eng review round 2 item 11 (locked, softens design fix 7): since iOS 14,
/// a same-Wi-Fi peer connection can fail completely silently if the user
/// denied this app's Local Network permission -- but iOS gives no reliable
/// signal that distinguishes that specific cause from an ordinary NAT/UDP
/// failure, so this can only ever be a heuristic, never a certainty claim.
///
/// Fires when [platform] is iOS and the swarm has been peerless
/// ([PearSwarmState.connecting] or [PearSwarmState.reconnecting] -- by
/// definition, zero live connections in either state) continuously for at
/// least 15 seconds ([stuckFor]).
///
/// Pure and platform-injectable specifically so it's trivially
/// unit-testable without a running worklet or a real iOS device (CEO review
/// CRITICAL: the Simulator does not enforce the Local Network prompt at
/// all, so a code-path test is the only coverage available here).
bool shouldShowLocalNetworkBanner({
  required PearSwarmState state,
  required Duration stuckFor,
  required TargetPlatform platform,
}) {
  if (platform != TargetPlatform.iOS) return false;
  final peerless = state == PearSwarmState.connecting ||
      state == PearSwarmState.reconnecting;
  if (!peerless) return false;
  return stuckFor >= const Duration(seconds: 15);
}

/// A dismissible banner shown when [shouldShowLocalNetworkBanner] fires for
/// [status] -- softened, no-certainty copy (eng review round 2 item 11)
/// with an Open Settings recovery action, since a doc note alone doesn't
/// rescue an end user stuck on the flagship cross-platform demo.
///
/// Renders nothing ([SizedBox.shrink]) until the underlying heuristic
/// fires. [status] is a plain, possibly-changing value rather than a
/// [Stream] -- this widget rebuilds via whatever mechanism its host
/// already uses (a `ListenableBuilder`, a `StreamSubscription` calling
/// `setState`, ...) and reacts to the change in [didUpdateWidget], the
/// same self-contained-[Timer] testability reasoning as `ExpiringInviteCard`
/// (pairing_screens.dart) -- a widget test can drive the 15-second
/// threshold directly with `tester.pump(...)`, without a real worklet.
class LocalNetworkTroubleBanner extends StatefulWidget {
  /// Creates the banner, tracking [status] for [platform] (defaults to
  /// [defaultTargetPlatform] -- null isn't a constant expression, so the
  /// real default is resolved lazily in [State.build] instead).
  const LocalNetworkTroubleBanner({
    super.key,
    required this.status,
    this.platform,
  });

  /// The swarm's current status, or null if not yet known.
  final PearSwarmStatus? status;

  /// The platform this banner's heuristic applies to, or null to use
  /// [defaultTargetPlatform] -- overridable in tests via
  /// `debugDefaultTargetPlatformOverride` is also possible, but this
  /// constructor parameter lets a test drive it directly without touching
  /// that global.
  final TargetPlatform? platform;

  @override
  State<LocalNetworkTroubleBanner> createState() =>
      _LocalNetworkTroubleBannerState();
}

class _LocalNetworkTroubleBannerState
    extends State<LocalNetworkTroubleBanner> {
  // Ticked by Timer.periodic rather than measured via DateTime.now()
  // deliberately -- flutter_test's fake clock advances pending Timers when
  // a test calls `tester.pump(duration)`, but does NOT make DateTime.now()
  // reflect that elapsed time, so a wall-clock diff would silently never
  // reach the threshold under test (only under a real clock, exactly the
  // kind of gap that isn't caught until it's demoed on a real phone).
  Timer? _ticker;
  int _stuckSeconds = 0;
  bool _dismissed = false;
  bool _visible = false;

  @override
  void initState() {
    super.initState();
    _onStatusChanged();
  }

  @override
  void didUpdateWidget(covariant LocalNetworkTroubleBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.status?.state != widget.status?.state) {
      _onStatusChanged();
    }
  }

  void _onStatusChanged() {
    final state = widget.status?.state;
    final stuck = state == PearSwarmState.connecting ||
        state == PearSwarmState.reconnecting;
    if (!stuck) {
      _stuckSeconds = 0;
      _ticker?.cancel();
      _ticker = null;
      // A fresh episode next time it gets stuck deserves its own banner --
      // a dismissal shouldn't silently suppress a LATER, separate episode.
      _dismissed = false;
      if (_visible) setState(() => _visible = false);
      return;
    }
    if (_ticker != null) return; // already ticking for this episode.
    _stuckSeconds = 0;
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      _stuckSeconds++;
      _recompute();
    });
  }

  void _recompute() {
    final state = widget.status?.state;
    if (state == null || !mounted) return;
    final should = !_dismissed &&
        shouldShowLocalNetworkBanner(
          state: state,
          stuckFor: Duration(seconds: _stuckSeconds),
          platform: widget.platform ?? defaultTargetPlatform,
        );
    if (should != _visible) setState(() => _visible = should);
  }

  void _dismiss() => setState(() {
        _dismissed = true;
        _visible = false;
      });

  @override
  void dispose() {
    _ticker?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_visible) return const SizedBox.shrink();
    return MaterialBanner(
      content: const Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('Having trouble connecting over the local network',
              style: TextStyle(fontWeight: FontWeight.bold)),
          SizedBox(height: 4),
          Text('If you denied Local Network access for this app, '
              're-enable it in Settings.'),
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => unawaited(QrScannerChannel.openAppSettings()),
          child: const Text('Open Settings'),
        ),
        TextButton(onPressed: _dismiss, child: const Text('Dismiss')),
      ],
    );
  }
}
