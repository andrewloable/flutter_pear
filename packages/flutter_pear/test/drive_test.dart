import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
import 'package:flutter_pear_bare/flutter_pear_bare.dart';
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
    expect(result.rejected, 0);
    await mirrorDir.delete(recursive: true);
  });

  test(
      'mirrorToDisk() rejects a hostile symlink entry -- reported in '
      'rejected, never written to disk, and surfaced on mirrorWarnings '
      '(flutter_pear-ovt.2.7/2.8 zip-slip hardening)', () async {
    final drive = await PearDrive.open(rpc, name: 'hostile-drive');
    await drive.put('/legit.txt', await writeLocalFile('legit.txt', 'ok'));
    worklet.injectDriveSymlink(drive.key.hex, '/x', '../../../etc/passwd');

    final warnings = <PearDriveMirrorWarning>[];
    final sub = drive.mirrorWarnings.listen(warnings.add);

    final mirrorDir =
        await Directory.systemTemp.createTemp('flutter_pear-mirror-hostile-');
    final result = await drive.mirrorToDisk(mirrorDir.path);
    // mirrorWarnings is a broadcast stream fed by the same event pipe as
    // every other Pear event -- give its listener a turn before asserting.
    await Future<void>.delayed(Duration.zero);

    expect(result.rejected, 1);
    expect(result.added, 1); // /legit.txt still mirrors normally
    expect(await File('${mirrorDir.path}/legit.txt').readAsString(), 'ok');
    expect(await File('${mirrorDir.path}/x').exists(), isFalse,
        reason: 'the rejected symlink must never be written to disk');

    expect(warnings, hasLength(1));
    expect(warnings.single.path, '/x');
    expect(warnings.single.reason, 'symlink-rejected');

    await sub.cancel();
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

  test(
      'replicating a drive with ZERO files on both sides still leaves the '
      "writer able to put() afterward (flutter_pear-test's fake fix, "
      'discovered by flutter_pear-ovt.4.5)', () async {
    // A real app can legitimately replicate its own drive the instant a
    // peer connects, well before it has put anything -- both sides'
    // in-memory drive views then start at 0 files each, a TIE the fake's
    // replicate-merge previously broke by file count alone
    // (mine.files.length >= theirs.files.length ? mine : theirs), which
    // could silently pick the NON-writer's drive object as canonical and
    // permanently strip the real writer's put access. The fix prefers
    // whichever side actually holds a non-null writer.
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final driveA = await PearDrive.open(rpcA, name: 'zero-file-tie-drive');

    final topic = PearCrypto.unsafeTopicFromString('drive-zero-file-tie');
    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    final connB = await firstConnB;

    final driveB = await PearDrive.open(rpcB, key: driveA.key);

    // Both sides replicate before EITHER has put anything -- 0 files each.
    await driveA.replicate(connA);
    await driveB.replicate(connB);
    await Future<void>.delayed(Duration.zero);

    // The rightful writer (A) must still be able to put -- this is exactly
    // what threw PearStorageException(STORAGE_UNAVAILABLE) before the fix.
    await driveA.put('/after-tie.txt', await writeLocalFile('d.txt', 'ok'));
    await Future<void>.delayed(Duration.zero);
    expect(await driveB.exists('/after-tie.txt'), isTrue);

    await rpcA.dispose();
    await rpcB.dispose();
  });

  group('transfers with no fixed deadline (KinNode gap G15)', () {
    test('G15-1 a get whose reply takes 11 s still succeeds (the old 10 s RPC timeout is gone)',
        () async {
      final slow = _ReplyRewriter(FakeBareWorklet(), 'drive.get',
          delay: const Duration(seconds: 11));
      final slowRpc = PearRpc(slow);
      await slowRpc.call(PearMethod.attachInfo);
      final drive = await PearDrive.open(slowRpc, name: 'slow');
      await drive.put('/a.txt', await writeLocalFile('a.txt', 'hello'));
      final dst = '${tempDir.path}/a-out.txt';
      expect(await drive.get('/a.txt', dst), dst);
      expect(await File(dst).readAsString(), 'hello');
      await slowRpc.dispose();
    }, timeout: const Timeout(Duration(seconds: 30)));

    test('maxDuration is the RPC timeout', () async {
      final slow = _ReplyRewriter(FakeBareWorklet(), 'drive.get',
          delay: const Duration(milliseconds: 1500));
      final slowRpc = PearRpc(slow);
      await slowRpc.call(PearMethod.attachInfo);
      final drive = await PearDrive.open(slowRpc, name: 'cap');
      await drive.put('/a.txt', await writeLocalFile('b.txt', 'x'));
      await expectLater(
        drive.get('/a.txt', '${tempDir.path}/b-out.txt',
            idleTimeout: const Duration(milliseconds: 200),
            maxDuration: const Duration(seconds: 1)),
        throwsA(isA<PearException>()
            .having((e) => e.code, 'code', PearErrorCode.rpcTimeout)),
      );
      await slowRpc.dispose();
    });

    test('idleTimeout is sent to the worklet as idleMs', () async {
      final spy = _ReplyRewriter(FakeBareWorklet(), 'drive.get');
      final spyRpc = PearRpc(spy);
      await spyRpc.call(PearMethod.attachInfo);
      final drive = await PearDrive.open(spyRpc, name: 'spy');
      await drive.put('/a.txt', await writeLocalFile('c.txt', 'x'));
      await drive.get('/a.txt', '${tempDir.path}/c-out.txt',
          idleTimeout: const Duration(seconds: 5));
      expect(spy.lastParams?['idleMs'], 5000);
      expect(spy.lastParams?.containsKey('transfer'), isFalse,
          reason: 'no transfer id without onProgress');
      await spyRpc.dispose();
    });

    test('G15-2 a stall reported by the worklet surfaces as transferStalled', () async {
      final stall = _ReplyRewriter(FakeBareWorklet(), 'drive.get',
          errorCode: PearErrorCode.transferStalled);
      final stallRpc = PearRpc(stall);
      await stallRpc.call(PearMethod.attachInfo);
      final drive = await PearDrive.open(stallRpc, name: 'stall');
      await drive.put('/a.txt', await writeLocalFile('d.txt', 'x'));
      await expectLater(
        drive.get('/a.txt', '${tempDir.path}/d-out.txt'),
        throwsA(isA<PearException>()
            .having((e) => e.code, 'code', PearErrorCode.transferStalled)),
      );
      await stallRpc.dispose();
    });

    test('progress reaches only its own call, ending at bytes == total', () async {
      final drive = await PearDrive.open(rpc, name: 'progress');
      await drive.put('/one.txt', await writeLocalFile('one.txt', '12345'));
      await drive.put('/two.txt', await writeLocalFile('two.txt', '1234567890'));
      final one = <(int, int?)>[];
      final two = <(int, int?)>[];
      await Future.wait([
        drive.get('/one.txt', '${tempDir.path}/one-out.txt',
            onProgress: (b, t) => one.add((b, t))),
        drive.get('/two.txt', '${tempDir.path}/two-out.txt',
            onProgress: (b, t) => two.add((b, t))),
      ]);
      expect(one, [(5, 5)]);
      expect(two, [(10, 10)]);
      // Nothing more is delivered after the call completed.
      await drive.get('/one.txt', '${tempDir.path}/one-again.txt');
      expect(one, [(5, 5)]);
    });

    test('put reports progress too', () async {
      final drive = await PearDrive.open(rpc, name: 'put-progress');
      final seen = <(int, int?)>[];
      await drive.put('/p.txt', await writeLocalFile('p.txt', 'abcdef'),
          onProgress: (b, t) => seen.add((b, t)));
      expect(seen, [(6, 6)]);
    });
  });
}

/// Wraps a worklet and, for requests of [method], records their params and
/// either delays the reply by [delay] or replaces it with an error [errorCode].
class _ReplyRewriter implements WorkletIpc {
  _ReplyRewriter(this._inner, this.method, {this.delay, this.errorCode});

  final WorkletIpc _inner;
  final String method;
  final Duration? delay;
  final String? errorCode;
  final _ids = <int>{};
  Map<String, Object?>? lastParams;

  @override
  Stream<WorkletCrash> get onCrash => _inner.onCrash;

  @override
  Future<void> send(Uint8List frame) {
    if (frame.isNotEmpty && frame[0] == PearFrameType.json) {
      final msg = jsonDecode(utf8.decode(frame.sublist(1)));
      if (msg is Map && msg['m'] == method) {
        _ids.add(msg['id'] as int);
        lastParams = Map<String, Object?>.from(msg['p'] as Map);
      }
    }
    return _inner.send(frame);
  }

  @override
  Stream<Uint8List> get incoming => _inner.incoming.asyncMap((frame) async {
        if (frame.isEmpty || frame[0] != PearFrameType.json) return frame;
        final msg = jsonDecode(utf8.decode(frame.sublist(1)));
        if (msg is! Map || !_ids.contains(msg['id'])) return frame;
        if (delay != null) await Future<void>.delayed(delay!);
        if (errorCode == null) return frame;
        final rewritten = Map<String, Object?>.from(msg)
          ..remove('ok')
          ..['err'] = {'code': errorCode, 'message': 'rewritten by test'};
        final body = utf8.encode(jsonEncode(rewritten));
        return Uint8List(body.length + 1)
          ..[0] = PearFrameType.json
          ..setRange(1, body.length + 1, body);
      });
}
