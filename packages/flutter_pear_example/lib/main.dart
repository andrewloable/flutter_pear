import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_pear/flutter_pear.dart';

import 'pairing_screens.dart';

void main() => runApp(const ChatApp());

/// Set via `--dart-define` by `tool/ios_hot_restart_gate.sh`
/// (flutter_pear-ovt.3.2) to skip straight to [ChatScreen] and auto-join this
/// topic on launch, so a scripted hot-restart gate can observe
/// `Pear.start()`'s `reattached` status without driving any UI. Empty (the
/// default) for every real run, which restores the ordinary tap-through home
/// screen.
const _gateAutoJoinTopic =
    String.fromEnvironment('FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC');

/// The two promised demos (see `project_plan.md`): chat (E7.1/E7.2) and
/// file-drop (E7.7, proving the E5.5 bulk-file path).
class ChatApp extends StatelessWidget {
  /// Creates the demo app.
  const ChatApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'flutter_pear demos',
        home: _gateAutoJoinTopic.isEmpty
            ? const _DemoHomeScreen()
            : const ChatScreen(),
      );
}

/// The home screen: exactly two demo cards (TD-D1, design review's final
/// gate) -- Chat and File drop, each with its own Start room / Join room
/// actions, both riding the same QR/invite pairing flow
/// ([StartRoomScreen]/[JoinRoomScreen]) with a different [PairingDestination].
/// Replaces the six flat buttons and the plain room-name demo shortcuts
/// that used to sit directly on this screen.
class _DemoHomeScreen extends StatelessWidget {
  const _DemoHomeScreen();

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('flutter_pear demos')),
        body: SafeArea(
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: const [
              _DemoCard(title: 'Chat', destination: PairingDestination.chat),
              SizedBox(height: 16),
              _DemoCard(
                title: 'File drop',
                destination: PairingDestination.fileDrop,
              ),
            ],
          ),
        ),
      );
}

/// One home-screen demo card: a title and its Start room / Join room
/// actions for [destination] -- shared by both demos so they can never
/// drift on layout or copy.
class _DemoCard extends StatelessWidget {
  const _DemoCard({required this.title, required this.destination});

  final String title;
  final PairingDestination destination;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(title, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 12),
              ElevatedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => StartRoomScreen(destination: destination),
                  ),
                ),
                child: const Text('Start room'),
              ),
              const SizedBox(height: 8),
              OutlinedButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => JoinRoomScreen(destination: destination),
                  ),
                ),
                child: const Text('Join room'),
              ),
            ],
          ),
        ),
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

/// Buffers a freshly-joined [PearSwarm]'s `state`/`connections` events from
/// the instant it's created, until something is ready to consume them.
///
/// Exists to close a subscription gap in the QR/invite pairing flow
/// (`StartRoomScreen`/`JoinRoomScreen` in pairing_screens.dart): those
/// screens create the [PearSwarm] well before `ChatScreen.joined` exists --
/// `_ChatScreenState.initState` (where it would otherwise subscribe) only
/// runs a full `Navigator.pushReplacement` plus a frame later. Without this,
/// any state/connection event landing in that gap is silently and
/// permanently missed (broadcast streams, same discipline as everywhere
/// else in this codebase -- a late subscriber never sees what already
/// fired). Construct this immediately after `join()` resolves, with no
/// other `await` in between, exactly like every other subscribe-first site
/// in this codebase.
class PrejoinedSwarmWiring {
  /// Starts buffering [swarm]'s events right away.
  PrejoinedSwarmWiring(PearSwarm swarm)
      : stateSub = swarm.state.listen(null),
        connectionsSub = swarm.connections.listen(null) {
    stateSub.onData(_statuses.add);
    connectionsSub.onData(_connections.add);
  }

  /// The subscription buffering [PearSwarmStatus] events until [drainInto]
  /// re-points it. Exposed so a caller that ends up not handing this off
  /// (e.g. the pairing screen's own join()/confirm() failed, or the screen
  /// was unmounted first) can cancel it directly.
  final StreamSubscription<PearSwarmStatus> stateSub;

  /// The subscription buffering [PearConnection] events until [drainInto]
  /// re-points it. See [stateSub].
  final StreamSubscription<PearConnection> connectionsSub;

  final _statuses = <PearSwarmStatus>[];
  final _connections = <PearConnection>[];

  /// Re-points both subscriptions' handlers to [onStatus]/[onConnection]
  /// and replays whatever was buffered before this call, in arrival order.
  /// Call exactly once -- a second call has nothing left to replay.
  void drainInto(
    void Function(PearSwarmStatus) onStatus,
    void Function(PearConnection) onConnection,
  ) {
    stateSub.onData(onStatus);
    connectionsSub.onData(onConnection);
    for (final status in _statuses) {
      onStatus(status);
    }
    _statuses.clear();
    for (final conn in _connections) {
      onConnection(conn);
    }
    _connections.clear();
  }
}

/// Joins a shared topic and chats with whoever else joins it.
class ChatScreen extends StatefulWidget {
  /// Creates the chat screen with its own plain-topic room-name entry flow
  /// (the demo-only [PearCrypto.unsafeTopicFromString] shortcut) -- the
  /// existing entry point, unchanged.
  const ChatScreen({super.key})
      : prejoinedPear = null,
        prejoinedSwarm = null,
        prejoinedWiring = null;

  /// Creates the chat screen already attached to [prejoinedSwarm] (joined
  /// via [prejoinedPear]) -- used by the QR/invite pairing flow (E7.2's
  /// `StartRoomScreen`/`JoinRoomScreen`), which builds its own [Pear] and
  /// [PearSwarm] via `PearPairing` rather than this screen's room-name text
  /// field. This screen takes over ownership of both: its [State.dispose]
  /// tears them down exactly as it would one it created itself. [wiring]
  /// (required alongside [swarm]) is the [PrejoinedSwarmWiring] the caller
  /// started subscribing on the instant it created [swarm] -- see that
  /// class for why this can't just re-subscribe from scratch here.
  const ChatScreen.joined({
    super.key,
    required this.prejoinedPear,
    required this.prejoinedSwarm,
    required this.prejoinedWiring,
  });

  /// The already-started [Pear] to adopt instead of creating one, when this
  /// screen was constructed via [ChatScreen.joined]. Null for the plain
  /// [ChatScreen] constructor.
  final Pear? prejoinedPear;

  /// The already-joined [PearSwarm] to adopt instead of creating one, when
  /// this screen was constructed via [ChatScreen.joined]. Null for the
  /// plain [ChatScreen] constructor.
  final PearSwarm? prejoinedSwarm;

  /// The [PrejoinedSwarmWiring] already buffering [prejoinedSwarm]'s events
  /// since before this screen existed. Null for the plain [ChatScreen]
  /// constructor, where [_wireSwarm] subscribes fresh instead.
  final PrejoinedSwarmWiring? prejoinedWiring;

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
  void initState() {
    super.initState();
    final pear = widget.prejoinedPear;
    final swarm = widget.prejoinedSwarm;
    // Both null for the plain ChatScreen() constructor (room-name entry via
    // _join() below); both non-null for ChatScreen.joined() (the QR/invite
    // pairing flow, E7.2).
    if (pear != null && swarm != null) {
      _wireSwarm(pear, swarm, wiring: widget.prejoinedWiring);
    } else if (_gateAutoJoinTopic.isNotEmpty) {
      _topicController.text = _gateAutoJoinTopic;
      WidgetsBinding.instance.addPostFrameCallback((_) => _join());
    }
  }

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
      // Greppable for tool/ios_hot_restart_gate.sh (flutter_pear-ovt.3.2,
      // exact substring "flutter_pear example: reattached=") and
      // tool/release_gate.sh's ios-smoke gate (flutter_pear-beq, substring
      // "worklet attached") -- the only way to observe worklet-attach
      // success from outside the app. Keep the "reattached=" prefix exact:
      // ios_hot_restart_gate.sh matches it verbatim.
      debugPrint(
        'flutter_pear example: reattached=${pear.worklet.reattached} '
        '(worklet attached)',
      );
      final topic = PearCrypto.unsafeTopicFromString(topicText);
      final swarm = await pear.join(topic);
      setState(() => _wireSwarm(pear, swarm));
    } on PearException catch (e) {
      // Greppable for tool/release_gate.sh's ios-smoke gate (flutter_pear-beq):
      // surfaces a genuine join failure immediately instead of the gate
      // waiting out its full timeout before declaring failure.
      debugPrint('flutter_pear example: FLUTTER_PEAR_FIXTURE_FAILED: $e');
      setState(() => _joinError = e.toString());
    } finally {
      setState(() => _joining = false);
    }
  }

  /// Subscribes to [swarm]'s state/connections streams and adopts [pear] as
  /// this screen's active session -- shared by [_join] (which builds its
  /// own [pear]/[swarm] from a typed room name, so [wiring] is null and
  /// this subscribes fresh) and [initState] (when constructed via
  /// [ChatScreen.joined] with an already-built swarm from the QR/invite
  /// pairing flow, E7.2, where [wiring] has been buffering events since
  /// before this screen existed -- see [PrejoinedSwarmWiring]). Either way,
  /// the handlers are attached before anything else, matching this
  /// codebase's established late-subscriber-race discipline -- a broadcast-
  /// stream event that arrives before a listener attaches is simply missed.
  void _wireSwarm(Pear pear, PearSwarm swarm, {PrejoinedSwarmWiring? wiring}) {
    void onStatus(PearSwarmStatus status) {
      if (!mounted) return;
      setState(() {
        _status = status;
        _log.add(ChatLogLine.stateChange(describeSwarmState(status)));
      });
    }

    void onConnection(PearConnection conn) {
      conn.data.listen((bytes) {
        if (!mounted) return;
        setState(() => _log.add(ChatLogLine.received(utf8.decode(bytes))));
      });
    }

    if (wiring != null) {
      _stateSub = wiring.stateSub;
      _connectionsSub = wiring.connectionsSub;
      wiring.drainInto(onStatus, onConnection);
    } else {
      _stateSub = swarm.state.listen(onStatus);
      _connectionsSub = swarm.connections.listen(onConnection);
    }
    _pear = pear;
    _swarm = swarm;
    _status = swarm.currentState;
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
    final delivered = await Future.wait(connections.map(
      (conn) => conn.write(bytes).then((_) => true).catchError((_) => false),
    ));
    final failedCount = delivered.where((ok) => !ok).length;
    setState(() {
      _log.add(ChatLogLine.sent(text));
      // Honest delivery signal (flutter_pear-doi hardware finding): write()
      // already throws per the library's own documented contract -- this
      // demo used to swallow that silently and always claim "sent", which
      // looked identical whether the peer actually got the message or not.
      if (failedCount > 0) {
        _log.add(ChatLogLine.stateChange(
          failedCount == connections.length
              ? 'not delivered -- connection dropped'
              : 'not delivered to $failedCount of ${connections.length} peers',
        ));
      }
    });
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
  /// Creates the banner for the swarm's current [status]. [peerCount], when
  /// given, is appended to the connected label (e.g. "Connected · 2 peers")
  /// -- omit it (the default) to show the plain "Connected" text unchanged,
  /// which is what every OTHER [PearSwarmState] label already does and what
  /// callers that don't track live peer counts should keep doing.
  const SwarmStatusBanner({super.key, required this.status, this.peerCount});

  /// The swarm state this banner reflects.
  final PearSwarmStatus status;

  /// The number of currently-connected peers to show alongside a
  /// [PearSwarmState.connected] label, or null to omit it.
  final int? peerCount;

  @override
  Widget build(BuildContext context) {
    final (color, text) = switch (status.state) {
      PearSwarmState.discovering => (Colors.grey, 'Discovering…'),
      PearSwarmState.connecting => (Colors.grey, 'Connecting…'),
      PearSwarmState.connected => (
          Colors.green,
          peerCount == null
              ? 'Connected'
              : 'Connected · $peerCount ${peerCount == 1 ? 'peer' : 'peers'}',
        ),
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
