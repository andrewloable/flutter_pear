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

// PearBaseGetResult wraps a Uint8List in a record -- record `==` compares
// each field with plain `==`, and Uint8List's `==` is identity, not content
// (unlike expect()'s special-cased deep-equality handling for a BARE
// Uint8List/Iterable). Comparing the whole record directly would silently
// pass/fail on object identity instead of byte content, so every assertion
// below compares fields separately.
void _expectGet(PearBaseGetResult actual,
    {required bool exists, Uint8List? value}) {
  expect(actual.exists, exists);
  if (value == null) {
    expect(actual.value, isNull);
  } else {
    expect(actual.value, value);
  }
}

void main() {
  late FakeBareWorklet worklet;
  late PearRpc rpc;

  setUp(() async {
    worklet = FakeBareWorklet();
    rpc = PearRpc(worklet);
    await rpc.call(PearMethod.attachInfo);
  });

  tearDown(() => rpc.dispose());

  test('open() by name opens a fresh base, as the sole initial writer',
      () async {
    final base =
        await PearBase.open(rpc, recipe: PearRecipe.lww, name: 'my-base');
    _expectGet(await base.get(_b('missing')), exists: false, value: null);
  });

  test(
      'open() by name is idempotent -- the same name always resolves to '
      'the same key', () async {
    final first =
        await PearBase.open(rpc, recipe: PearRecipe.lww, name: 'my-base');
    final second =
        await PearBase.open(rpc, recipe: PearRecipe.lww, name: 'my-base');
    expect(second.key, first.key);
  });

  test('lww: put() then get() round-trips the value', () async {
    final base = await PearBase.open(rpc, recipe: PearRecipe.lww, name: 'lww');
    await base.put(_b('k1'), _b('v1'));
    _expectGet(await base.get(_b('k1')), exists: true, value: _b('v1'));
  });

  test('lww: del() removes a key; get() then reports not-exists', () async {
    final base = await PearBase.open(rpc, recipe: PearRecipe.lww, name: 'lww');
    await base.put(_b('k1'), _b('v1'));
    await base.del(_b('k1'));
    _expectGet(await base.get(_b('k1')), exists: false, value: null);
  });

  test('orderedLog: append() entries come back in order via range()', () async {
    final base =
        await PearBase.open(rpc, recipe: PearRecipe.orderedLog, name: 'log');
    await base.append(_b('e0'));
    await base.append(_b('e1'));
    await base.append(_b('e2'));
    expect(await base.range().toList(), [_b('e0'), _b('e1'), _b('e2')]);
  });

  test('orderedLog: range(start, end) reads a sub-range', () async {
    final base =
        await PearBase.open(rpc, recipe: PearRecipe.orderedLog, name: 'log');
    for (var i = 0; i < 5; i++) {
      await base.append(_b('e$i'));
    }
    expect(await base.range(start: 1, end: 3).toList(), [_b('e1'), _b('e2')]);
  });

  test('crdtMap: put() then get() round-trips the value', () async {
    final base =
        await PearBase.open(rpc, recipe: PearRecipe.crdtMap, name: 'crdt');
    await base.put(_b('k1'), _b('v1'));
    _expectGet(await base.get(_b('k1')), exists: true, value: _b('v1'));
  });

  test('crdtMap: del() removes a key; get() then reports not-exists', () async {
    final base =
        await PearBase.open(rpc, recipe: PearRecipe.crdtMap, name: 'crdt');
    await base.put(_b('k1'), _b('v1'));
    await base.del(_b('k1'));
    _expectGet(await base.get(_b('k1')), exists: false, value: null);
  });

  test('get() is rejected for orderedLog with a typed, non-crashing error',
      () async {
    final base =
        await PearBase.open(rpc, recipe: PearRecipe.orderedLog, name: 'log');
    await expectLater(
      base.get(_b('k')),
      throwsA(isA<PearStorageException>()),
    );
  });

  test('range() is rejected for lww with a typed, non-crashing error',
      () async {
    final base = await PearBase.open(rpc, recipe: PearRecipe.lww, name: 'lww');
    await expectLater(
      base.range().toList(),
      throwsA(isA<PearStorageException>()),
    );
  });

  test(
      'opening with an unrecognized recipe name throws a typed '
      'UNKNOWN_RECIPE error, not a crash', () async {
    // Bypasses the typed PearRecipe enum (which can't express an invalid
    // value) to exercise the worklet's own validation directly, matching
    // this ticket's VALIDATION requirement.
    await expectLater(
      rpc.call(
          PearMethod.baseOpen, {'recipe': 'not-a-real-recipe', 'name': 'x'}),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownRecipe)),
    );
  });

  test('close() then any further call fails with BASE_CLOSED', () async {
    final base = await PearBase.open(rpc, recipe: PearRecipe.lww, name: 'lww');
    await base.close();
    await expectLater(
      base.get(_b('k')),
      throwsA(isA<PearStorageException>()
          .having((e) => e.code, 'code', PearErrorCode.baseClosed)),
    );
  });

  group('two writers', () {
    late FakeSwarmHub hub;
    late PearRpc rpcA;
    late PearRpc rpcB;

    setUp(() async {
      hub = FakeSwarmHub();
      rpcA = PearRpc(FakeBareWorklet(hub: hub));
      rpcB = PearRpc(FakeBareWorklet(hub: hub));
      await rpcA.call(PearMethod.attachInfo);
      await rpcB.call(PearMethod.attachInfo);
    });

    tearDown(() async {
      await rpcA.dispose();
      await rpcB.dispose();
    });

    /// Connects A and B over a shared topic, opens [key] on B, admits B as
    /// a writer via A's [PearBase.addWriter], and replicates both ways --
    /// the full setup every "two writers converge" scenario below needs.
    Future<PearBase> admitAndReplicate(PearBase baseA) async {
      final topic =
          PearCrypto.unsafeTopicFromString('base-test-${baseA.key.hex}');
      final swarmA = await PearSwarm.join(rpcA, topic);
      final firstConnA = swarmA.connections.first;
      final swarmB = await PearSwarm.join(rpcB, topic);
      final firstConnB = swarmB.connections.first;
      final connA = await firstConnA;
      final connB = await firstConnB;

      final baseB =
          await PearBase.open(rpcB, recipe: baseA.recipe, key: baseA.key);
      await baseA.addWriter(baseB.writerKey);

      await baseA.replicate(connA);
      await baseB.replicate(connB);
      await Future<void>.delayed(Duration.zero);
      return baseB;
    }

    test('lww: two writers converge to the identical merged view', () async {
      final baseA =
          await PearBase.open(rpcA, recipe: PearRecipe.lww, name: 'shared-lww');
      await baseA.put(_b('before'), _b('from-a'));
      final baseB = await admitAndReplicate(baseA);

      _expectGet(await baseB.get(_b('before')),
          exists: true, value: _b('from-a'));

      await baseB.put(_b('after'), _b('from-b'));
      await Future<void>.delayed(Duration.zero);

      _expectGet(await baseA.get(_b('after')),
          exists: true, value: _b('from-b'));
      _expectGet(await baseB.get(_b('after')),
          exists: true, value: _b('from-b'));
    });

    test('lww: watch() fires when the peer\'s write replicates in', () async {
      final baseA =
          await PearBase.open(rpcA, recipe: PearRecipe.lww, name: 'shared-lww');
      final baseB = await admitAndReplicate(baseA);

      var ticks = 0;
      final sub = baseB.watch().listen((_) => ticks++);
      await Future<void>.delayed(Duration.zero);

      await baseA.put(_b('k'), _b('v'));
      await Future<void>.delayed(Duration.zero);

      _expectGet(await baseB.get(_b('k')), exists: true, value: _b('v'));
      expect(ticks, greaterThan(0));
      await sub.cancel();
    });

    test(
        'orderedLog: two writers interleaving entries converge to the '
        'identical merged content on both sides', () async {
      final baseA = await PearBase.open(rpcA,
          recipe: PearRecipe.orderedLog, name: 'shared-log');
      await baseA.append(_b('a0'));
      final baseB = await admitAndReplicate(baseA);

      await baseB.append(_b('b0'));
      await Future<void>.delayed(Duration.zero);

      final entriesA = (await baseA.range().toList()).map(utf8.decode).toSet();
      final entriesB = (await baseB.range().toList()).map(utf8.decode).toSet();
      expect(entriesA, entriesB);
      expect(entriesA, {'a0', 'b0'});
    });

    test(
        'crdtMap: a concurrent, not-yet-observed put survives a delete '
        '(add wins)', () async {
      final baseA = await PearBase.open(rpcA,
          recipe: PearRecipe.crdtMap, name: 'shared-crdt');
      await baseA.put(_b('x'), _b('from-a'));
      final baseB = await admitAndReplicate(baseA);
      _expectGet(await baseB.get(_b('x')), exists: true, value: _b('from-a'));

      // Concurrently: A deletes what it observed, B adds a value A hasn't
      // seen yet -- neither side replicates in between.
      await baseA.del(_b('x'));
      await baseB.put(_b('x'), _b('from-b'));
      await Future<void>.delayed(Duration.zero);

      _expectGet(await baseA.get(_b('x')), exists: true, value: _b('from-b'));
      _expectGet(await baseB.get(_b('x')), exists: true, value: _b('from-b'));
    });

    test('removeWriter: a removed writer can no longer append', () async {
      final baseA =
          await PearBase.open(rpcA, recipe: PearRecipe.lww, name: 'shared-lww');
      final baseB = await admitAndReplicate(baseA);

      await baseA.removeWriter(baseB.writerKey);
      await expectLater(
        baseB.put(_b('k'), _b('v')),
        throwsA(isA<PearStorageException>()),
      );
    });
  });
}
