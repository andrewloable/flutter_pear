import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_pear/flutter_pear.dart';
import 'package:path_provider/path_provider.dart';

import 'file_picker_channel.dart';
import 'file_transfer_controller.dart';
import 'main.dart'
    show PrejoinedSwarmWiring, SwarmStatusBanner, describeSwarmState;

/// Joins a shared topic and exchanges files with whoever else joins it --
/// the hardened E7.7 demo (Eng review round 2, design review's TD-D1/fix
/// 1/fix 2/fix 6): automatic receive via [FileTransferController] (no
/// manual "check for files" button), per-peer grouped file cards replacing
/// a developer log, one status banner.
///
/// Reachable ONLY via the QR/invite pairing flow ([FileDropScreen.joined])
/// -- TD-D1 retired the old plain room-name entry path this screen used to
/// have. Unlike `ChatScreen`, nothing else needs a bare room-name
/// constructor here: no hot-restart gate script targets file-drop.
class FileDropScreen extends StatefulWidget {
  /// Creates the file-drop screen already attached to [prejoinedSwarm]
  /// (joined via [prejoinedPear]) -- same ownership/wiring contract as
  /// `ChatScreen.joined`: this screen's [State.dispose] tears both down.
  /// [prejoinedWiring] has been buffering [prejoinedSwarm]'s events since
  /// before this screen existed -- see [PrejoinedSwarmWiring].
  const FileDropScreen.joined({
    super.key,
    required this.prejoinedPear,
    required this.prejoinedSwarm,
    required this.prejoinedWiring,
  });

  /// The already-started [Pear] this screen takes ownership of.
  final Pear prejoinedPear;

  /// The already-joined [PearSwarm] this screen takes ownership of.
  final PearSwarm prejoinedSwarm;

  /// The [PrejoinedSwarmWiring] buffering [prejoinedSwarm]'s events since
  /// before this screen existed.
  final PrejoinedSwarmWiring prejoinedWiring;

  @override
  State<FileDropScreen> createState() => _FileDropScreenState();
}

class _FileDropScreenState extends State<FileDropScreen> {
  FileTransferController? _controller;
  String? _initError;
  bool _sending = false;
  final _debugLog = <String>[];
  final _knownReceivedCards = <FileTransferCard>{};

  @override
  void initState() {
    super.initState();
    unawaited(_init());
  }

  @override
  void dispose() {
    _controller?.removeListener(_onControllerChanged);
    _controller?.dispose();
    final pear = widget.prejoinedPear;
    // Same sequencing as ChatScreen.dispose: leave() must fully finish
    // (its RPC round trip) before pear.dispose() tears down the same RPC
    // bridge out from under it.
    widget.prejoinedSwarm.leave().catchError((_) {}).whenComplete(pear.dispose);
    super.dispose();
  }

  Future<void> _init() async {
    final pear = widget.prejoinedPear;
    final PearDrive drive;
    try {
      drive = await pear.drive(name: 'file-drop-demo');
    } on PearException catch (e) {
      if (!mounted) return;
      setState(() => _initError = e.toString());
      return;
    }
    final supportDir = await getApplicationSupportDirectory();
    final docsDir = await getApplicationDocumentsDirectory();
    if (!mounted) return;

    // FileTransferController subscribes to these the instant it's
    // constructed, then prejoinedWiring's replay (below) feeds it whatever
    // arrived in the pairing-flow gap before this screen existed -- same
    // subscribe-before-replay ordering PrejoinedSwarmWiring's own doc
    // requires, without needing the controller itself to know about
    // pairing-flow plumbing (it only ever sees the two plain Streams its
    // constructor already asks for).
    final connectionsController = StreamController<PearConnection>.broadcast();
    final statusController = StreamController<PearSwarmStatus>.broadcast();
    final controller = FileTransferController(
      ownDrive: drive,
      openPeerDrive: (key) => pear.drive(key: key),
      connections: connectionsController.stream,
      swarmStatus: statusController.stream,
      stagingRoot: '${supportDir.path}/pear-drive-staging',
      receivedRoot: '${docsDir.path}/received',
      resumeInsurance: pear.resume,
    );
    controller.addListener(_onControllerChanged);
    widget.prejoinedWiring.drainInto(
      (status) {
        statusController.add(status);
        _debugLog.add(describeSwarmState(status));
      },
      connectionsController.add,
    );
    setState(() => _controller = controller);
  }

  // Only the snackbar side effect -- FileDropBody rebuilds itself on every
  // controller change via its own ListenableBuilder, so this doesn't also
  // need a setState() to keep the UI current.
  void _onControllerChanged() {
    if (!mounted) return;
    _showSnackbarsForNewlyReceivedCards();
  }

  /// "receive SUCCESS -> completed card, tap = Open / Share, plus a
  /// snackbar" -- [ChangeNotifier] only says "something changed", not
  /// what, so this diffs against [_knownReceivedCards] (identity-keyed by
  /// the card objects themselves, which [FileTransferController] replaces
  /// rather than mutates) to find cards that just became `received` and
  /// weren't already announced.
  void _showSnackbarsForNewlyReceivedCards() {
    final controller = _controller;
    if (controller == null) return;
    for (final card in controller.cardsByPeer.values.expand((c) => c)) {
      if (card.direction != TransferDirection.receiving) continue;
      if (card.status != TransferStatus.received) continue;
      if (!_knownReceivedCards.add(card)) continue;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Received ${card.name}')),
      );
    }
  }

  Future<void> _pickAndSend() async {
    final controller = _controller;
    if (controller == null || _sending) return;
    final PickedFile? picked;
    try {
      picked = await FilePickerChannel.pickFile();
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Pick failed: ${e.message ?? e.code}')),
      );
      return;
    }
    if (picked == null) return;
    setState(() => _sending = true);
    try {
      await controller.send(picked);
    } finally {
      if (mounted) setState(() => _sending = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('flutter_pear file drop')),
        body: Center(
          child: _initError != null
              ? Text(_initError!, style: const TextStyle(color: Colors.red))
              : const CircularProgressIndicator(),
        ),
      );
    }
    return Scaffold(
      appBar: AppBar(title: const Text('flutter_pear file drop')),
      body: FileDropBody(
        controller: controller,
        sending: _sending,
        onPickAndSend: _pickAndSend,
        debugLog: _debugLog,
      ),
    );
  }
}

/// The file-drop room's body once its [FileTransferController] exists --
/// pulled out of [FileDropScreen] as its own public, directly-testable
/// widget: a widget test can pump this against a REAL [FileTransferController]
/// backed by `flutter_pear_test`'s fake worklet (same pattern
/// `file_transfer_controller_test.dart` already uses), without needing a
/// real `Pear`/`PearSwarm`/native platform channel to stand up
/// [FileDropScreen] itself. Self-updating via [ListenableBuilder] -- no
/// external `setState` orchestration required.
class FileDropBody extends StatelessWidget {
  /// Creates the body for [controller]. [sending] disables the send button
  /// mid-pick/put; [onPickAndSend] starts a new send; [debugLog] is shown
  /// behind the collapsible dev toggle (design fix 6), never as primary
  /// content.
  const FileDropBody({
    super.key,
    required this.controller,
    required this.sending,
    required this.onPickAndSend,
    required this.debugLog,
  });

  /// The controller driving this body's state.
  final FileTransferController controller;

  /// Whether a send is currently in flight (disables the send button).
  final bool sending;

  /// Called to pick and send a new file.
  final VoidCallback onPickAndSend;

  /// Verbose connection-state transitions, newest last -- shown only
  /// inside the collapsible "Debug log" section.
  final List<String> debugLog;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: controller,
        builder: (context, _) {
          final status = controller.status;
          final peerCount = controller.connectedPeers.length;
          return Column(
            children: [
              if (status != null)
                SwarmStatusBanner(status: status, peerCount: peerCount),
              Padding(
                padding: const EdgeInsets.all(16),
                child: ElevatedButton.icon(
                  onPressed: sending ? null : onPickAndSend,
                  icon: const Icon(Icons.upload_file),
                  label: const Text('Send a file'),
                ),
              ),
              Expanded(child: _buildPeerGroups(controller)),
              _buildDebugLog(),
            ],
          );
        },
      );

  Widget _buildPeerGroups(FileTransferController controller) {
    final cardsByPeer = controller.cardsByPeer;
    // Every connected peer gets a group, even with zero cards yet ("Nothing
    // from this peer yet" -- design fix 1's warm per-peer empty state) --
    // plus any peer with cards from BEFORE it disconnected, so history
    // doesn't vanish just because the peer isn't live right now.
    final peerShorts = {...controller.connectedPeers, ...cardsByPeer.keys}
        .toList()
      ..sort();
    if (peerShorts.isEmpty) {
      return const Center(child: Text('No peers connected yet.'));
    }
    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      children: [
        for (final peerShort in peerShorts)
          _PeerGroup(
              peerShort: peerShort,
              cards: cardsByPeer[peerShort] ?? const [],
              onRetry: controller.retry),
      ],
    );
  }

  Widget _buildDebugLog() => ExpansionTile(
        title: const Text('Debug log'),
        initiallyExpanded: false,
        children: [
          SizedBox(
            height: 160,
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: debugLog.length,
              itemBuilder: (context, i) => Text(
                debugLog[i],
                style: const TextStyle(
                    color: Colors.grey, fontStyle: FontStyle.italic),
              ),
            ),
          ),
        ],
      );
}

class _PeerGroup extends StatelessWidget {
  const _PeerGroup({
    required this.peerShort,
    required this.cards,
    required this.onRetry,
  });

  final String peerShort;
  final List<FileTransferCard> cards;
  final Future<void> Function(FileTransferCard) onRetry;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SizedBox(height: 16),
          Text('Peer $peerShort',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          if (cards.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text('Nothing from this peer yet',
                  style: TextStyle(
                      color: Colors.grey, fontStyle: FontStyle.italic)),
            )
          else
            for (final card in cards)
              _FileCard(card: card, peerShort: peerShort, onRetry: onRetry),
        ],
      );
}

class _FileCard extends StatelessWidget {
  const _FileCard({
    required this.card,
    required this.peerShort,
    required this.onRetry,
  });

  final FileTransferCard card;
  final String peerShort;
  final Future<void> Function(FileTransferCard) onRetry;

  bool get _inFlight =>
      card.status == TransferStatus.sending ||
      card.status == TransferStatus.waitingForRecipients ||
      card.status == TransferStatus.receiving;

  bool get _failed =>
      card.status == TransferStatus.failed ||
      card.status == TransferStatus.receiveFailed;

  bool get _done =>
      card.status == TransferStatus.sent ||
      card.status == TransferStatus.received;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Icon(card.direction == TransferDirection.sending
                      ? Icons.upload
                      : Icons.download),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(card.name,
                        style: Theme.of(context).textTheme.bodyLarge),
                  ),
                  Text(_humanSize(card.size),
                      style: Theme.of(context).textTheme.bodySmall),
                ],
              ),
              const SizedBox(height: 4),
              if (_inFlight) const LinearProgressIndicator(),
              if (!_inFlight) Text(_resultText(), style: _resultStyle()),
              if (card.direction == TransferDirection.sending &&
                  card.peers.length > 1)
                for (final entry in card.peers.entries)
                  Text('  ${entry.key}: ${_peerStateText(entry.value)}',
                      style: Theme.of(context).textTheme.bodySmall),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  if (_failed &&
                      card.direction == TransferDirection.sending)
                    TextButton(
                      onPressed: () => onRetry(card),
                      child: const Text('Retry'),
                    ),
                  if (_done && card.direction == TransferDirection.receiving) ...[
                    TextButton(onPressed: () {}, child: const Text('Open')),
                    TextButton(onPressed: () {}, child: const Text('Share')),
                  ],
                ],
              ),
            ],
          ),
        ),
      );

  String _resultText() => switch (card.status) {
        TransferStatus.sent => 'Sent ✓',
        TransferStatus.partiallySent => 'Sent to some peers',
        TransferStatus.failed => 'Failed -- not delivered',
        TransferStatus.received => 'Received ✓',
        TransferStatus.receiveFailed => 'Failed to receive',
        TransferStatus.sending ||
        TransferStatus.waitingForRecipients ||
        TransferStatus.receiving =>
          '',
      };

  TextStyle _resultStyle() => TextStyle(
        color: _failed
            ? Colors.red
            : _done
                ? Colors.green
                : Colors.grey,
      );

  String _peerStateText(TransferPeerState state) => switch (state) {
        TransferPeerState.pending => 'pending',
        TransferPeerState.acked => 'delivered ✓',
        TransferPeerState.failed => 'failed',
      };
}

String _humanSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}
