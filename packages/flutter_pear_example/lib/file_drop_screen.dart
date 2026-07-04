import 'dart:async' show unawaited;

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
      wiring.drainInto(_onStatus, (conn) => _onConnection(drive, conn));
    } else {
      swarm.state.listen(_onStatus);
      swarm.connections.listen((conn) => _onConnection(drive, conn));
    }
  }

  void _onStatus(PearSwarmStatus status) {
    if (!mounted) return;
    setState(() => _status = status);
  }

  void _onConnection(PearDrive drive, PearConnection conn) {
    // Both sides replicate the same named drive over every connection that
    // shows up -- mirrors PearConnection's own "call on both peers" contract
    // for replicate().
    drive.replicate(conn);
    _log.add('replicating with ${conn.remotePublicKey.hex.substring(0, 8)}…');
    if (mounted) setState(() {});
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
      swarm.connections.listen((conn) => _onConnection(drive, conn));

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
    final drive = _drive;
    if (drive == null) return;
    setState(() => _transfer = _TransferStatus.receiving);
    try {
      final dir = await getApplicationDocumentsDirectory();
      final result = await drive.mirrorToDisk(dir.path);
      setState(() {
        _log.add(
          'checked for files: ${result.added} added, ${result.changed} '
          'changed, ${result.removed} removed -> ${dir.path}',
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
