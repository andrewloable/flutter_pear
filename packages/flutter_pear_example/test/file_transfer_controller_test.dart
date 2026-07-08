import 'dart:io';

import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_example/file_picker_channel.dart';
import 'package:flutter_pear_example/file_transfer_controller.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

/// One test peer: a real [PearDrive]/[PearSwarm] over a fake worklet, plus
/// the [FileTransferController] under test wired to them. Keeps the raw
/// [FakeBareWorklet] too -- [FakeBareWorklet.disconnectFrom] and
/// [FakeSwarmHub.join] (for simulated rediscovery) both operate on it
/// directly, not through [PearRpc]/[PearSwarm].
class _Peer {
  _Peer._(
      this.worklet, this.rpc, this.swarm, this.drive, this.controller, this.dir);

  final FakeBareWorklet worklet;
  final PearRpc rpc;
  final PearSwarm swarm;
  final PearDrive drive;
  final FileTransferController controller;
  final Directory dir;

  Future<void> dispose() async {
    controller.dispose();
    await rpc.dispose();
  }
}

Future<_Peer> _setUpPeer(
  FakeSwarmHub hub,
  String label,
  PearKey topic,
  Directory tempRoot,
) async {
  final worklet = FakeBareWorklet(hub: hub);
  final rpc = PearRpc(worklet);
  await rpc.call(PearMethod.attachInfo);
  final drive = await PearDrive.open(rpc, name: 'file-drop-$label');
  final swarm = await PearSwarm.join(rpc, topic);
  final dir = Directory('${tempRoot.path}/$label')..createSync();
  final controller = FileTransferController(
    ownDrive: drive,
    openPeerDrive: (key) => PearDrive.open(rpc, key: key),
    connections: swarm.connections,
    swarmStatus: swarm.state,
    stagingRoot: '${dir.path}/staging',
    receivedRoot: '${dir.path}/received',
  );
  return _Peer._(worklet, rpc, swarm, drive, controller, dir);
}

/// Polls [condition] until it's true or [timeout] elapses -- the
/// send->announce->mirror->copy->ack pipeline crosses real async file I/O
/// and RPC round trips, not just microtasks, so a single `pumpEventQueue`
/// isn't always enough.
Future<void> _waitUntil(bool Function() condition,
    {Duration timeout = const Duration(seconds: 5)}) async {
  final deadline = DateTime.now().add(timeout);
  while (!condition()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('condition never became true within $timeout');
    }
    await Future<void>.delayed(const Duration(milliseconds: 5));
  }
}

Iterable<FileTransferCard> _allCards(FileTransferController c) =>
    c.cardsByPeer.values.expand((cards) => cards);

void main() {
  late Directory tempDir;
  late FakeSwarmHub hub;
  late PearKey topic;
  late _Peer alice;
  late _Peer bob;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('flutter_pear-transfer-test-');
    hub = FakeSwarmHub();
    topic = PearCrypto.unsafeTopicFromString('file-transfer-controller-test');
    alice = await _setUpPeer(hub, 'alice', topic, tempDir);
    bob = await _setUpPeer(hub, 'bob', topic, tempDir);
    // Lets both sides' connection/driveAnnounce/replicate exchange settle
    // before each test's own actions -- not strictly required (the receive
    // path retries once if a driveAnnounce hasn't landed yet), just a
    // margin so test bodies read as "act, then assert" rather than racing
    // connection setup.
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });

  tearDown(() async {
    await alice.dispose();
    await bob.dispose();
    await tempDir.delete(recursive: true);
  });

  Future<String> writeLocalFile(
      Directory dir, String name, String content) async {
    final file = File('${dir.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  test('end-to-end: send -> auto-receive -> ack -> sender card sent',
      () async {
    final path = await writeLocalFile(alice.dir, 'photo.png', 'bytes!');
    await alice.controller.send(PickedFile(path: path, name: 'photo.png'));

    // Auto-receive: no manual action on bob's side.
    await _waitUntil(() => _allCards(bob.controller)
        .any((c) => c.name == 'photo.png' && c.status == TransferStatus.received));

    final receivedCard =
        _allCards(bob.controller).firstWhere((c) => c.name == 'photo.png');
    expect(receivedCard.direction, TransferDirection.receiving);

    final peerShort = receivedCard.peers.keys.single;
    final receivedFile = File('${bob.dir.path}/received/$peerShort/photo.png');
    expect(await receivedFile.exists(), isTrue);
    expect(await receivedFile.readAsString(), 'bytes!');

    // Sender's own card reaches `sent` once bob's ack arrives.
    await _waitUntil(() => _allCards(alice.controller)
        .any((c) => c.name == 'photo.png' && c.status == TransferStatus.sent));
  });

  test('duplicate filenames overwrite within peer', () async {
    final path1 = await writeLocalFile(alice.dir, 'note.txt', 'first');
    await alice.controller.send(PickedFile(path: path1, name: 'note.txt'));
    await _waitUntil(() => _allCards(bob.controller)
        .any((c) => c.name == 'note.txt' && c.status == TransferStatus.received));

    final path2 = await writeLocalFile(alice.dir, 'note2.txt', 'second');
    // Same virtual name as before -- put() itself already overwrites at the
    // drive level (drive_test.dart's own documented contract); the receive
    // side must overwrite the on-disk file too, not create a second copy.
    await alice.controller.send(PickedFile(path: path2, name: 'note.txt'));
    await _waitUntil(() =>
        _allCards(bob.controller)
            .where((c) => c.name == 'note.txt' && c.status == TransferStatus.received)
            .length ==
        2);

    final peerShort = bob.controller.cardsByPeer.keys.single;
    final receivedFile = File('${bob.dir.path}/received/$peerShort/note.txt');
    expect(await receivedFile.readAsString(), 'second');
  });

  test(
      'a file removed from the sender drive survives in the receiver\'s '
      'received dir after a later, unrelated mirror (no deletion mirror)',
      () async {
    final path1 = await writeLocalFile(alice.dir, 'keep.txt', 'keep me');
    await alice.controller.send(PickedFile(path: path1, name: 'keep.txt'));
    await _waitUntil(() => _allCards(bob.controller)
        .any((c) => c.name == 'keep.txt' && c.status == TransferStatus.received));

    final peerShort = bob.controller.cardsByPeer.keys.single;
    final keptFile = File('${bob.dir.path}/received/$peerShort/keep.txt');
    expect(await keptFile.exists(), isTrue);

    // Alice deletes it from her own drive...
    await alice.drive.delete('/keep.txt');

    // ...then sends an UNRELATED second file, triggering another mirror.
    final path2 = await writeLocalFile(alice.dir, 'other.txt', 'other');
    await alice.controller.send(PickedFile(path: path2, name: 'other.txt'));
    await _waitUntil(() => _allCards(bob.controller)
        .any((c) => c.name == 'other.txt' && c.status == TransferStatus.received));

    // keep.txt must still be there -- receivedRoot is never pruned.
    expect(await keptFile.exists(), isTrue);
    expect(await keptFile.readAsString(), 'keep me');
  });

  test(
      'interrupted transfer (connection closes before ack) -> failed, '
      'then retry succeeds', () async {
    final path = await writeLocalFile(alice.dir, 'big.bin', 'payload');
    await alice.controller.send(PickedFile(path: path, name: 'big.bin'));

    // Sever alice's connection to bob before bob's ack can arrive --
    // matches swarm_test.dart's own disconnect pattern: the side whose
    // .disconnectFrom is called is the side whose PearConnection closes.
    alice.worklet.disconnectFrom(bob.worklet);

    await _waitUntil(() => _allCards(alice.controller).any((c) =>
        c.name == 'big.bin' && c.peers.values.contains(TransferPeerState.failed)));

    var card = _allCards(alice.controller).firstWhere((c) => c.name == 'big.bin');
    expect(card.status, TransferStatus.failed);

    // Simulate Hyperswarm's own automatic rediscovery finding bob again
    // (same mechanism swarm_test.dart's reconnect-cycle test uses).
    hub.join(topic.hex, alice.worklet);
    await _waitUntil(
        () => alice.swarm.currentState.state == PearSwarmState.connected,
        timeout: const Duration(seconds: 10));

    card = _allCards(alice.controller).firstWhere((c) => c.name == 'big.bin');
    await alice.controller.retry(card);

    await _waitUntil(() => _allCards(alice.controller)
        .any((c) => c.name == 'big.bin' && c.status == TransferStatus.sent));
  });

  test('the staged picker copy is deleted after send', () async {
    final path = await writeLocalFile(alice.dir, 'ephemeral.txt', 'temp');
    expect(await File(path).exists(), isTrue);

    await alice.controller.send(PickedFile(path: path, name: 'ephemeral.txt'));

    expect(await File(path).exists(), isFalse);
  });
}
