import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_pear/flutter_pear.dart';

import 'file_picker_channel.dart';
import 'transfer_protocol.dart';

/// Which side of a transfer a [FileTransferCard] describes.
enum TransferDirection {
  /// This device is the sender.
  sending,

  /// This device is the receiver.
  receiving,
}

/// One recipient's (for [TransferDirection.sending]) or the sender's (for
/// [TransferDirection.receiving]) individual state within a
/// [FileTransferCard].
enum TransferPeerState {
  /// Still waiting on this peer (an ack, for sending; the mirror+copy step,
  /// for receiving).
  pending,

  /// This peer confirmed receipt ([TransferPeerState.acked]) — sending
  /// only; a receiving card is only ever created once already complete.
  acked,

  /// This peer's connection closed before it could confirm receipt —
  /// retryable via [FileTransferController.retry].
  failed,
}

/// This transfer's overall status — derived from a sending card's
/// per-recipient [FileTransferCard.peers] states, or set directly for a
/// receiving card (which involves exactly one peer, the sender).
enum TransferStatus {
  /// Sending: the local [PearDrive.put] is still in flight.
  sending,

  /// Sending: announced to every live recipient; none has acked or failed
  /// yet.
  waitingForRecipients,

  /// Sending: every targeted recipient acked. Receiving: the file landed
  /// in the received directory and the ack was sent.
  sent,

  /// Sending: some recipients acked, others are still pending or failed —
  /// render this as "per-peer status rows" (one row per
  /// [FileTransferCard.peers] entry).
  partiallySent,

  /// Sending: every targeted recipient failed (none acked) — retryable.
  failed,

  /// Receiving: the drive mirror + copy-to-received step is in flight.
  receiving,

  /// Receiving: the file landed in the received directory and the ack was
  /// sent — same terminal meaning as [sent], kept as a distinct value so a
  /// direction-blind switch still reads clearly.
  received,

  /// Receiving: the mirror or copy step threw. [FileTransferController]
  /// already retried it once automatically; this is only reached if that
  /// retry also failed.
  receiveFailed,
}

/// One entry in [FileTransferController.cardsByPeer] — one file, one
/// direction, one or more peers.
///
/// For [TransferDirection.sending], [peers] has one entry per targeted
/// recipient (short 8-hex-char peer key) — this is what lets the UI render
/// "per-peer status rows" for a [TransferStatus.partiallySent] card, and is
/// why the SAME card instance appears under every targeted recipient's
/// group in [FileTransferController.cardsByPeer]. For
/// [TransferDirection.receiving], [peers] has exactly one entry, the
/// sender.
@immutable
class FileTransferCard {
  /// Creates a transfer card. Apps never construct this directly —
  /// [FileTransferController] owns the whole lifecycle.
  const FileTransferCard({
    required this.name,
    required this.size,
    required this.direction,
    required this.timestamp,
    required this.status,
    required this.peers,
    this.sourceLocalPath,
  });

  /// The file's name.
  final String name;

  /// The file's size in bytes.
  final int size;

  /// Which side of the transfer this device is on.
  final TransferDirection direction;

  /// When this card was created.
  final DateTime timestamp;

  /// This transfer's overall status — see [TransferStatus].
  final TransferStatus status;

  /// Per-peer state, keyed by short (8-hex-char) peer key — see this
  /// class's own doc for the sending-vs-receiving shape difference.
  final Map<String, TransferPeerState> peers;

  /// The original local file path this was sent from (sending only, null
  /// for receiving) — kept so [FileTransferController.retry] can re-`put`
  /// if the file is no longer in this device's own drive.
  final String? sourceLocalPath;

  FileTransferCard _copyWith({
    TransferStatus? status,
    Map<String, TransferPeerState>? peers,
  }) =>
      FileTransferCard(
        name: name,
        size: size,
        direction: direction,
        timestamp: timestamp,
        status: status ?? this.status,
        peers: peers ?? this.peers,
        sourceLocalPath: sourceLocalPath,
      );

  @override
  String toString() =>
      'FileTransferCard($direction $name, $status, peers: $peers)';
}

TransferStatus _deriveSendStatus(Map<String, TransferPeerState> peers) {
  if (peers.isEmpty) return TransferStatus.sent;
  var acked = 0, failed = 0, pending = 0;
  for (final state in peers.values) {
    switch (state) {
      case TransferPeerState.acked:
        acked++;
      case TransferPeerState.failed:
        failed++;
      case TransferPeerState.pending:
        pending++;
    }
  }
  if (acked == peers.length) return TransferStatus.sent;
  if (failed == peers.length) return TransferStatus.failed;
  if (pending == peers.length) return TransferStatus.waitingForRecipients;
  return TransferStatus.partiallySent;
}

/// Drives the hardened file-drop demo's transfer state machine (Eng review
/// round 2, replacing the rejected single-status/manual-poll/mirrors-
/// deletions design in the old `file_drop_screen.dart`).
///
/// Every dependency is constructor-injected (own [PearDrive], a
/// peer-drive-opener, the connection/status streams, and the two on-disk
/// roots) rather than reached for globally — this is what makes
/// [FileTransferController] testable directly against
/// `flutter_pear_test`'s `FakeBareWorklet`/`FakeSwarmHub`, the same seam
/// `flutter_pear`'s own tests use (`PearRpc(FakeBareWorklet(hub: ...))`
/// then `PearDrive.open`/`PearSwarm.join` directly), with no real worklet
/// or UI involved.
///
/// A [ChangeNotifier]: call [addListener] and read [cardsByPeer] — matches
/// ordinary Flutter widget-binding idioms (`ListenableBuilder`) better than
/// a bespoke `Stream` would for a mutate-in-place card list, and this is
/// app-layer demo code, not `flutter_pear` itself (whose own
/// Future-for-calls/Stream-for-events convention this controller still
/// honors at ITS OWN boundary: [send]/[retry] are `Future`s, connection/
/// envelope handling is driven by the injected `Stream`s).
///
/// Automatic receive only — there is no manual "check for files" method.
/// [FileAnnounce] (see `transfer_protocol.dart`) is the only receive
/// trigger, since `PearDrive` exposes no watch/progress stream.
class FileTransferController extends ChangeNotifier {
  /// Creates a controller wired to [ownDrive] and the given connection
  /// lifecycle streams. [openPeerDrive] opens (or re-opens) a drive by key
  /// — normally `(key) => pear.drive(key: key)`. [stagingRoot] holds a
  /// full, disposable mirror of each peer's drive (deletions ARE reflected
  /// here); [receivedRoot] is the user-visible destination that files are
  /// individually COPIED into by name and NEVER pruned from, regardless of
  /// what happens in the peer's drive afterward. [resumeInsurance], if
  /// given, is called before every [send]/receive-triggering operation —
  /// the same `pear.resume()` insurance `file_drop_screen.dart` already
  /// applies against a slow picker/backgrounding race (flutter_pear-ohv).
  FileTransferController({
    required this.ownDrive,
    required this.openPeerDrive,
    required Stream<PearConnection> connections,
    required Stream<PearSwarmStatus> swarmStatus,
    required this.stagingRoot,
    required this.receivedRoot,
    this.resumeInsurance,
  }) {
    _connectionsSub = connections.listen(_onConnection);
    _statusSub = swarmStatus.listen((status) {
      _status = status;
      notifyListeners();
    });
  }

  /// This device's own drive — every [send] puts into it.
  final PearDrive ownDrive;

  /// Opens (or re-opens) a peer's drive by its announced key.
  final Future<PearDrive> Function(PearKey key) openPeerDrive;

  /// Root directory each peer's drive is mirrored into, one subdirectory
  /// per short peer key — disposable; deletions from the peer's drive DO
  /// show up here on the next mirror.
  final String stagingRoot;

  /// Root directory received files are copied into, one subdirectory per
  /// short peer key — never pruned, regardless of what the peer's drive
  /// does afterward.
  final String receivedRoot;

  /// Called before every send/receive operation that touches the worklet —
  /// see the constructor's own doc.
  final Future<void> Function()? resumeInsurance;

  StreamSubscription<PearConnection>? _connectionsSub;
  StreamSubscription<PearSwarmStatus>? _statusSub;
  PearSwarmStatus? _status;

  // Keyed by full peer hex -- same cache/re-replicate-on-every-reconnect
  // rationale as the old file_drop_screen.dart's _peerDrives (see
  // _onDriveAnnounce).
  final _peerDrives = <String, PearDrive>{};

  // Currently-live connections, full-hex-keyed -- refreshed on every
  // connect/disconnect so send() always targets who's ACTUALLY connected
  // right now, and retry() can find a peer's latest connection after a
  // reconnect (a new PearConnection object, never the old one -- see
  // PearConnection's own ephemeral-connection doc).
  final _liveConnections = <String, PearConnection>{};

  // Serializes mirror+copy operations per peer (full hex key) -- concurrent
  // DRIVE_MIRROR_TO_DISK calls on the same peer's staging dir would race on
  // the same files (eng review 10).
  final _mirrorQueues = <String, Future<void>>{};

  final _cards = <FileTransferCard>[];

  /// This swarm's current connection status, or null before the first
  /// event arrives.
  PearSwarmStatus? get status => _status;

  /// Every [FileTransferCard] so far, grouped by short (8-hex-char) peer
  /// key — a card appears under every peer key present in its own
  /// [FileTransferCard.peers] (so a multi-recipient send appears under
  /// each recipient's group; a receive appears under just the sender's).
  Map<String, List<FileTransferCard>> get cardsByPeer {
    final out = <String, List<FileTransferCard>>{};
    for (final card in _cards) {
      for (final peerShort in card.peers.keys) {
        (out[peerShort] ??= []).add(card);
      }
    }
    return out;
  }

  /// Every currently-connected peer's short (8-hex-char) key — lets a UI
  /// render a group (even an empty "nothing yet" one) for a connected peer
  /// with no [FileTransferCard] of its own yet, and show a live peer count
  /// on the connection status banner. Unlike `PearSwarm.establishedConnections`
  /// (which, by design, keeps every connection ever seen, including closed
  /// ones — see its own doc), this reflects only who's connected RIGHT NOW.
  Set<String> get connectedPeers =>
      _liveConnections.keys.map((hex) => hex.substring(0, 8)).toSet();

  void _onConnection(PearConnection conn) {
    final peerHex = conn.remotePublicKey.hex;
    final peerShort = peerHex.substring(0, 8);
    _liveConnections[peerHex] = conn;
    notifyListeners();

    // A connection can close (or the peer can vanish) between this call
    // being issued and its response -- neither is fatal to the controller,
    // so both are fire-and-forget with an explicit swallow rather than an
    // unhandled Future error.
    unawaited(ownDrive.replicate(conn).catchError((_) {}));
    unawaited(conn
        .write(DriveAnnounce(ownDrive.key.hex).toBytes())
        .catchError((_) {}));

    conn.data.listen(
      (bytes) => _onEnvelope(peerHex, peerShort, conn, bytes),
      onDone: () => _onDisconnect(peerHex),
    );
  }

  void _onDisconnect(String peerHex) {
    _liveConnections.remove(peerHex);
    for (var i = 0; i < _cards.length; i++) {
      final card = _cards[i];
      if (card.direction != TransferDirection.sending) continue;
      final peerShort = peerHex.substring(0, 8);
      final state = card.peers[peerShort];
      if (state != TransferPeerState.pending) continue;
      final peers = Map<String, TransferPeerState>.from(card.peers)
        ..[peerShort] = TransferPeerState.failed;
      _cards[i] = card._copyWith(
          peers: peers, status: _deriveSendStatus(peers));
    }
    // Always -- even with no card affected, connectedPeers just changed.
    notifyListeners();
  }

  Future<void> _onEnvelope(
    String peerHex,
    String peerShort,
    PearConnection conn,
    Uint8List bytes,
  ) async {
    final TransferMessage? message;
    try {
      message = decodeEnvelope(bytes);
    } on FormatException {
      // An untrusted peer sending garbage is never a crash -- log-and-ignore
      // (DO step 3).
      return;
    }
    if (message == null) return; // unknown type / newer version -- ignore.

    switch (message) {
      case DriveAnnounce(:final driveKeyHex):
        await _onDriveAnnounce(peerHex, driveKeyHex, conn);
      case FileAnnounce(:final name, :final size):
        await _enqueueReceive(peerHex, peerShort, name, size, conn);
      case FileReceived(:final name):
        _onAck(peerShort, name);
    }
  }

  Future<void> _onDriveAnnounce(
    String peerHex,
    String driveKeyHex,
    PearConnection conn,
  ) async {
    var peerDrive = _peerDrives[peerHex];
    if (peerDrive == null) {
      peerDrive = await openPeerDrive(PearKey.fromHex(driveKeyHex));
      _peerDrives[peerHex] = peerDrive;
    }
    // Re-issued on every announcement (every connection/reconnect),
    // deliberately not deduped -- a fresh PearConnection each reconnect
    // would otherwise leave a stale peer drive wired to a dead stream (same
    // rationale as the old file_drop_screen.dart's _onPeerDriveKey).
    await peerDrive.replicate(conn);
  }

  void _onAck(String peerShort, String name) {
    final i = _cards.indexWhere((c) =>
        c.direction == TransferDirection.sending &&
        c.name == name &&
        c.peers.containsKey(peerShort));
    if (i == -1) return;
    final card = _cards[i];
    final peers = Map<String, TransferPeerState>.from(card.peers)
      ..[peerShort] = TransferPeerState.acked;
    _cards[i] =
        card._copyWith(peers: peers, status: _deriveSendStatus(peers));
    notifyListeners();
  }

  Future<void> _enqueueReceive(
    String peerHex,
    String peerShort,
    String name,
    int size,
    PearConnection conn,
  ) {
    final previous = _mirrorQueues[peerHex] ?? Future<void>.value();
    final next = previous
        .then((_) => _receiveOne(peerHex, peerShort, name, size, conn))
        // A failed receive must never wedge this peer's queue -- the next
        // FileAnnounce still needs to run.
        .catchError((_) {});
    _mirrorQueues[peerHex] = next;
    return next;
  }

  Future<void> _receiveOne(
    String peerHex,
    String peerShort,
    String name,
    int size,
    PearConnection conn, {
    bool isRetry = false,
  }) async {
    final now = DateTime.now();
    final receivingCard = FileTransferCard(
      name: name,
      size: size,
      direction: TransferDirection.receiving,
      timestamp: now,
      status: TransferStatus.receiving,
      peers: {peerShort: TransferPeerState.pending},
    );
    final cardIndex = _cards.length;
    _cards.add(receivingCard);
    notifyListeners();

    try {
      await resumeInsurance?.call();
      final peerDrive = _peerDrives[peerHex];
      if (peerDrive == null) {
        throw StateError(
            'received a fileAnnounce from $peerShort before its '
            'driveAnnounce -- nothing to mirror');
      }
      final stagingDir = '$stagingRoot/$peerShort';
      await Directory(stagingDir).create(recursive: true);
      final receivedDir = '$receivedRoot/$peerShort';
      await Directory(receivedDir).create(recursive: true);

      await peerDrive.mirrorToDisk(stagingDir);
      // Copies ONLY the file this specific FileAnnounce named -- never a
      // bulk re-sync of the whole staging directory into receivedRoot, so
      // a file the peer has since deleted from their drive (which DOES
      // show up as a removal in staging on the NEXT mirror) can never be
      // pruned from receivedRoot by this step touching an unrelated name
      // (DO step 3's "NEVER deleting anything there").
      final stagedFile = File(_drivePath(stagingDir, name));
      final receivedFile = File(_drivePath(receivedDir, name));
      await receivedFile.parent.create(recursive: true);
      await stagedFile.copy(receivedFile.path); // overwrites same names.

      _cards[cardIndex] = receivingCard._copyWith(
        status: TransferStatus.received,
        peers: {peerShort: TransferPeerState.acked},
      );
      notifyListeners();
      await conn.write(FileReceived(name).toBytes());
    } catch (_) {
      if (isRetry) {
        _cards[cardIndex] = receivingCard._copyWith(
          status: TransferStatus.receiveFailed,
          peers: {peerShort: TransferPeerState.failed},
        );
        notifyListeners();
        return;
      }
      // receiveFailed is auto-retried exactly once (DO step 2's "auto-
      // retry") -- if the retry also fails, it's left at receiveFailed
      // above, a terminal state until the peer re-announces.
      await _receiveOne(peerHex, peerShort, name, size, conn,
          isRetry: true);
    }
  }

  /// Sends [picked] to every currently-connected peer: puts it into
  /// [ownDrive], deletes the staged picker copy at [PickedFile.path] (it
  /// would otherwise exist three times on device — eng review 10), then
  /// announces it. Creates one [FileTransferCard] per targeted recipient
  /// (see that class's own doc). A no-op if no peer is currently
  /// connected.
  Future<void> send(PickedFile picked) async {
    await resumeInsurance?.call();
    final name = picked.name;
    final sizeBytes = await File(picked.path).length();
    await ownDrive.put('/$name', picked.path);
    await File(picked.path).delete();

    final recipients = Map<String, PearConnection>.from(_liveConnections);
    final now = DateTime.now();
    final peers = {
      for (final peerHex in recipients.keys)
        peerHex.substring(0, 8): TransferPeerState.pending,
    };
    final card = FileTransferCard(
      name: name,
      size: sizeBytes,
      direction: TransferDirection.sending,
      timestamp: now,
      status: _deriveSendStatus(peers),
      peers: peers,
      sourceLocalPath: picked.path,
    );
    _cards.add(card);
    notifyListeners();

    final announcement = FileAnnounce(name, sizeBytes).toBytes();
    for (final conn in recipients.values) {
      unawaited(conn.write(announcement).catchError((_) {}));
    }
  }

  /// Re-announces [card] to whichever targeted recipients haven't acked
  /// yet (pending or failed), resetting them to pending — only for
  /// recipients CURRENTLY connected; an offline recipient is left as-is
  /// until it reconnects and can be retried again. Re-`put`s from
  /// [FileTransferCard.sourceLocalPath] first if the file is no longer in
  /// [ownDrive] (e.g. this device was reinstalled). A no-op for a
  /// [TransferDirection.receiving] card or one that's already fully
  /// [TransferStatus.sent].
  Future<void> retry(FileTransferCard card) async {
    if (card.direction != TransferDirection.sending) return;
    final i = _cards.indexOf(card);
    if (i == -1) return;

    final retryable = card.peers.entries
        .where((e) => e.value != TransferPeerState.acked)
        .map((e) => e.key)
        .where(_liveConnections.keys
            .map((hex) => hex.substring(0, 8))
            .toSet()
            .contains)
        .toSet();
    if (retryable.isEmpty) return;

    if (!await ownDrive.exists('/${card.name}')) {
      final path = card.sourceLocalPath;
      if (path == null || !await File(path).exists()) {
        throw StateError(
            'cannot retry "${card.name}": no longer in this device\'s own '
            'drive and the original local file is gone too');
      }
      await ownDrive.put('/${card.name}', path);
    }

    final peers = Map<String, TransferPeerState>.from(card.peers);
    for (final peerShort in retryable) {
      peers[peerShort] = TransferPeerState.pending;
    }
    _cards[i] = card._copyWith(peers: peers, status: _deriveSendStatus(peers));
    notifyListeners();

    final announcement = FileAnnounce(card.name, card.size).toBytes();
    for (final entry in _liveConnections.entries) {
      if (!retryable.contains(entry.key.substring(0, 8))) continue;
      unawaited(entry.value.write(announcement).catchError((_) {}));
    }
  }

  @override
  void dispose() {
    unawaited(_connectionsSub?.cancel());
    unawaited(_statusSub?.cancel());
    super.dispose();
  }
}

String _drivePath(String root, String name) =>
    name.startsWith('/') ? '$root$name' : '$root/$name';
