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
  late FakeSwarmHub hub;
  late PearRpc rpcA; // the inviter
  late PearRpc rpcB; // the accepting side

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

  test(
      'create/accept round trip yields linked peers -- B gets the key A '
      'confirms with', () async {
    final invite = await PearPairing.createInvite(rpcA);
    final sharedKey = PearCrypto.unsafeTopicFromString('shared-topic-key');

    invite.candidates.listen((candidate) => candidate.confirm(sharedKey));

    final result = await PearPairing.acceptInvite(rpcB, invite.invite);
    expect(result, sharedKey);
  });

  test('the candidate userData is visible to the inviter', () async {
    final invite = await PearPairing.createInvite(rpcA);
    final sharedKey = PearCrypto.unsafeTopicFromString('shared-topic-key');

    // Kicked off before awaiting the candidates stream below -- it won't
    // resolve until the inviter confirms further down.
    final accepted =
        PearPairing.acceptInvite(rpcB, invite.invite, userData: _b('phone-b'));

    final candidate = await invite.candidates.first;
    expect(utf8.decode(candidate.userData), 'phone-b');
    await candidate.confirm(sharedKey);

    expect(await accepted, sharedKey);
  });

  test(
      'garbage invite bytes throw a typed PearConnectionException with '
      'INVALID_INVITE, not a hang', () async {
    await expectLater(
      PearPairing.acceptInvite(rpcB, _b('not a real invite')),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.invalidInvite)),
    );
  });

  test(
      'an invite past its ttl throws a typed PearConnectionException with '
      'INVITE_EXPIRED', () async {
    final invite = await PearPairing.createInvite(rpcA,
        ttl: const Duration(milliseconds: 1));
    await Future<void>.delayed(const Duration(milliseconds: 20));

    await expectLater(
      PearPairing.acceptInvite(rpcB, invite.invite),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.inviteExpired)),
    );
  });

  test(
      'revoke blocks accept -- a revoked invite times out rather than '
      'hanging or succeeding', () async {
    final invite = await PearPairing.createInvite(rpcA);
    await invite.revoke();

    await expectLater(
      PearPairing.acceptInvite(rpcB, invite.invite,
          timeout: const Duration(milliseconds: 50)),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.pairingTimeout)),
    );
  });

  test('accept never confirmed times out rather than hanging forever',
      () async {
    final invite = await PearPairing.createInvite(rpcA);
    // Nobody ever listens to invite.candidates / calls confirm().

    await expectLater(
      PearPairing.acceptInvite(rpcB, invite.invite,
          timeout: const Duration(milliseconds: 50)),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.pairingTimeout)),
    );
  });

  test(
      'confirming an unknown candidate id on a real invite throws '
      'UNKNOWN_CANDIDATE', () async {
    final invite = await PearPairing.createInvite(rpcA);

    await expectLater(
      rpcA.call(PearMethod.pairingConfirmCandidate, {
        'inviteId': invite.id,
        'candidateId': 'does-not-exist',
        'key': base64Encode(PearCrypto.unsafeTopicFromString('x').bytes),
      }),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownCandidate)),
    );
  });

  test('confirming on an unknown invite id throws UNKNOWN_INVITE', () async {
    await expectLater(
      rpcA.call(PearMethod.pairingConfirmCandidate, {
        'inviteId': 'never-created',
        'candidateId': 'does-not-exist',
        'key': base64Encode(PearCrypto.unsafeTopicFromString('x').bytes),
      }),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownInvite)),
    );
  });

  test(
      'confirming a candidate after the invite was revoked throws '
      'UNKNOWN_INVITE instead of stale success', () async {
    final invite = await PearPairing.createInvite(rpcA);
    final acceptFuture = PearPairing.acceptInvite(rpcB, invite.invite,
        timeout: const Duration(milliseconds: 50));
    final candidate = await invite.candidates.first;
    await invite.revoke();

    await expectLater(
      candidate.confirm(PearCrypto.unsafeTopicFromString('shared-topic-key')),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownInvite)),
    );

    // The candidate was already pending before the revoke -- it still
    // times out via its own bound rather than hanging or succeeding, same
    // as the plain revoke-blocks-accept case above.
    await expectLater(
      acceptFuture,
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.pairingTimeout)),
    );
  });

  test(
      'a different worklet cannot confirm someone else\'s candidate -- '
      'no shared-hub privacy leak', () async {
    final invite = await PearPairing.createInvite(rpcA);
    final acceptFuture = PearPairing.acceptInvite(rpcB, invite.invite,
        timeout: const Duration(milliseconds: 50));

    final event = await rpcA.events
        .firstWhere((e) => e.name == PearEventName.pairingCandidate);
    final candidateId = (event.payload as Map)['candidateId'] as String;

    final rpcC = PearRpc(FakeBareWorklet(hub: hub));
    await rpcC.call(PearMethod.attachInfo);

    await expectLater(
      rpcC.call(PearMethod.pairingConfirmCandidate, {
        'inviteId': invite.id,
        'candidateId': candidateId,
        'key': base64Encode(PearCrypto.unsafeTopicFromString('x').bytes),
      }),
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.unknownInvite)),
    );

    await expectLater(
      acceptFuture,
      throwsA(isA<PearConnectionException>()
          .having((e) => e.code, 'code', PearErrorCode.pairingTimeout)),
    );

    await rpcC.dispose();
  });
}
