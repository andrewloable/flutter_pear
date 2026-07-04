import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_pear/flutter_pear.dart';
import 'package:path_provider/path_provider.dart';

import 'file_picker_channel.dart';
import 'main.dart' show SwarmStatusBanner, describeSwarmState;

/// E7.7 -- the second promised demo (chat is E7.1/E7.2): proves the E5.5
/// bulk-file path over the same room-joining affordance as chat. Sends a
/// picked file to every connected peer via [PearDrive.put] (streamed by
/// local file path, never loaded into memory -- see [PearDrive]'s own doc
/// for why that's what makes a large file safe here) and lets a peer pull
/// down anything new with [PearDrive.mirrorToDisk].
///
/// Joins by room NAME (`PearCrypto.unsafeTopicFromString`), same as
/// [ChatScreen] -- E7.2's QR/invite pairing flow isn't built yet; this
/// reuses whatever room-joining mechanism chat currently has rather than
/// inventing a second one, and will switch to the real pairing flow
/// alongside chat once E7.2 lands (see that task's own notes).
class FileDropScreen extends StatefulWidget {
  /// Creates the file-drop demo screen.
  const FileDropScreen({super.key});

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

      swarm.state.listen((status) {
        if (!mounted) return;
        setState(() => _status = status);
      });
      swarm.connections.listen((conn) {
        // Both sides replicate the same named drive over every connection
        // that shows up -- mirrors PearConnection's own "call on both
        // peers" contract for replicate().
        drive.replicate(conn);
        _log.add('replicating with ${conn.remotePublicKey.hex.substring(0, 8)}…');
        if (mounted) setState(() {});
      });

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
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('flutter_pear file drop')),
        body: _swarm == null ? _buildJoinForm() : _buildRoom(),
      );

  Widget _buildJoinForm() => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Demo only: joins by room name, same as the chat demo -- '
              'switches to real QR/invite pairing once that lands (E7.2).',
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
