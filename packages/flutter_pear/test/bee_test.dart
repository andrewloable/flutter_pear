import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_pear/flutter_pear.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/rpc.dart';
// ignore: implementation_imports
import 'package:flutter_pear/src/schema.dart';
import 'package:flutter_pear_test/flutter_pear_test.dart';
import 'package:flutter_test/flutter_test.dart';

Uint8List _b(String s) => Uint8List.fromList(utf8.encode(s));

void main() {
  late FakeBareWorklet worklet;
  late PearRpc rpc;

  setUp(() async {
    worklet = FakeBareWorklet();
    rpc = PearRpc(worklet);
    await rpc.call(PearMethod.attachInfo);
  });

  tearDown(() => rpc.dispose());

  test('open() by name opens a fresh bee', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    expect(await bee.get(_b('missing')), isNull);
  });

  test('open() by name is idempotent -- the same name always resolves to '
      'the same key', () async {
    final first = await PearBee.open(rpc, name: 'my-bee');
    final second = await PearBee.open(rpc, name: 'my-bee');
    expect(second.key, first.key);
  });

  test('put() then get() round-trips the value', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    await bee.put(_b('k1'), _b('v1'));
    expect(await bee.get(_b('k1')), _b('v1'));
  });

  test('put() overwrites an existing value', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    await bee.put(_b('k1'), _b('v1'));
    await bee.put(_b('k1'), _b('v2'));
    expect(await bee.get(_b('k1')), _b('v2'));
  });

  test('del() removes a key; get() then returns null', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    await bee.put(_b('k1'), _b('v1'));
    await bee.del(_b('k1'));
    expect(await bee.get(_b('k1')), isNull);
  });

  test('del() on an absent key is a no-op, not an error', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    await bee.del(_b('never-existed')); // must not throw
  });

  test('range() reads every entry in ascending key order', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    for (final k in ['c', 'a', 'b', 'e', 'd']) {
      await bee.put(_b(k), _b('v-$k'));
    }

    final entries = await bee.range().toList();
    expect(entries.map((e) => utf8.decode(e.key)), ['a', 'b', 'c', 'd', 'e']);
    expect(entries.map((e) => utf8.decode(e.value)),
        ['v-a', 'v-b', 'v-c', 'v-d', 'v-e']);
  });

  test('range() honors gte/lt bounds', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    for (final k in ['a', 'b', 'c', 'd', 'e']) {
      await bee.put(_b(k), _b(k));
    }

    final entries = await bee.range(gte: _b('b'), lt: _b('e')).toList();
    expect(entries.map((e) => utf8.decode(e.key)), ['b', 'c', 'd']);
  });

  test('range() honors reverse and limit', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    for (final k in ['a', 'b', 'c', 'd', 'e']) {
      await bee.put(_b(k), _b(k));
    }

    final entries = await bee.range(reverse: true, limit: 2).toList();
    expect(entries.map((e) => utf8.decode(e.key)), ['e', 'd']);
  });

  test('watch() fires when a put() changes the bee', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    var ticks = 0;
    final sub = bee.watch().listen((_) => ticks++);
    await Future<void>.delayed(Duration.zero); // let onListen's subscribe land

    await bee.put(_b('k1'), _b('v1'));
    await Future<void>.delayed(Duration.zero);

    expect(ticks, 1);
    await sub.cancel();
  });

  test('canceling watch() unsubscribes worklet-side -- the JS-side listener '
      'count drops back to zero', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    final sub = bee.watch().listen((_) {});
    await Future<void>.delayed(Duration.zero);

    expect(worklet.activeBeeWatchCount(bee.key.hex), 1);
    await sub.cancel();
    await Future<void>.delayed(Duration.zero);

    expect(worklet.activeBeeWatchCount(bee.key.hex), 0);
  });

  test('canceling and immediately re-listening on the same watch() Stream '
      'keeps the fresh subscription alive -- the stale cancel must not '
      'kill it', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    final stream = bee.watch();
    final sub1 = stream.listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(worklet.activeBeeWatchCount(bee.key.hex), 1);

    // Cancel then immediately re-listen on the SAME Stream, back to back,
    // with no await in between -- reproduces the exact ordering a
    // rebuilt widget/StreamBuilder would produce. onCancel's own
    // beeUnwatch call is not awaited by subscription.cancel() (a broadcast
    // StreamController's onCancel runs detached), so it can still be in
    // flight when the fresh onListen below fires.
    unawaited(sub1.cancel());
    var ticks = 0;
    final sub2 = stream.listen((_) => ticks++);
    await Future<void>.delayed(Duration.zero);

    // Exactly one live watch should survive -- not zero (killed by the
    // stale unwatch) and not two (the old one leaked).
    expect(worklet.activeBeeWatchCount(bee.key.hex), 1);

    await bee.put(_b('k1'), _b('v1'));
    await Future<void>.delayed(Duration.zero);
    expect(ticks, 1);

    await sub2.cancel();
  });

  test('get() on a closed bee throws a typed PearStorageException with '
      'BEE_CLOSED', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    await bee.close();

    await expectLater(
      bee.get(_b('k1')),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.beeClosed)),
    );
  });

  test('put() on a closed bee throws BEE_CLOSED', () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    await bee.close();

    await expectLater(
      bee.put(_b('k1'), _b('v1')),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.beeClosed)),
    );
  });

  test('closing a bee stops an outstanding watch, not just future calls',
      () async {
    final bee = await PearBee.open(rpc, name: 'my-bee');
    bee.watch().listen((_) {});
    await Future<void>.delayed(Duration.zero);
    expect(worklet.activeBeeWatchCount(bee.key.hex), 1);

    await bee.close();

    expect(worklet.activeBeeWatchCount(bee.key.hex), 0);
  });

  test('unwatch naming the wrong bee for a real watchId throws UNKNOWN_BEE '
      'instead of silently closing the other bee\'s watch', () async {
    final beeA = await PearBee.open(rpc, name: 'bee-a');
    final beeB = await PearBee.open(rpc, name: 'bee-b');

    // Drives the raw RPC methods directly (bypassing PearBee.watch(),
    // which always sends a matching bee/watch pair) to construct a
    // mismatched pair the way a wire-level bug could produce one.
    const watchId = 'test-watch-id';
    await rpc.call(PearMethod.beeWatch, {'bee': beeA.key.hex, 'watch': watchId});
    expect(worklet.activeBeeWatchCount(beeA.key.hex), 1);

    await expectLater(
      rpc.call(PearMethod.beeUnwatch, {'bee': beeB.key.hex, 'watch': watchId}),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownBee)),
    );
    // The mismatched call must not have torn down beeA's own watch.
    expect(worklet.activeBeeWatchCount(beeA.key.hex), 1);
  });

  test('a bee reopened after close() works again, not permanently locked '
      'out', () async {
    final first = await PearBee.open(rpc, name: 'my-bee');
    await first.put(_b('k1'), _b('v1'));
    await first.close();

    final reopened = await PearBee.open(rpc, name: 'my-bee');
    expect(reopened.key, first.key);
    expect(await reopened.get(_b('k1')), _b('v1'));

    await reopened.put(_b('k2'), _b('v2'));
    expect(await reopened.get(_b('k2')), _b('v2'));
  });

  test('two different peers calling open(name:) with the same name never '
      'collide on the same key', () async {
    final hub = FakeSwarmHub();
    final rpcA = PearRpc(FakeBareWorklet(hub: hub));
    final rpcB = PearRpc(FakeBareWorklet(hub: hub));
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final beeA = await PearBee.open(rpcA, name: 'shared-bee');
    final beeB = await PearBee.open(rpcB, name: 'shared-bee');

    expect(beeA.key, isNot(beeB.key));

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test('put() on a bee opened by key (not owned by this worklet) throws a '
      'typed PearStorageException -- only the creating peer can write',
      () async {
    final hub = FakeSwarmHub();
    final rpcA = PearRpc(FakeBareWorklet(hub: hub));
    final rpcB = PearRpc(FakeBareWorklet(hub: hub));
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final beeA = await PearBee.open(rpcA, name: 'owner-only-bee');
    final beeB = await PearBee.open(rpcB, key: beeA.key);

    await expectLater(
      beeB.put(_b('k1'), _b('not allowed')),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.storageUnavailable)),
    );

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test('replicate() called by only ONE side never syncs data -- both peers '
      'must call it', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final beeA = await PearBee.open(rpcA, name: 'one-sided-bee');
    await beeA.put(_b('k1'), _b('v1'));

    final topic = PearCrypto.topicFromString('bee-one-sided-replicate');
    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    await firstConnB;

    final beeB = await PearBee.open(rpcB, key: beeA.key);
    await beeA.replicate(connA); // only A calls replicate; B never does

    await Future<void>.delayed(Duration.zero);
    expect(await beeB.get(_b('k1')), isNull);

    await rpcA.dispose();
    await rpcB.dispose();
  });

  test('two peers replicate a bee -- B reads a value A put before '
      'replicating, and its watch fires for one put after', () async {
    final hub = FakeSwarmHub();
    final workletA = FakeBareWorklet(hub: hub);
    final workletB = FakeBareWorklet(hub: hub);
    final rpcA = PearRpc(workletA);
    final rpcB = PearRpc(workletB);
    await rpcA.call(PearMethod.attachInfo);
    await rpcB.call(PearMethod.attachInfo);

    final beeA = await PearBee.open(rpcA, name: 'shared-bee');
    await beeA.put(_b('k1'), _b('before'));

    final topic = PearCrypto.topicFromString('bee-replicate-test');
    final swarmA = await PearSwarm.join(rpcA, topic);
    final firstConnA = swarmA.connections.first;
    final swarmB = await PearSwarm.join(rpcB, topic);
    final firstConnB = swarmB.connections.first;
    final connA = await firstConnA;
    final connB = await firstConnB;

    final beeB = await PearBee.open(rpcB, key: beeA.key);
    var ticks = 0;
    final sub = beeB.watch().listen((_) => ticks++);
    await Future<void>.delayed(Duration.zero);

    await beeA.replicate(connA);
    await beeB.replicate(connB);
    await Future<void>.delayed(Duration.zero);

    expect(await beeB.get(_b('k1')), _b('before'));

    await beeA.put(_b('k2'), _b('after'));
    await Future<void>.delayed(Duration.zero);

    expect(await beeB.get(_b('k2')), _b('after'));
    expect(ticks, greaterThan(0));

    // B's watch was created before the merge and migrated onto the
    // canonical (A's) bee object during it -- canceling it now must still
    // find and remove it from wherever it actually lives post-merge, not
    // leak it on the orphaned pre-merge object (E5.3 review fix).
    await sub.cancel();
    await Future<void>.delayed(Duration.zero);
    expect(workletB.activeBeeWatchCount(beeB.key.hex), 0);

    await rpcA.dispose();
    await rpcB.dispose();
  });
}
