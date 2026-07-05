import 'dart:async' show unawaited;
import 'dart:convert' show utf8;
import 'dart:typed_data' show Uint8List;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_pear/flutter_pear.dart';
import 'package:path_provider/path_provider.dart';

import 'file_picker_channel.dart';
import 'main.dart' show PrejoinedSwarmWiring, SwarmStatusBanner, describeSwarmState;

/// E7.7 -- the second promised demo (chat is E7.1/E7.2): proves the E5.5
/// bulk-file path over the same room-joining affordance as chat. Sends a
/// picked file to every connected peer via [PearDrive.put] (streamed by
/// local file path, never loaded into memory -- see [PearDrive]'s own doc
/// for why that's what makes a large file safe here) and lets a peer pull
/// down anything new with [PearDrive.mirrorToDisk].
///
/// A `name`-derived [PearDrive] (`pear.drive(name: ...)`) is keyed off this
/// device's own [Pear]'s Corestore, which seeds a fresh random primary key
/// per install -- so the SAME name opens a DIFFERENT, unrelated drive on
/// each device. [PearDrive.replicate] only exposes a drive to whoever
/// already knows its key; it doesn't announce that key. So the peer whose
/// drive you want to mirror has to tell you its key some other way -- this
/// screen does that itself, over the very first bytes on each
/// [PearConnection] (see [_onConnection]), rather than something a peer
/// could guess from `name` alone.
///
/// Two ways in: the plain [FileDropScreen] constructor's own room-NAME entry
/// (`PearCrypto.unsafeTopicFromString`, demo-only shortcut, same as
/// [ChatScreen]'s own plain constructor), or [FileDropScreen.joined] --
/// adopting an already-paired [Pear]/[PearSwarm] from the real QR/invite flow
/// (`StartRoomScreen`/`JoinRoomScreen` in pairing_screens.dart), mirroring
/// [ChatScreen.joined]. Either way, no separate pairing mechanism exists for
/// file-drop -- it rides the exact same room-name or QR/invite path chat
/// does.
class FileDropScreen extends StatefulWidget {
  /// Creates the file-drop demo screen with its own room-name entry flow.
  const FileDropScreen({super.key})
      : prejoinedPear = null,
        prejoinedSwarm = null,
        prejoinedWiring = null;

  /// Creates the file-drop screen already attached to [prejoinedSwarm]
  /// (joined via [prejoinedPear]) -- used by the QR/invite pairing flow
  /// (`StartRoomScreen`/`JoinRoomScreen`), which builds its own [Pear] and
  /// [PearSwarm] via `PearPairing` rather than this screen's room-name text
  /// field. This screen takes over ownership of both: its [State.dispose]
  /// tears them down exactly as it would one it created itself. [wiring]
  /// (required alongside [swarm]) is the [PrejoinedSwarmWiring] the caller
  /// started subscribing on the instant it created [swarm] -- see that
  /// class for why this can't just re-subscribe from scratch here.
  const FileDropScreen.joined({
    super.key,
    required this.prejoinedPear,
    required this.prejoinedSwarm,
    required this.prejoinedWiring,
  });

  /// The already-started [Pear] to adopt instead of creating one, when this
  /// screen was constructed via [FileDropScreen.joined]. Null for the plain
  /// [FileDropScreen] constructor.
  final Pear? prejoinedPear;

  /// The already-joined [PearSwarm] to adopt instead of creating one, when
  /// this screen was constructed via [FileDropScreen.joined]. Null for the
  /// plain [FileDropScreen] constructor.
  final PearSwarm? prejoinedSwarm;

  /// The [PrejoinedSwarmWiring] already buffering [prejoinedSwarm]'s events
  /// since before this screen existed. Null for the plain [FileDropScreen]
  /// constructor, where [_FileDropScreenState._join] subscribes fresh
  /// instead.
  final PrejoinedSwarmWiring? prejoinedWiring;

  @override
  State<FileDropScreen> createState() => _FileDropScreenState();
}

/// Wire-encodes [key] as the drive-key announcement message sent over a
/// [PearConnection] -- see [FileDropScreen]'s class doc. Exposed top-level
/// (not inlined) so its round trip with [decodeDriveKeyAnnouncement] is
/// unit-testable without a running [Pear] -- everything else in this file
/// that touches [PearConnection]/[Pear] isn't (same structural limit as
/// `ChatScreen.joined`: `Pear`'s only public constructor is `Pear.start()`,
/// which always dials the real platform channel).
Uint8List encodeDriveKeyAnnouncement(PearKey key) =>
    Uint8List.fromList(utf8.encode(key.hex));

/// Reverses [encodeDriveKeyAnnouncement]. Throws [FormatException] (via
/// [PearKey.fromHex]) if [bytes] isn't a valid announcement -- the caller
/// ([_FileDropScreenState._onPeerDriveKey]) treats that as an untrusted
/// peer sending garbage, not a crash.
PearKey decodeDriveKeyAnnouncement(Uint8List bytes) =>
    PearKey.fromHex(utf8.decode(bytes));

enum _TransferStatus { idle, sending, receiving, done }

class _FileDropScreenState extends State<FileDropScreen> {
  final _topicController = TextEditingController();
  final _log = <String>[];

  Pear? _pear;
  PearSwarm? _swarm;
  PearDrive? _drive;
  PearSwarmStatus? _status;
  String? _joinError;
  bool _joining = false;
  _TransferStatus _transfer = _TransferStatus.idle;

  // Keyed by remotePublicKey.hex -- one entry per peer whose drive KEY this
  // device has learned (see the class doc on why that key must be
  // exchanged at all). [_checkForFiles] mirrors every drive in here, not
  // [_drive] (this device's own drive can never contain a peer's upload).
  final _peerDrives = <String, PearDrive>{};

  @override
  void initState() {
    super.initState();
    final pear = widget.prejoinedPear;
    final swarm = widget.prejoinedSwarm;
    // Both null for the plain FileDropScreen() constructor (room-name entry
    // via _join() below); both non-null for FileDropScreen.joined() (the
    // QR/invite pairing flow).
    if (pear != null && swarm != null) {
      unawaited(_adopt(pear, swarm, widget.prejoinedWiring));
    }
  }

  @override
  void dispose() {
    final pear = _pear;
    final leaving = _swarm?.leave();
    if (leaving != null) {
      leaving.catchError((_) {}).whenComplete(() => pear?.dispose());
    } else {
      pear?.dispose();
    }
    _topicController.dispose();
    super.dispose();
  }

  /// Adopts an already-joined [swarm]/[pear] from [FileDropScreen.joined] --
  /// shared shape with [_join], but the drive/replication wiring is
  /// factored into [_onStatus]/[_onConnection] so both paths stay in sync.
  /// [wiring] replays whatever [PearSwarmStatus]/[PearConnection] events
  /// arrived before this screen existed -- see [PrejoinedSwarmWiring].
  ///
  /// Ownership of [pear]/[swarm] transfers to this screen the instant this
  /// runs (mirrors [FileDropScreen.joined]'s own doc): [dispose] tears both
  /// down even if drive creation below fails.
  Future<void> _adopt(
    Pear pear,
    PearSwarm swarm,
    PrejoinedSwarmWiring? wiring,
  ) async {
    setState(() {
      _pear = pear;
      _swarm = swarm;
      _status = swarm.currentState;
    });
    final PearDrive drive;
    try {
      drive = await pear.drive(name: 'file-drop-demo');
    } on PearException catch (e) {
      if (!mounted) return;
      setState(() => _joinError = e.toString());
      return;
    }
    if (!mounted) return;
    setState(() => _drive = drive);

    if (wiring != null) {
      wiring.drainInto(_onStatus, (conn) => _onConnection(pear, drive, conn));
    } else {
      swarm.state.listen(_onStatus);
      swarm.connections.listen((conn) => _onConnection(pear, drive, conn));
    }
  }

  void _onStatus(PearSwarmStatus status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  /// Wires one newly-shown [PearConnection]: replicates this device's own
  /// [drive] (so a peer who already knows its key CAN fetch it), then
  /// exchanges drive keys over the connection itself -- see the class doc
  /// on why that's necessary at all -- so this device in turn learns the
  /// peer's key, opens ITS drive, and replicates that too. [pear] is taken
  /// as a parameter (not read from [_pear]) because the listener this
  /// drives is attached before [_pear] itself is assigned in [_join].
  void _onConnection(Pear pear, PearDrive drive, PearConnection conn) {
    drive.replicate(conn);
    final peerHex = conn.remotePublicKey.hex;
    _log.add('replicating with ${peerHex.substring(0, 8)}…');
    // Subscribed before writing our own announcement -- a broadcast stream
    // event arriving before a listener attaches is simply missed, same
    // discipline as everywhere else in this codebase.
    conn.data.listen((bytes) => _onPeerDriveKey(pear, peerHex, conn, bytes));
    unawaited(conn.write(encodeDriveKeyAnnouncement(drive.key)).catchError((_) {}));
    if (mounted) setState(() {});
  }

  /// Handles [bytes] arriving on [conn] as the peer's drive-key
  /// announcement (see [_onConnection]) -- opens that drive by key (once --
  /// [_peerDrives] caches it across reconnects) and replicates it over
  /// [conn]. Replication itself is re-issued on EVERY call, deliberately
  /// not deduped like the open/cache is: [conn] is a fresh [PearConnection]
  /// each time a peer reconnects (`swarm.connections` never re-delivers an
  /// old one), and skipping re-replicate here would leave a reconnected
  /// peer's drive permanently wired to a dead, closed stream -- silently
  /// starving [_checkForFiles] of anything that peer sends after that
  /// point. Matches [_onConnection]'s own `drive.replicate(conn)`, called
  /// unconditionally on every connection for exactly the same reason.
  Future<void> _onPeerDriveKey(
    Pear pear,
    String peerHex,
    PearConnection conn,
    Uint8List bytes,
  ) async {
    var peerDrive = _peerDrives[peerHex];
    if (peerDrive == null) {
      try {
        peerDrive = await pear.drive(key: decodeDriveKeyAnnouncement(bytes));
      } catch (e) {
        if (!mounted) return;
        setState(
          () => _log.add(
            'bad drive-key announcement from ${peerHex.substring(0, 8)}: $e',
          ),
        );
        return;
      }
      _peerDrives[peerHex] = peerDrive;
    }
    await peerDrive.replicate(conn);
    if (!mounted) return;
    setState(
      () => _log.add(
        "learned ${peerHex.substring(0, 8)}'s drive -- Check for files "
        'will pull down whatever they share',
      ),
    );
  }

  Future<void> _join() async {
    if (_joining) return;
    final topicText = _topicController.text.trim();
    if (topicText.isEmpty) return;

    setState(() {
      _joining = true;
      _joinError = null;
    });
    try {
      final pear = await Pear.start();
      final topic = PearCrypto.unsafeTopicFromString(topicText);
      final swarm = await pear.join(topic);
      final drive = await pear.drive(name: 'file-drop-demo');

      swarm.state.listen(_onStatus);
      swarm.connections.listen((conn) => _onConnection(pear, drive, conn));

      setState(() {
        _pear = pear;
        _swarm = swarm;
        _drive = drive;
        _status = swarm.currentState;
      });
    } on PearException catch (e) {
      setState(() => _joinError = e.toString());
    } finally {
      setState(() => _joining = false);
    }
  }

  Future<void> _pickAndSend() async {
    final drive = _drive;
    // Also guards against re-entrancy: without this, a second tap while a
    // pick+send is already in flight could pick a same-named file and
    // (pre-fix) truncate the first pick's bytes mid-read, or (post-fix)
    // simply race two transfers concurrently for no reason.
    if (drive == null || _transfer == _TransferStatus.sending) return;

    final PickedFile? picked;
    try {
      picked = await FilePickerChannel.pickFile();
    } on PlatformException catch (e) {
      setState(() => _log.add('pick failed: ${e.message ?? e.code}'));
      return;
    }
    if (picked == null) return;

    final path = picked.path;
    final name = picked.name;
    setState(() => _transfer = _TransferStatus.sending);
    try {
      // flutter_pear-ohv: the native picker Activity above backgrounds this
      // Activity for as long as the user takes to pick a file -- long
      // enough to cross PearLifecycle's auto-suspend linger window on a
      // slow pick. Its own auto-resume (fired the instant this Activity
      // returns to the foreground) is unawaited internally, so a
      // drive.put() issued right after picked resolves could race a
      // still-suspended worklet and fail with SEND_FAILED. pear.resume()
      // is idempotent and a fast no-op when nothing was suspended (checked
      // synchronously against WorkletState before any platform-channel
      // call) -- safe, near-free insurance here on every send, not just
      // the rare slow-pick case.
      await _pear?.resume();
      await drive.put('/$name', path);
      setState(() {
        _log.add('sent $name -- waiting for peers to pull it down');
        _transfer = _TransferStatus.done;
      });
    } on PearException catch (e) {
      setState(() {
        _log.add('send failed: $e');
        _transfer = _TransferStatus.idle;
      });
    }
  }

  Future<void> _checkForFiles() async {
    // Mirrors every PEER drive learned so far (see the class doc/
    // _onPeerDriveKey) -- never _drive, this device's own drive, which by
    // construction can only ever contain what THIS device itself put there.
    if (_peerDrives.isEmpty) {
      // Reachable while connected but before the key-exchange round trip
      // (see _onConnection/_onPeerDriveKey) finishes -- says so instead of
      // silently doing nothing, which read as a broken button rather than
      // "still connecting."
      setState(() => _log.add("haven't learned a peer's drive yet -- wait "
          'for the room to finish connecting and try again'));
      return;
    }
    setState(() => _transfer = _TransferStatus.receiving);
    try {
      // flutter_pear-ohv: same insurance as _pickAndSend -- backgrounding
      // the app (for any reason, not just the picker) before tapping this
      // button risks the same auto-suspend race. Near-free when nothing
      // was actually suspended.
      await _pear?.resume();
      final dir = await getApplicationDocumentsDirectory();
      var added = 0, changed = 0, removed = 0;
      for (final peerDrive in _peerDrives.values) {
        final result = await peerDrive.mirrorToDisk(dir.path);
        added += result.added;
        changed += result.changed;
        removed += result.removed;
      }
      setState(() {
        _log.add(
          'checked for files: $added added, $changed changed, $removed '
          'removed -> ${dir.path}',
        );
        _transfer = _TransferStatus.done;
      });
    } on PearException catch (e) {
      setState(() {
        _log.add('check failed: $e');
        _transfer = _TransferStatus.idle;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    // _swarm is set (via _adopt) before its drive finishes creating, so
    // there's a real gap where the room isn't ready to render yet -- unlike
    // _join(), which sets both together. Surface that gap (and any failure
    // during it) instead of rendering a half-wired room.
    final Widget body;
    if (_swarm == null) {
      body = _buildJoinForm();
    } else if (_drive == null) {
      body = Center(
        child: _joinError != null
            ? Text(_joinError!, style: const TextStyle(color: Colors.red))
            : const CircularProgressIndicator(),
      );
    } else {
      body = _buildRoom();
    }
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_pear file drop')),
      body: body,
    );
  }

  Widget _buildJoinForm() => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Demo only: joins by room name, same as the chat demo -- use '
              'Start/Join Room (QR) from the home screen for real '
              'QR/invite pairing instead.',
              style: TextStyle(color: Colors.deepOrange),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _topicController,
              decoration: const InputDecoration(labelText: 'Shared room name'),
              onSubmitted: (_) => _join(),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _joining ? null : _join,
              child: const Text('Join'),
            ),
            if (_joinError != null) ...[
              const SizedBox(height: 16),
              Text(_joinError!, style: const TextStyle(color: Colors.red)),
            ],
          ],
        ),
      );

  Widget _buildRoom() => Column(
        children: [
          if (_status != null) SwarmStatusBanner(status: _status!),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.all(8),
              child: Text(describeSwarmState(_status!)),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: _log.map(Text.new).toList(),
            ),
          ),
          if (_transfer == _TransferStatus.sending ||
              _transfer == _TransferStatus.receiving)
            const Padding(
              padding: EdgeInsets.all(16),
              child: LinearProgressIndicator(),
            ),
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                ElevatedButton(
                  onPressed:
                      _transfer == _TransferStatus.sending ? null : _pickAndSend,
                  child: const Text('Pick & send file'),
                ),
                ElevatedButton(
                  onPressed: _checkForFiles,
                  child: const Text('Check for files'),
                ),
              ],
            ),
          ),
        ],
      );
}
