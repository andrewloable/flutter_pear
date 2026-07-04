import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_pear/flutter_pear.dart';
import 'package:qr_flutter/qr_flutter.dart';

import 'main.dart' show ChatScreen, PrejoinedSwarmWiring;
import 'qr_scanner_channel.dart';

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
/// that topic on this device too, and hands off to [ChatScreen.joined] --
/// both devices land in chat over the same freshly-derived topic, never
/// the demo's shared-string shortcut.
class StartRoomScreen extends StatefulWidget {
  /// Creates the "start a room" screen.
  const StartRoomScreen({super.key});

  @override
  State<StartRoomScreen> createState() => _StartRoomScreenState();
}

class _StartRoomScreenState extends State<StartRoomScreen> {
  Pear? _pear;
  PearInvite? _invite;
  StreamSubscription<PearPairingCandidate>? _candidatesSub;
  bool _pairing = false;
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

  Future<void> _start() async {
    // Tracked outside the try so a failure after Pear.start() succeeded
    // (e.g. createInvite() throwing) can still dispose it in the catch --
    // otherwise a failed invite creation would leak a running worklet.
    Pear? pear;
    try {
      pear = await Pear.start();
      final invite = await pear.createInvite();
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
      if (!mounted) {
        unawaited(swarm.leave().catchError((_) {}));
        unawaited(wiring.stateSub.cancel());
        unawaited(wiring.connectionsSub.cancel());
        return;
      }
      _handedOff = true;
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen.joined(
            prejoinedPear: pear,
            prejoinedSwarm: swarm,
            prejoinedWiring: wiring,
          ),
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
          child: SingleChildScrollView(
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
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text('Scan this on the other device to join:'),
        const SizedBox(height: 16),
        Center(
          child: ColoredBox(
            color: Colors.white,
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: QrImageView(data: code, size: 240),
            ),
          ),
        ),
        const SizedBox(height: 24),
        const Text('Or read this code aloud / let them type it in:'),
        const SizedBox(height: 8),
        SelectableText(
          code,
          style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
        ),
        const SizedBox(height: 24),
        Center(
          child: _pairing
              ? const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    CircularProgressIndicator(),
                    SizedBox(height: 8),
                    Text('Peer found -- pairing…'),
                  ],
                )
              : const Text('Waiting for a peer to scan or enter this code…'),
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
/// [Pear.join], landing in the same [ChatScreen.joined] destination.
class JoinRoomScreen extends StatefulWidget {
  /// Creates the "join a room" screen.
  const JoinRoomScreen({super.key});

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
  String? _joinError;

  @override
  void initState() {
    super.initState();
    unawaited(_refreshPermission());
  }

  @override
  void dispose() {
    _manualCodeController.dispose();
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
        _joinError = 'That code is not valid -- check it and try again.';
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
      handedOff = true;
      if (!mounted) {
        unawaited(wiring.stateSub.cancel());
        unawaited(wiring.connectionsSub.cancel());
        unawaited(swarm.leave().catchError((_) {}).whenComplete(pear.dispose));
        return;
      }
      Navigator.of(context).pushReplacement(
        MaterialPageRoute(
          builder: (_) => ChatScreen.joined(
            prejoinedPear: pear!,
            prejoinedSwarm: swarm,
            prejoinedWiring: wiring,
          ),
        ),
      );
    } on PearException catch (e) {
      if (!mounted) return;
      setState(() => _joinError = e.toString());
    } finally {
      if (!handedOff) await pear?.dispose();
      if (mounted) setState(() => _joining = false);
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Join room')),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildPermissionSection(),
                const SizedBox(height: 24),
                const Divider(),
                const SizedBox(height: 16),
                const Text('Or type/paste the code from the other device:'),
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
                if (_joinError != null) ...[
                  const SizedBox(height: 16),
                  Text(_joinError!, style: const TextStyle(color: Colors.red)),
                ],
                if (_joining) ...[
                  const SizedBox(height: 16),
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
