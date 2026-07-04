import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';

void main() => runApp(const ChatApp());

/// E7.1 -- the "clone this repo, run on two phones, chat" proof. Joins a
/// topic over Hyperswarm and exchanges plaintext messages with every
/// connected peer, with the swarm's connection state (X8) shown prominently
/// -- this screen is as much an honesty demo (does flutter_pear tell you
/// what's actually happening) as it is a chat app.
class ChatApp extends StatelessWidget {
  /// Creates the demo app.
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) => const MaterialApp(
        title: 'flutter_pear chat',
        home: ChatScreen(),
      );
}

/// One line in the chat log: a message this device sent, one received from
/// a peer, or a connection-state change notice.
class ChatLogLine {
  /// A message this device sent.
  ChatLogLine.sent(this.text)
      : own = true,
        isStateChange = false;

  /// A message received from a peer.
  ChatLogLine.received(this.text)
      : own = false,
        isStateChange = false;

  /// A connection-state change notice.
  ChatLogLine.stateChange(this.text)
      : own = false,
        isStateChange = true;

  /// The text to display.
  final String text;

  /// Whether this device sent it (right-aligned) versus received it or it's
  /// a state notice (left-aligned).
  final bool own;

  /// Whether this is a connection-state notice rather than a chat message.
  final bool isStateChange;
}

/// Joins a shared topic and chats with whoever else joins it.
class ChatScreen extends StatefulWidget {
  /// Creates the chat screen.
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _topicController = TextEditingController();
  final _messageController = TextEditingController();
  final _log = <ChatLogLine>[];

  Pear? _pear;
  PearSwarm? _swarm;
  PearSwarmStatus? _status;
  String? _joinError;
  bool _joining = false;
  StreamSubscription<PearSwarmStatus>? _stateSub;
  StreamSubscription<PearConnection>? _connectionsSub;

  @override
  void dispose() {
    _stateSub?.cancel();
    _connectionsSub?.cancel();
    // State.dispose() must stay synchronous, so this can't await -- but it
    // must still be SEQUENCED: leave() awaits an RPC round trip before
    // closing its streams, and racing it against _pear's own dispose()
    // (which tears down that same RPC bridge) would fail leave()'s in-
    // flight call with a stray, unhandled WORKLET_DISPOSED exception.
    final pear = _pear;
    final leaving = _swarm?.leave();
    if (leaving != null) {
      leaving.catchError((_) {}).whenComplete(() => pear?.dispose());
    } else {
      pear?.dispose();
    }
    _topicController.dispose();
    _messageController.dispose();
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

      _stateSub = swarm.state.listen((status) {
        if (!mounted) return;
        setState(() {
          _status = status;
          _log.add(ChatLogLine.stateChange(describeSwarmState(status)));
        });
      });
      _connectionsSub = swarm.connections.listen((conn) {
        conn.data.listen((bytes) {
          if (!mounted) return;
          setState(() => _log.add(ChatLogLine.received(utf8.decode(bytes))));
        });
      });

      setState(() {
        _pear = pear;
        _swarm = swarm;
        _status = swarm.currentState;
      });
    } on PearException catch (e) {
      setState(() => _joinError = e.toString());
    } finally {
      setState(() => _joining = false);
    }
  }

  Future<void> _send() async {
    final text = _messageController.text;
    final connections = _swarm?.establishedConnections ?? const [];
    if (text.isEmpty || connections.isEmpty) return;
    final bytes = Uint8List.fromList(utf8.encode(text));
    // A connection already closed since it was last seen fails write() with
    // connectionClosed (PearConnection has no public way to check first) --
    // caught per-connection so one stale peer can't block delivery to the
    // rest. Sent concurrently: independent peers, no reason to serialize.
    await Future.wait(connections.map(
      (conn) => conn.write(bytes).catchError((_) {}),
    ));
    setState(() => _log.add(ChatLogLine.sent(text)));
    _messageController.clear();
  }

  Future<void> _leave() async {
    await _stateSub?.cancel();
    await _connectionsSub?.cancel();
    await _swarm?.leave();
    await _pear?.dispose();
    setState(() {
      _swarm = null;
      _pear = null;
      _status = null;
      _log.clear();
    });
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(
          title: const Text('flutter_pear chat'),
          actions: [
            if (_swarm != null)
              IconButton(onPressed: _leave, icon: const Icon(Icons.logout)),
          ],
        ),
        body: _swarm == null ? _buildJoinForm() : _buildChat(),
      );

  Widget _buildJoinForm() => Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Demo only: this derives a topic straight from the text you '
              'type (PearCrypto.unsafeTopicFromString) -- every device '
              'worldwide using the same text joins the same room. Real '
              'apps use PearPairing invites instead.',
              style: TextStyle(color: Colors.deepOrange),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _topicController,
              decoration: const InputDecoration(
                labelText: 'Shared room name',
                hintText: 'e.g. my-secret-room',
              ),
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

  Widget _buildChat() => Column(
        children: [
          if (_status != null) SwarmStatusBanner(status: _status!),
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.all(16),
              itemCount: _log.length,
              itemBuilder: (context, i) => _buildLogLine(_log[i]),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _messageController,
                    onSubmitted: (_) => _send(),
                    decoration: const InputDecoration(hintText: 'Message'),
                  ),
                ),
                IconButton(onPressed: _send, icon: const Icon(Icons.send)),
              ],
            ),
          ),
        ],
      );

  Widget _buildLogLine(ChatLogLine line) {
    if (line.isStateChange) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Text(
          line.text,
          style: const TextStyle(
              color: Colors.grey, fontStyle: FontStyle.italic),
        ),
      );
    }
    return Align(
      alignment: line.own ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: line.own ? Colors.blue.shade100 : Colors.grey.shade200,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Text(line.text),
      ),
    );
  }
}

/// "Failed" alone, or with the reason appended, when [status] carries one --
/// shared by [describeSwarmState] and [SwarmStatusBanner] so the two never
/// drift on how a failure reads.
String _failedLabel(PearSwarmStatus status) =>
    'Failed${status.error == null ? '' : ': ${status.error!.message}'}';

/// The verbose, timeline-style description of [status] logged as each
/// [PearSwarmState] transition happens (contrast [SwarmStatusBanner]'s
/// terser current-state label) -- exposed top-level so it's unit-testable
/// without a running worklet.
String describeSwarmState(PearSwarmStatus status) => switch (status.state) {
      PearSwarmState.discovering => 'Looking for a peer on this topic…',
      PearSwarmState.connecting => 'Found a peer, connecting…',
      PearSwarmState.connected => 'Connected.',
      PearSwarmState.reconnecting => 'Peer dropped, looking again…',
      PearSwarmState.suspended => 'Suspended (app in background).',
      PearSwarmState.failed => _failedLabel(status),
    };

/// Shows the current [PearSwarmState] prominently -- grey while discovering/
/// connecting, green once connected, amber while reconnecting/suspended,
/// red with the failure reason if it fails -- so a stuck connection is
/// honestly visible instead of silently hidden behind a spinner. Public (not
/// example-internal) so it's directly widget-testable.
class SwarmStatusBanner extends StatelessWidget {
  /// Creates the banner for the swarm's current [status].
  const SwarmStatusBanner({super.key, required this.status});

  /// The swarm state this banner reflects.
  final PearSwarmStatus status;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (status.state) {
      PearSwarmState.discovering => (Colors.grey, 'Discovering…'),
      PearSwarmState.connecting => (Colors.grey, 'Connecting…'),
      PearSwarmState.connected => (Colors.green, 'Connected'),
      PearSwarmState.reconnecting => (Colors.amber, 'Reconnecting…'),
      PearSwarmState.suspended => (Colors.amber, 'Suspended'),
      PearSwarmState.failed => (Colors.red, _failedLabel(status)),
    };
    return Container(
      width: double.infinity,
      color: color.shade100,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: TextStyle(color: color.shade900)),
    );
  }
}
