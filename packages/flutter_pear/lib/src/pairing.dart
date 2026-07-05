import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'crypto.dart';
import 'rpc.dart';
import 'schema.dart';

/// One incoming pairing attempt on a [PearInvite] — surfaced via
/// [PearInvite.candidates].
class PearPairingCandidate {
  PearPairingCandidate._(
      this._rpc, this._inviteId, this._candidateId, this.userData);

  final PearRpc _rpc;
  final String _inviteId;
  final String _candidateId;

  /// Whatever bytes the accepting side passed to `PearPairing.acceptInvite`'s
  /// `userData` — arbitrary length, possibly empty. Not authenticated by
  /// itself; only useful for display/routing, not as a security check.
  final Uint8List userData;

  /// Completes pairing for this candidate, sending back [key] — the
  /// counterpart's `PearPairing.acceptInvite` call resolves with it. [key]
  /// is exactly 32 bytes because the underlying blind-pairing wire format
  /// fixes it at that size (not a limitation this wrapper adds) — a
  /// natural fit for sharing a swarm topic or another data-structure key
  /// the two devices will use next.
  Future<void> confirm(PearKey key) =>
      _rpc.call(PearMethod.pairingConfirmCandidate, {
        'inviteId': _inviteId,
        'candidateId': _candidateId,
        'key': base64Encode(key.bytes),
      });
}

/// One blind-pairing invite created via [PearPairing.createInvite].
class PearInvite {
  PearInvite._(this._rpc, this.invite, this.id, this.candidates);

  final PearRpc _rpc;

  /// The shareable, QR-encodable invite bytes — pass to
  /// `PearPairing.acceptInvite` on the other device.
  final Uint8List invite;

  /// This invite's identity — stable for its lifetime, useful for your own
  /// tracking/display of pending invites (e.g. a "waiting for a peer to
  /// scan" list). Distinct from [invite] itself: this is never shared with
  /// the accepting side.
  final String id;

  /// Every incoming pairing attempt on this invite, in arrival order.
  /// Broadcast — a listener attaching after a candidate already arrived
  /// misses it, same as every other Pear event stream.
  ///
  /// The SAME physical candidate device can, under real network
  /// conditions, occasionally produce more than one event here for what a
  /// user experiences as one pairing attempt (blind-pairing's own
  /// DHT-poll-based discovery and a live-connection delivery can both fire
  /// independently — confirmed empirically, ~40% of the time under system
  /// load, effectively never in a quiet environment; see flutter_pear-0zq).
  /// This wrapper does not de-dup it for you — a fix would need a genuine
  /// per-connection identity, not anything blind-pairing itself exposes.
  /// Handle it defensively: e.g. guard against acting on a second
  /// notification while already mid-confirm on the first (the example
  /// app's `StartRoomScreen._onCandidate` does exactly this).
  final Stream<PearPairingCandidate> candidates;

  /// Stops listening for new candidates on this invite. Idempotent. A
  /// `PearPairing.acceptInvite` call already waiting on it doesn't fail
  /// immediately — it fails with [PearErrorCode.pairingTimeout] once its
  /// own bound elapses, since revoking has nothing left to confirm rather
  /// than an explicit "you were revoked" signal to reach across to it with.
  Future<void> revoke() =>
      _rpc.call(PearMethod.pairingRevoke, {'inviteId': id});
}

/// Blind pairing — invites and device linking (E5.6) — wrapper 4 of 5 in
/// the data-structure family. Unlike `PearStore`/`PearBee`/`PearDrive`,
/// this isn't a corestore-backed data structure: it's a handshake protocol
/// with no open-by-name/key, no writer, and no `replicate()` of its own.
///
/// Expiry is enforced by this wrapper (checked against [createInvite]'s
/// `ttl` at [acceptInvite] time), not by blind-pairing itself — the
/// underlying library encodes an expiry timestamp into the invite bytes
/// but never checks it. Replay posture: blind-pairing prevents a captured
/// invite from being reused to derive a *different* pairing session, but
/// this wrapper makes no persistence guarantees beyond that — an invite's
/// only state lives in this worklet generation's memory, so it doesn't
/// survive a hot restart or worklet crash (persisted, restart-safe invites
/// are a pinned M2 question, not built here). This TTL/replay posture is
/// the decided v0.1 answer to that part of E5.9's own pinned question —
/// see `SECURITY_POSTURE.md` for the full key-persistence/backup/reinstall
/// picture this is one piece of.
///
/// ```dart
/// // Device A: create an invite and wait for a peer to scan it.
/// final invite = await pear.createInvite();
/// invite.candidates.listen((candidate) {
///   candidate.confirm(PearCrypto.unsafeTopicFromString('shared-room'));
/// });
/// shareAsQrCode(invite.invite); // app-provided
///
/// // Device B: scan the QR code, then accept it.
/// final sharedTopic = await pear.acceptInvite(scannedInviteBytes);
/// ```
class PearPairing {
  PearPairing._();

  /// Creates an invite, optionally expiring after [ttl] (never, if
  /// omitted). Start listening to the returned [PearInvite.candidates]
  /// before sharing the invite bytes with anyone.
  static Future<PearInvite> createInvite(PearRpc rpc, {Duration? ttl}) async {
    final result = await rpc.call(PearMethod.pairingCreateInvite, {
      if (ttl != null)
        'expiresAt': DateTime.now().add(ttl).millisecondsSinceEpoch,
    }) as Map;
    final inviteId = result['inviteId'] as String;

    final candidates = StreamController<PearPairingCandidate>.broadcast();
    final sub = rpc.events.listen((e) {
      if (e.name != PearEventName.pairingCandidate) return;
      final p = e.payload;
      if (p is! Map || p['inviteId'] != inviteId) return;
      candidates.add(PearPairingCandidate._(
        rpc,
        inviteId,
        p['candidateId'] as String,
        base64Decode(p['userData'] as String),
      ));
    });
    unawaited(candidates.done.then((_) => sub.cancel()));

    return PearInvite._(
      rpc,
      base64Decode(result['invite'] as String),
      inviteId,
      candidates.stream,
    );
  }

  /// Accepts [invite], optionally announcing [userData] to the inviter.
  /// Blocks until the inviter confirms (see
  /// [PearPairingCandidate.confirm]), bounded by [timeout] — including a
  /// revoked invite, which never confirms and so times out the same way.
  /// Returns the 32-byte key the inviter chose to share.
  ///
  /// Throws with [PearErrorCode.invalidInvite] for undecodable bytes,
  /// [PearErrorCode.inviteExpired] if past the invite's `ttl`, or
  /// [PearErrorCode.pairingTimeout] if nobody confirms in time.
  static Future<PearKey> acceptInvite(
    PearRpc rpc,
    Uint8List invite, {
    Uint8List? userData,
    Duration timeout = const Duration(seconds: 30),
  }) async {
    final result = await rpc.call(
      PearMethod.pairingAcceptInvite,
      {
        'invite': base64Encode(invite),
        if (userData != null) 'userData': base64Encode(userData),
        'timeoutMs': timeout.inMilliseconds,
      },
      // The RPC call itself must not time out before the worklet's own
      // bounded pairing wait does -- otherwise a slow-but-still-bounded
      // pairing would surface as RPC_TIMEOUT instead of the more
      // meaningful PAIRING_TIMEOUT, or (worse) succeed on the worklet side
      // after Dart already gave up on it.
      timeout + const Duration(seconds: 5),
    ) as Map;
    return PearKey(base64Decode(result['key'] as String));
  }
}
