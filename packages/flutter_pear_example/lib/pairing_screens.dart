import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pear/flutter_pear.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'file_drop_screen.dart' show FileDropScreen;
import 'local_network_banner.dart';
import 'main.dart' show ChatScreen, PrejoinedSwarmWiring;
import 'qr_scanner_channel.dart';
import 'share_open_channel.dart';

/// Which demo screen the QR/invite pairing flow
/// ([StartRoomScreen]/[JoinRoomScreen]) hands off to once pairing succeeds.
/// Both demos ride the exact same invite/QR exchange -- this only picks
/// which already-paired [Pear]/[PearSwarm] consumer to land on afterward.
enum PairingDestination {
  /// Land on [ChatScreen.joined].
  chat,

  /// Land on [FileDropScreen.joined].
  fileDrop,
}

/// Builds the screen [destination] lands on once pairing produces [pear],
/// [swarm], and its [wiring] -- shared by [StartRoomScreen] and
/// [JoinRoomScreen] so the two never drift on how a [PairingDestination]
/// maps to a screen.
Widget _buildDestinationScreen(
  PairingDestination destination,
  Pear pear,
  PearSwarm swarm,
  PrejoinedSwarmWiring wiring,
) =>
    switch (destination) {
      PairingDestination.chat => ChatScreen.joined(
          prejoinedPear: pear,
          prejoinedSwarm: swarm,
          prejoinedWiring: wiring,
        ),
      PairingDestination.fileDrop => FileDropScreen.joined(
          prejoinedPear: pear,
          prejoinedSwarm: swarm,
          prejoinedWiring: wiring,
        ),
    };

/// Generates a fresh, cryptographically random 32-byte [PearKey] to use as
/// the shared swarm topic for one pairing session. Deliberately NOT
/// [PearCrypto.unsafeTopicFromString] -- a random key scoped to just this
/// one invite/pairing exchange is the entire point of real pairing over the
/// demo room-name shortcut (see that helper's own doc for why it's unsafe
/// for anything but a quick demo).
PearKey _randomTopicKey() {
  final random = Random.secure();
  final bytes = Uint8List(32);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return PearKey(bytes);
}

/// How long a demo invite lives before [StartRoomScreen] flips its card to
/// the expired state. [PearInvite] itself exposes no expiry event -- this
/// is a local timer matching the same [Duration] passed to
/// `Pear.createInvite`'s `ttl`.
const _inviteTtl = Duration(minutes: 10);

/// How long the "Paired" confirmation beat stays on screen before handing
/// off to the destination room -- design fix 5's success-state pause,
/// shared by [StartRoomScreen] and [JoinRoomScreen].
const _pairedBeatDuration = Duration(milliseconds: 700);

/// The brief "Paired" confirmation shown on both [StartRoomScreen] and
/// [JoinRoomScreen] right before handing off to the destination room --
/// interaction state table's SUCCESS row for both screens. Public
/// (not screen-private) specifically so the state-matrix test suite can
/// pump it directly.
class PairedBeat extends StatelessWidget {
  /// Creates the beat.
  const PairedBeat({super.key});

  @override
  Widget build(BuildContext context) => const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.check_circle, color: Colors.green, size: 48),
            SizedBox(height: 8),
            Text('Paired'),
          ],
        ),
      );
}

/// E7.2, device A's half of the QR pairing flow: creates a
/// [PearPairing] invite and renders it both as a QR code and as a
/// selectable base64 string (the "manual code" -- the exact bytes of
/// [PearInvite.invite], not a [PearKey]; see [JoinRoomScreen] for the
/// matching accept side). The QR/code stays visible for the whole flow --
/// including once a peer is found and pairing is in progress -- since the
/// other device may still need to keep scanning it if that confirm/join
/// exchange is slow.
///
/// On the first candidate to scan the invite, generates a fresh random
/// topic key ([_randomTopicKey]), confirms the candidate with it, joins
/// that topic on this device too, and hands off to [destination] -- both
/// devices land on the same demo screen over the same freshly-derived
/// topic, never the demo's shared-string shortcut.
class StartRoomScreen extends StatefulWidget {
  /// Creates the "start a room" screen, handing off to [destination]
  /// (chat by default) once pairing succeeds.
  const StartRoomScreen({super.key, this.destination = PairingDestination.chat});

  /// Which demo screen to land on once pairing succeeds.
  final PairingDestination destination;

  @override
  State<StartRoomScreen> createState() => _StartRoomScreenState();
}

class _StartRoomScreenState extends State<StartRoomScreen> {
  Pear? _pear;
  PearInvite? _invite;
  StreamSubscription<PearPairingCandidate>? _candidatesSub;
  bool _pairing = false;
  bool _paired = false;
  String? _error;

  // Set right before navigating away with [_pear] handed off to
  // ChatScreen.joined -- dispose() must NOT also tear down a Pear that
  // screen now owns.
  bool _handedOff = false;

  @override
  void initState() {
    super.initState();
    unawaited(_start());
  }

  /// Design fix 5's TTL-expiry recovery: revokes the expired invite (best
  /// effort) and creates a fresh one on the same [Pear] -- never requires
  /// the whole screen (and its [Pear]/worklet) to be torn down and
  /// recreated. [ExpiringInviteCard] notices the new invite's different
  /// [PearInvite.invite]-derived code and restarts its own countdown.
  Future<void> _generateNewCode() async {
    final pear = _pear;
    if (pear == null) return;
    await _candidatesSub?.cancel();
    final oldInvite = _invite;
    if (oldInvite != null) unawaited(oldInvite.revoke().catchError((_) {}));
    setState(() => _invite = null);
    try {
      final invite = await pear.createInvite(ttl: _inviteTtl);
      _candidatesSub = invite.candidates.listen(_onCandidate);
      if (!mounted) {
        await _candidatesSub?.cancel();
        return;
      }
      setState(() => _invite = invite);
    } on PearException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _start() async {
    // Tracked outside the try so a failure after Pear.start() succeeded
    // (e.g. createInvite() throwing) can still dispose it in the catch --
    // otherwise a failed invite creation would leak a running worklet.
    Pear? pear;
    try {
      pear = await Pear.start();
      final invite = await pear.createInvite(ttl: _inviteTtl);
      // Subscribe immediately, nothing else awaited in between -- a
      // candidate that arrives before this listener attaches is missed
      // (broadcast stream, same discipline as everywhere else in this
      // codebase).
      _candidatesSub = invite.candidates.listen(_onCandidate);
      if (!mounted) {
        // Screen already gone before the invite finished setting up --
        // nothing was handed off, so this Pear is still ours to clean up.
        await _candidatesSub?.cancel();
        await pear.dispose();
        return;
      }
      setState(() {
        _pear = pear;
        _invite = invite;
      });
    } on PearException catch (e) {
      await pear?.dispose();
      if (!mounted) return;
      setState(() => _error = e.toString());
    }
  }

  Future<void> _onCandidate(PearPairingCandidate candidate) async {
    // Synchronous re-entrancy guard: a second candidate event delivered
    // before this handler's first `await` still sees `_pairing == true`,
    // since setState below runs before any suspension point.
    if (_pairing) return;
    setState(() => _pairing = true);
    final pear = _pear;
    if (pear == null) {
      // Practically unreachable -- _pear is set synchronously (no
      // intervening await) right after subscribing to candidates in
      // _start(), so no candidate event can be delivered before it's
      // set. Guarded anyway so a violated assumption here shows up as a
      // stuck "pairing…" spinner reset rather than a silent no-op.
      setState(() => _pairing = false);
      return;
    }
    final topicKey = _randomTopicKey();
    PearSwarm? swarm;
    PrejoinedSwarmWiring? wiring;
    try {
      // Join BEFORE confirming the candidate. confirm() immediately
      // unblocks the peer's own acceptInvite()/join() on the other device
      // -- so if this device's own join() below failed, the peer would be
      // permanently stranded on a topic this device never joined (the
      // next candidate gets a fresh random topic key, so there's no
      // rescue path). Confirming only once our own join() has already
      // succeeded means a failure here just surfaces as an error on this
      // screen, while the peer's acceptInvite() keeps waiting for the
      // next candidate to confirm it.
      swarm = await pear.join(topicKey);
      // Subscribe to the swarm's streams the instant it exists -- before
      // confirm(), before the mounted check, before anything else --
      // since ChatScreen.joined's own initState (where it would otherwise
      // subscribe) only runs a full pushReplacement + frame later. See
      // [PrejoinedSwarmWiring].
      wiring = PrejoinedSwarmWiring(swarm);
      await candidate.confirm(topicKey);
      // Local so both mounted checks below (the beat can still be interrupted
      // by the screen going away mid-pause) share the exact same cleanup --
      // at this point nothing has been handed off yet, so it's this
      // function's job, same as every other unmounted-mid-flow branch here.
      void cleanupUnmounted() {
        unawaited(swarm!.leave().catchError((_) {}));
        unawaited(wiring!.stateSub.cancel());
        unawaited(wiring.connectionsSub.cancel());
      }

      if (!mounted) {
        cleanupUnmounted();
        return;
      }
      // Design fix 5's success beat -- a brief, visible "Paired" confirmation
      // before handing off to the destination room.
      setState(() => _paired = true);
      await Future<void>.delayed(_pairedBeatDuration);
      if (!mounted) {
        cleanupUnmounted();
        return;
      }
      _handedOff = true;
      // Best-effort cleanup, not load-bearing for the hand-off below: this
      // device has no further use for the invite once its one candidate is
      // confirmed (flutter_pear-xtj) -- revoking closes the door on any
      // later candidate (a duplicate delivery per flutter_pear-0zq, or a
      // genuinely new scan) trying to pair against an invite this screen
      // is about to leave. A failure here (e.g. the RPC racing dispose)
      // isn't worth surfacing -- the invite still expires on its own TTL.
      final invite = _invite;
      if (invite != null) unawaited(invite.revoke().catchError((_) {}));
      // Rebound to new final locals: the builder closure below can't inherit
      // the null-promotion already established for the mutable swarm/wiring
      // captured above.
      final joinedSwarm = swarm;
      final joinedWiring = wiring;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => _buildDestinationScreen(
              widget.destination, pear, joinedSwarm, joinedWiring),
        ),
      );
    } on PearException catch (e) {
      // Either join() itself failed (swarm/wiring still null), or
      // confirm() failed after a successful join() -- in the latter case
      // this device is left joined to a topic the peer was never told
      // about, so leave it and stop buffering its events rather than
      // silently holding a zero-peer swarm open.
      if (swarm != null) {
        unawaited(swarm.leave().catchError((_) {}));
      }
      if (wiring != null) {
        unawaited(wiring.stateSub.cancel());
        unawaited(wiring.connectionsSub.cancel());
      }
      if (!mounted) return;
      setState(() {
        _pairing = false;
        _error = e.toString();
      });
    }
  }

  @override
  void dispose() {
    _candidatesSub?.cancel();
    if (!_handedOff) _pear?.dispose();
    super.dispose();
  }

  void _retry() {
    setState(() => _error = null);
    if (_invite == null) unawaited(_start());
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Start room')),
        body: SafeArea(
          child: _paired
              ? const PairedBeat()
              : SingleChildScrollView(
                  padding: const EdgeInsets.all(16),
                  child: _buildBody(),
                ),
        ),
      );

  Widget _buildBody() {
    if (_error != null) {
      // Never a dead end with only the AppBar back arrow as a way out: if
      // the invite itself is still live (_start() succeeded and only a
      // later _onCandidate() pairing attempt failed), retrying just clears
      // the error to reveal that still-valid invite/QR again -- listening
      // never stopped. Only re-runs _start() from scratch when there's no
      // invite to fall back to (_start() itself failed).
      return Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(_error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          ElevatedButton(onPressed: _retry, child: const Text('Try again')),
        ],
      );
    }
    final invite = _invite;
    if (invite == null) {
      return const Center(child: CircularProgressIndicator());
    }
    final code = base64Encode(invite.invite);
    return ExpiringInviteCard(
      code: code,
      pairing: _pairing,
      ttl: _inviteTtl,
      onGenerateNewCode: _generateNewCode,
    );
  }
}

/// The invite card once an invite exists: QR code, copy/share row, an
/// expandable full-code fallback (design fix 4 -- replaces the old
/// read-aloud copy + always-visible base64 wall), and the waiting/pairing
/// status line. Pulled out of [StartRoomScreen] as its own widget
/// specifically so a widget test can pump it directly with a fixed [code],
/// without needing a real [Pear] -- `Pear.start` has no test seam (see
/// pairing_screens_test.dart's own comment on why [StartRoomScreen] itself
/// can't be widget-tested end to end).
class InviteCard extends StatelessWidget {
  /// Creates the invite card for [code], showing the pairing spinner
  /// instead of the idle "waiting" line while [pairing] is true.
  const InviteCard({super.key, required this.code, required this.pairing});

  /// The base64-encoded invite bytes to render as a QR code and offer for
  /// copy/share.
  final String code;

  /// Whether a candidate has been found and pairing is in progress.
  final bool pairing;

  Future<void> _copyCode(BuildContext context) async {
    await Clipboard.setData(ClipboardData(text: code));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Copied')));
  }

  Future<void> _shareCode() async {
    try {
      await ShareOpenChannel.shareText(code);
    } catch (_) {
      // Best-effort -- the code is already copyable and visible on screen,
      // so a failed share isn't worth surfacing as an error.
    }
  }

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Scan this on the other device to join:'),
          const SizedBox(height: 16),
          Center(
            child: ColoredBox(
              color: Colors.white,
              child: Padding(
                padding: const EdgeInsets.all(16),
                // Constrained to the narrower of 240 or the available width
                // (minus this Padding's own 32) -- a fixed 240 would
                // overflow horizontally on a narrow phone.
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final qrSize = constraints.maxWidth.isFinite
                        ? constraints.maxWidth.clamp(0, 240).toDouble()
                        : 240.0;
                    return QrImageView(data: code, size: qrSize);
                  },
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Wrap(
            alignment: WrapAlignment.center,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              IconButton(
                onPressed: () => unawaited(_copyCode(context)),
                icon: const Icon(Icons.copy),
                tooltip: 'Copy code',
              ),
              TextButton.icon(
                onPressed: () => unawaited(_shareCode()),
                icon: const Icon(Icons.share),
                label: const Text('Share'),
              ),
            ],
          ),
          ExpansionTile(
            title: const Text('Show full code'),
            children: [
              Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                child: SelectableText(
                  code,
                  style:
                      const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          Center(
            child: pairing
                ? const Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(height: 8),
                      Text('Peer found -- pairing…'),
                    ],
                  )
                : const Text(
                    'Waiting for a peer to scan or enter this code…'),
          ),
        ],
      );
}

/// Wraps [InviteCard] with the TTL-expiry countdown (design fix 5) -- owns
/// its own [Timer], entirely independent of [Pear]/network state, so a
/// widget test can drive the expiry transition directly via
/// `tester.pump(ttl)` without a real invite (`Pear.start` has no test seam
/// -- see [InviteCard]'s own doc and pairing_screens_test.dart). Once
/// expired, the card flips over entirely to an expired state with a
/// "Generate new code" button rather than showing a now-useless QR code
/// alongside it; a new [code] (from [onGenerateNewCode] succeeding)
/// restarts the countdown.
class ExpiringInviteCard extends StatefulWidget {
  /// Creates the countdown-wrapped invite card for [code], expiring after
  /// [ttl] and calling [onGenerateNewCode] when the user asks for a fresh
  /// one post-expiry.
  const ExpiringInviteCard({
    super.key,
    required this.code,
    required this.pairing,
    required this.ttl,
    required this.onGenerateNewCode,
  });

  /// The base64-encoded invite bytes -- see [InviteCard.code].
  final String code;

  /// Whether a candidate has been found and pairing is in progress -- see
  /// [InviteCard.pairing].
  final bool pairing;

  /// How long [code] is valid for before this card flips to the expired
  /// state.
  final Duration ttl;

  /// Called when the user taps "Generate new code" post-expiry.
  final Future<void> Function() onGenerateNewCode;

  @override
  State<ExpiringInviteCard> createState() => _ExpiringInviteCardState();
}

class _ExpiringInviteCardState extends State<ExpiringInviteCard> {
  bool _expired = false;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _startTimer();
  }

  @override
  void didUpdateWidget(covariant ExpiringInviteCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    // A fresh code (generated post-expiry) restarts the countdown.
    if (oldWidget.code != widget.code) {
      setState(() => _expired = false);
      _startTimer();
    }
  }

  void _startTimer() {
    _timer?.cancel();
    _timer = Timer(widget.ttl, () {
      if (mounted) setState(() => _expired = true);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_expired) {
      return InviteCard(code: widget.code, pairing: widget.pairing);
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('This invite expired'),
        const SizedBox(height: 16),
        ElevatedButton(
          onPressed: () => unawaited(widget.onGenerateNewCode()),
          child: const Text('Generate new code'),
        ),
      ],
    );
  }
}

/// E7.2, device B's half of the QR pairing flow: never dead-ends regardless
/// of camera permission state (codex #4) -- a manual invite-code entry field
/// is always available, alongside whichever camera-permission affordance
/// ([CameraPermissionStatus.granted]/[CameraPermissionStatus.denied]/
/// [CameraPermissionStatus.permanentlyDenied]/[CameraPermissionStatus.notDetermined])
/// currently applies. Either path decodes the same base64 invite-code bytes
/// [StartRoomScreen] displays and calls [Pear.acceptInvite] then
/// [Pear.join], landing on the same [PairingDestination] the other device
/// resolves to.
class JoinRoomScreen extends StatefulWidget {
  /// Creates the "join a room" screen, handing off to [destination] (chat
  /// by default) once pairing succeeds.
  const JoinRoomScreen({super.key, this.destination = PairingDestination.chat});

  /// Which demo screen to land on once pairing succeeds.
  final PairingDestination destination;

  @override
  State<JoinRoomScreen> createState() => _JoinRoomScreenState();
}

class _JoinRoomScreenState extends State<JoinRoomScreen> {
  final _manualCodeController = TextEditingController();

  CameraPermissionStatus? _permissionStatus;
  // Set when checkPermission()/requestPermission() itself throws (channel
  // glitch, MissingPluginException, an unexpected native-side change) --
  // distinct from _joinError since it applies to the permission section
  // specifically, not the join action below it. Without this, an unhandled
  // throw here (unlike _scan()'s explicit PlatformException catch) would
  // leave _permissionStatus stuck at null forever, spinning
  // _buildPermissionSection() indefinitely with no error ever surfaced.
  String? _permissionError;
  bool _joining = false;
  bool _paired = false;
  String? _joinError;

  // The joining swarm's live status, purely for the local-network trouble
  // banner (design fix "in-flow recovery") -- set once pear.join(key)
  // resolves and this screen's own subscription (independent of
  // PrejoinedSwarmWiring's own buffering one) starts observing it.
  PearSwarmStatus? _joiningStatus;
  StreamSubscription<PearSwarmStatus>? _joiningStatusSub;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPermission());
  }

  @override
  void dispose() {
    _manualCodeController.dispose();
    _joiningStatusSub?.cancel();
    super.dispose();
  }

  Future<void> _refreshPermission() async {
    try {
      final status = await QrScannerChannel.checkPermission();
      if (!mounted) return;
      setState(() {
        _permissionStatus = status;
        _permissionError = null;
      });
    } catch (_) {
      // Deliberately broad: the channel call can throw a PlatformException,
      // or (if the native side ever returns null) a TypeError from the
      // force-unwrap in QrScannerChannel -- either way, this must not leave
      // _permissionStatus stuck at null with a permanently spinning
      // permission section and no explanation.
      if (!mounted) return;
      setState(() => _permissionError =
          "Couldn't check camera permission -- use the code below instead.");
    }
  }

  Future<void> _requestPermission() async {
    try {
      final status = await QrScannerChannel.requestPermission();
      if (!mounted) return;
      setState(() {
        _permissionStatus = status;
        _permissionError = null;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _permissionError =
          "Couldn't request camera permission -- use the code below instead.");
    }
  }

  Future<void> _scan() async {
    String? result;
    try {
      result = await QrScannerChannel.scanQrCode();
    } on PlatformException catch (e) {
      if (!mounted) return;
      setState(() => _joinError = 'Could not open the scanner: ${e.message}');
      return;
    }
    // Null means the user backed out without scanning -- returning to this
    // screen with no error is the correct, non-dead-ending behavior.
    if (result == null) return;
    await _acceptCode(result);
  }

  Future<void> _joinManualCode() async {
    final code = _manualCodeController.text.trim();
    if (code.isEmpty) return;
    await _acceptCode(code);
  }

  Future<void> _acceptCode(String code) async {
    if (_joining) return;
    setState(() {
      _joining = true;
      _joinError = null;
    });

    final Uint8List invite;
    try {
      invite = base64Decode(code);
    } on FormatException {
      // Obviously-garbage input fails fast, before any network/RPC round
      // trip -- a typed error, never a hang.
      setState(() {
        _joining = false;
        _joinError = 'That code is not valid -- check it and try again, or '
            'ask sender for a new code.';
      });
      return;
    }

    Pear? pear;
    // Tracks whether disposal ownership passed to something else (the
    // ChatScreen this navigates to, or the leave()/dispose() chain for a
    // screen that's gone by the time joining finishes) -- if not, the
    // `finally` below must dispose it itself so a failed acceptInvite/join
    // never leaks a running worklet.
    var handedOff = false;
    try {
      pear = await Pear.start();
      final key = await pear.acceptInvite(invite);
      final swarm = await pear.join(key);
      // Subscribe to the swarm's streams the instant it exists -- see
      // [PrejoinedSwarmWiring] for why this can't wait for
      // ChatScreen.joined's own initState.
      final wiring = PrejoinedSwarmWiring(swarm);
      // A second, independent subscription on the same broadcast stream --
      // purely for the local-network trouble banner below, no ownership
      // implications (read-only, never touches leave()/dispose()).
      _joiningStatusSub = swarm.state.listen((status) {
        if (mounted) setState(() => _joiningStatus = status);
      });
      handedOff = true;
      void cleanupUnmounted() {
        unawaited(wiring.stateSub.cancel());
        unawaited(wiring.connectionsSub.cancel());
        unawaited(swarm.leave().catchError((_) {}).whenComplete(pear!.dispose));
        _joiningStatusSub?.cancel();
      }

      if (!mounted) {
        cleanupUnmounted();
        return;
      }
      // Design fix 5's success beat -- a brief, visible "Paired" confirmation
      // before handing off to the destination room.
      setState(() => _paired = true);
      await Future<void>.delayed(_pairedBeatDuration);
      if (!mounted) {
        cleanupUnmounted();
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => _buildDestinationScreen(
              widget.destination, pear!, swarm, wiring),
        ),
      );
    } on PearException catch (e) {
      if (!mounted) return;
      setState(() => _joinError = e.toString());
    } finally {
      if (!handedOff) await pear?.dispose();
      await _joiningStatusSub?.cancel();
      _joiningStatusSub = null;
      if (mounted) {
        setState(() {
          _joining = false;
          _joiningStatus = null;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_paired) {
      return Scaffold(
        appBar: AppBar(title: const Text('Join room')),
        body: const PairedBeat(),
      );
    }
    // Design fix "paste-first on iOS" -- the paste field + Join button lead
    // on iOS (with the affirmative "Paste the invite code..." copy),
    // followed by the camera section; Android keeps the QR-first ordering
    // it already had.
    final isIOS = defaultTargetPlatform == TargetPlatform.iOS;
    final pasteSection = _buildPasteSection();
    final scanSection = _buildPermissionSection();
    return Scaffold(
      appBar: AppBar(title: const Text('Join room')),
      body: SafeArea(
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (isIOS) pasteSection else scanSection,
              const SizedBox(height: 24),
              const Divider(),
              const SizedBox(height: 16),
              if (isIOS) scanSection else pasteSection,
              if (_joinError != null) ...[
                const SizedBox(height: 16),
                Text(_joinError!, style: const TextStyle(color: Colors.red)),
              ],
              if (_joining) ...[
                const SizedBox(height: 16),
                LocalNetworkTroubleBanner(status: _joiningStatus),
                const Center(child: Text('Connecting...')),
                const SizedBox(height: 8),
                const Center(child: CircularProgressIndicator()),
                const SizedBox(height: 8),
                // A slow/stalled peer can hold this spinner up for the
                // full acceptInvite()/join() timeout window with nothing
                // else tappable otherwise -- the AppBar back arrow already
                // works as an implicit cancel, but this makes it explicit
                // and discoverable instead of relying on that.
                Center(
                  child: TextButton(
                    onPressed: () => Navigator.of(context).maybePop(),
                    child: const Text('Cancel'),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPasteSection() => Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Paste the invite code from the other device'),
          const SizedBox(height: 8),
          TextField(
            controller: _manualCodeController,
            decoration: const InputDecoration(labelText: 'Invite code'),
            onSubmitted: (_) => _joinManualCode(),
          ),
          const SizedBox(height: 16),
          ElevatedButton(
            onPressed: _joining ? null : _joinManualCode,
            child: const Text('Join'),
          ),
        ],
      );

  Widget _buildPermissionSection() {
    final status = _permissionStatus;
    if (status == null) {
      final error = _permissionError;
      if (error != null) {
        // Never a permanent, unexplained spinner -- the manual code field
        // below still works regardless.
        return Text(error, style: const TextStyle(color: Colors.red));
      }
      return const Center(child: CircularProgressIndicator());
    }
    return switch (status) {
      CameraPermissionStatus.granted => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ElevatedButton.icon(
              onPressed: _joining ? null : _scan,
              icon: const Icon(Icons.qr_code_scanner),
              label: const Text('Scan QR code'),
            ),
          ],
        ),
      CameraPermissionStatus.notDetermined => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              "Camera access lets you scan the other device's QR code "
              'instead of typing it in.',
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _requestPermission,
              child: const Text('Enable camera'),
            ),
          ],
        ),
      CameraPermissionStatus.denied => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Camera access was denied. Grant it to scan a QR code, or '
              'use the code below instead.',
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: _requestPermission,
              child: const Text('Grant camera access'),
            ),
          ],
        ),
      CameraPermissionStatus.permanentlyDenied => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Camera access is disabled for this app. Enable it in system '
              'Settings to scan a QR code, or use the code below instead.',
            ),
            const SizedBox(height: 8),
            ElevatedButton(
              onPressed: () => unawaited(QrScannerChannel.openAppSettings()),
              child: const Text('Open Settings'),
            ),
          ],
        ),
    };
  }
}
