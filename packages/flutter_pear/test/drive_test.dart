import 'dart:io';

import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory tempDir;
  late FakeBareWorklet worklet;
  late PearRpc rpc;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('flutter_pear-drive-test-');
    worklet = FakeBareWorklet();
    rpc = PearRpc(worklet);
    await rpc.call(PearMethod.attachInfo);
  });

  tearDown(() async {
    await rpc.dispose();
    await tempDir.delete(recursive: true);
  });

  /// Writes [content] to a fresh file under [tempDir] and returns its path.
  Future<String> writeLocalFile(String name, String content) async {
    final file = File('${tempDir.path}/$name');
    await file.writeAsString(content);
    return file.path;
  }

  test('open() by name opens a fresh drive', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    expect(await drive.exists('/whatever.txt'), isFalse);
  });

  test(
      'open() by name is idempotent -- the same name always resolves to '
      'the same key', () async {
    final first = await PearDrive.open(rpc, name: 'my-drive');
    final second = await PearDrive.open(rpc, name: 'my-drive');
    expect(second.key, first.key);
  });

  test('put() then get() round-trips the file content', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    final source = await writeLocalFile('source.txt', 'hello drive');

    await drive.put('/greeting.txt', source);

    final destination = '${tempDir.path}/downloaded.txt';
    final resultPath = await drive.get('/greeting.txt', destination);
    expect(resultPath, destination);
    expect(await File(destination).readAsString(), 'hello drive');
  });

  test('put() overwrites existing content at the same virtual path', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    await drive.put('/f.txt', await writeLocalFile('a.txt', 'first'));
    await drive.put('/f.txt', await writeLocalFile('b.txt', 'second'));

    final destination = '${tempDir.path}/out.txt';
    await drive.get('/f.txt', destination);
    expect(await File(destination).readAsString(), 'second');
  });

  test('exists() reflects put()/delete()', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    expect(await drive.exists('/f.txt'), isFalse);

    await drive.put('/f.txt', await writeLocalFile('a.txt', 'data'));
    expect(await drive.exists('/f.txt'), isTrue);

    await drive.delete('/f.txt');
    expect(await drive.exists('/f.txt'), isFalse);
  });

  test('delete() on an absent path is a no-op, not an error', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    await drive.delete('/never-existed.txt'); // must not throw
  });

  test('list() returns every virtual path, sorted', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    for (final name in ['/c.txt', '/a.txt', '/b.txt']) {
      await drive.put(name, await writeLocalFile('src.txt', name));
    }

    final paths = await drive.list().toList();
    expect(paths, ['/a.txt', '/b.txt', '/c.txt']);
  });

  test('list() scopes to the given folder', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    await drive.put('/docs/a.txt', await writeLocalFile('src.txt', 'a'));
    await drive.put('/docs/b.txt', await writeLocalFile('src.txt', 'b'));
    await drive.put('/other.txt', await writeLocalFile('src.txt', 'x'));

    final paths = await drive.list(folder: '/docs').toList();
    expect(paths, ['/docs/a.txt', '/docs/b.txt']);
  });

  test(
      'get() on a missing path throws a typed PearStorageException with '
      'FILE_NOT_FOUND', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');

    await expectLater(
      drive.get('/nope.txt', '${tempDir.path}/out.txt'),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.fileNotFound)),
    );
  });

  test(
      'operations on a closed drive throw a typed PearStorageException with '
      'DRIVE_CLOSED', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    await drive.close();

    await expectLater(
      drive.put('/f.txt', await writeLocalFile('a.txt', 'data')),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.driveClosed)),
    );
  });

  test('mirrorToDisk() writes every file to the local directory', () async {
    final drive = await PearDrive.open(rpc, name: 'my-drive');
    await drive.put('/a.txt', await writeLocalFile('a.txt', 'A'));
    await drive.put('/b.txt', await writeLocalFile('b.txt', 'B'));

    final mirrorDir =
        await Directory.systemTemp.createTemp('flutter_pear-mirror-');
    final result = await drive.mirrorToDisk(mirrorDir.path);

    expect(result.added, 2);
    expect(await File('${mirrorDir.path}/a.txt').readAsString(), 'A');
    expect(await File('${mirrorDir.path}/b.txt').readAsString(), 'B');
    await mirrorDir.delete(recursive: true);
  });

  test(
      'a drive reopened after close() works again, not permanently locked '
      'out', () async {
    final first = await PearDrive.open(rpc, name: 'my-drive');
    await first.put('/f.txt', await writeLocalFile('a.txt', 'data'));
    await first.close();

    final reopened = await PearDrive.open(rpc, name: 'my-drive');
    expect(reopened.key, first.key);
    expect(await reopened.exists('/f.txt'), isTrue);

    await reopened.put('/g.txt', await writeLocalFile('b.txt', 'more data'));
    expect(await reopened.exists('/g.txt'), isTrue);
  });

  test(
      'two different peers calling open(name:) with the same name never '
      'collide on the same key', () async {
    final hub = FakeSwarmHub();
    final rpcA = PearRpc(FakeBareWorklet(hub: hub));
    final rpcB = PearRpc(FakeBareWorklet(hub: hub));
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final driveA = await PearDrive.open(rpcA, name: 'shared-drive');
    final driveB = await PearDrive.open(rpcB, name: 'shared-drive');

    expect(driveA.key, isNot(driveB.key));

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test(
      'put() on a drive opened by key (not owned by this worklet) throws '
      'a typed PearStorageException -- only the creating peer can write',
      () async {
    final hub = FakeSwarmHub();
    final rpcA = PearRpc(FakeBareWorklet(hub: hub));
    final rpcB = PearRpc(FakeBareWorklet(hub: hub));
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final driveA = await PearDrive.open(rpcA, name: 'owner-only-drive');
    final driveB = await PearDrive.open(rpcB, key: driveA.key);

    await expectLater(
      driveB.put('/f.txt', await writeLocalFile('a.txt', 'not allowed')),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.storageUnavailable)),
    );

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test(
      'replicate() called by only ONE side never syncs data -- both peers '
      'must call it', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final driveA = await PearDrive.open(rpcA, name: 'one-sided-drive');
    await driveA.put('/f.txt', await writeLocalFile('a.txt', 'data'));

    final topic = PearCrypto.unsafeTopicFromString('drive-one-sided-replicate');
    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    await firstConnB;

    final driveB = await PearDrive.open(rpcB, key: driveA.key);
    await driveA.replicate(connA); // only A calls replicate; B never does

    await Future<void>.delayed(Duration.zero);
    expect(await driveB.exists('/f.txt'), isFalse);

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test(
      'two peers replicate a drive -- B gets a file A put before '
      'replicating', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final driveA = await PearDrive.open(rpcA, name: 'shared-drive');
    await driveA.put('/before.txt', await writeLocalFile('a.txt', 'before'));

    final topic = PearCrypto.unsafeTopicFromString('drive-replicate-test');
    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    final connB = await firstConnB;

    final driveB = await PearDrive.open(rpcB, key: driveA.key);
    expect(await driveB.exists('/before.txt'), isFalse);

    await driveA.replicate(connA);
    await driveB.replicate(connB);
    await Future<void>.delayed(Duration.zero);

    expect(await driveB.exists('/before.txt'), isTrue);
    final destination = '${tempDir.path}/from-b.txt';
    await driveB.get('/before.txt', destination);
    expect(await File(destination).readAsString(), 'before');

    await driveA.put('/after.txt', await writeLocalFile('c.txt', 'after'));
    await Future<void>.delayed(Duration.zero);
    expect(await driveB.exists('/after.txt'), isTrue);

    await rpcA.dispose();
    await rpcB.dispose();
  });
}
