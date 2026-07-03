import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late FakeBareWorklet worklet;
  late PearRpc rpc;
  late PearStore store;

  setUp(() async {
    worklet = FakeBareWorklet();
    rpc = PearRpc(worklet);
    await rpc.call(PearMethod.attachInfo);
    store = PearStore(rpc);
  });

  tearDown(() => rpc.dispose());

  test('get() by name opens a fresh core at length 0', () async {
    final core = await store.get(name: 'my-log');
    expect(core.length, 0);
  });

  test('get() by name is idempotent -- the same name always resolves to the '
      'same key', () async {
    final first = await store.get(name: 'my-log');
    final second = await store.get(name: 'my-log');
    expect(second.key, first.key);
  });

  test('append() grows length and returns the new length', () async {
    final core = await store.get(name: 'my-log');
    final length = await core.append([
      Uint8List.fromList(utf8.encode('one')),
      Uint8List.fromList(utf8.encode('two')),
    ]);
    expect(length, 2);
    expect(core.length, 2);
  });

  test('get(index) returns a previously appended block', () async {
    final core = await store.get(name: 'my-log');
    await core.append([Uint8List.fromList(utf8.encode('hello'))]);
    expect(utf8.decode(await core.get(0)), 'hello');
  });

  test('get(index) at or past length throws a typed PearStorageException '
      'with INDEX_OUT_OF_RANGE', () async {
    final core = await store.get(name: 'my-log');
    await core.append([Uint8List.fromList(utf8.encode('only one block'))]);

    await expectLater(
      core.get(1),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.indexOutOfRange)),
    );
  });

  test('updates fires the new length every time a block is appended',
      () async {
    final core = await store.get(name: 'my-log');
    final lengths = <int>[];
    core.updates.listen(lengths.add);

    await core.append([Uint8List.fromList(utf8.encode('a'))]);
    await core.append([Uint8List.fromList(utf8.encode('b'))]);
    await Future<void>.delayed(Duration.zero);

    expect(lengths, [1, 2]);
  });

  test('close() then append() throws with CORE_CLOSED', () async {
    final core = await store.get(name: 'my-log');
    await core.close();

    await expectLater(
      core.append([Uint8List.fromList(utf8.encode('too late'))]),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.coreClosed)),
    );
  });

  test('close() then get() throws with CORE_CLOSED', () async {
    final core = await store.get(name: 'my-log');
    await core.append([Uint8List.fromList(utf8.encode('block'))]);
    await core.close();

    await expectLater(
      core.get(0),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.coreClosed)),
    );
  });

  test('a core reopened after close() works again, not permanently locked '
      'out', () async {
    final first = await store.get(name: 'my-log');
    await first.append([Uint8List.fromList(utf8.encode('one'))]);
    await first.close();

    final reopened = await store.get(name: 'my-log');
    expect(reopened.key, first.key);
    expect(reopened.length, 1);

    // The critical regression this guards: a naive reopen implementation
    // can leave the key permanently marked closed, so this append must
    // succeed, not throw CORE_CLOSED forever.
    final length = await reopened.append(
        [Uint8List.fromList(utf8.encode('two'))]);
    expect(length, 2);
    expect(utf8.decode(await reopened.get(1)), 'two');
  });

  test('two different peers calling get(name:) with the same name never '
      'collide on the same key', () async {
    final hub = FakeSwarmHub();
    final rpcA = PearRpc(FakeBareWorklet(hub: hub));
    final rpcB = PearRpc(FakeBareWorklet(hub: hub));
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final coreA = await PearStore(rpcA).get(name: 'shared-log');
    final coreB = await PearStore(rpcB).get(name: 'shared-log');

    expect(coreA.key, isNot(coreB.key));

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test('append() on a core opened by key (not owned by this worklet) '
      'throws a typed PearStorageException -- only the creating peer can '
      'write', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final coreA = await PearStore(rpcA).get(name: 'owner-only-log');
    final coreB = await PearStore(rpcB).get(key: coreA.key);

    await expectLater(
      coreB.append([Uint8List.fromList(utf8.encode('not allowed'))]),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.storageUnavailable)),
    );

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test('replicate() called by only ONE side never syncs data -- both '
      'peers must call it, matching real Hypercore', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final coreA = await PearStore(rpcA).get(name: 'one-sided-log');
    await coreA.append([Uint8List.fromList(utf8.encode('data'))]);

    final topic = PearCrypto.topicFromString('store-one-sided-replicate');
    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    await firstConnB;

    final coreB = await PearStore(rpcB).get(key: coreA.key);

    // Only A calls replicate(); B never does.
    await coreA.replicate(connA);
    await Future<void>.delayed(Duration.zero);

    expect(coreB.length, 0);

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test('replicate() against a peer with no open connection throws a typed '
      'PearConnectionException with UNKNOWN_PEER', () async {
    final core = await store.get(name: 'my-log');
    final topic = PearCrypto.topicFromString('store-replicate-unknown-peer');
    final swarm = await PearSwarm.join(rpc, topic);

    // Fabricate a connection that was never actually established.
    final ghostRpc = PearRpc(FakeBareWorklet());
    final ghostSwarm = await PearSwarm.join(ghostRpc, topic);
    swarm.connections.listen((_) {}); // no-op; nothing will arrive
    final ghostKey = PearCrypto.hash(Uint8List.fromList(utf8.encode('ghost')));

    await expectLater(
      rpc.call(PearMethod.coreReplicate, {
        'key': core.key.hex,
        'peer': ghostKey.hex,
      }),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownPeer)),
    );

    await ghostSwarm.leave();
  });

  test(
      'two peers replicate a core -- B reads a block A appended before '
      'replicating, and sees updates for one appended after',
      () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final coreA = await PearStore(rpcA).get(name: 'shared-log');
    await coreA.append([Uint8List.fromList(utf8.encode('before'))]);

    final topic = PearCrypto.topicFromString('store-replicate-test');
    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    final connB = await firstConnB;

    // B opens the SAME core by A's public key, out of band -- before any
    // data has replicated in, it's a valid but empty local core, matching
    // real Corestore semantics (see PearStore.get's doc).
    final coreB = await PearStore(rpcB).get(key: coreA.key);
    expect(coreB.length, 0);

    final updates = <int>[];
    coreB.updates.listen(updates.add);

    await coreA.replicate(connA);
    await coreB.replicate(connB);
    await Future<void>.delayed(Duration.zero);

    expect(coreB.length, 1);
    expect(utf8.decode(await coreB.get(0)), 'before');

    await coreA.append([Uint8List.fromList(utf8.encode('after'))]);
    await Future<void>.delayed(Duration.zero);

    expect(coreB.length, 2);
    expect(utf8.decode(await coreB.get(1)), 'after');
    expect(updates, contains(2));

    await rpcA.dispose();
    await rpcB.dispose();
  });
}
