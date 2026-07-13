import 'schema.dart';

/// One [PearErrorCode]'s user-facing documentation: what went wrong, why,
/// and the concrete step to fix or work around it.
class PearErrorCatalogEntry {
  /// Creates a catalog entry. Used only to build [PearErrorCatalog.entries]
  /// -- app code reads entries from there rather than constructing its own.
  const PearErrorCatalogEntry({
    required this.problem,
    required this.cause,
    required this.fix,
  });

  /// One-sentence statement of what failed.
  final String problem;

  /// Why this happens.
  final String cause;

  /// The concrete, actionable step to resolve or avoid it.
  final String fix;
}

/// problem/cause/fix documentation for every [PearErrorCode], keyed by the
/// code string (e.g. `PearErrorCode.coreClosed`) -- what [PearException]'s
/// `toString()` renders instead of a bare code, and what
/// `packages/flutter_pear/ERRORS.md` documents at length (see
/// [anchorFor]). Checked for completeness in both directions against the
/// real [PearErrorCode] registry by `test/error_catalog_test.dart`.
abstract final class PearErrorCatalog {
  PearErrorCatalog._();

  /// Every registered [PearErrorCode], keyed by its code string.
  static const entries = <String, PearErrorCatalogEntry>{
    PearErrorCode.unknownPeer: PearErrorCatalogEntry(
      problem: 'Tried to write to a peer that has no open connection.',
      cause: 'The connection to that peer already closed (the peer '
          'disconnected, reconnected as a new PearConnection, or the '
          'connection was never established) before this write reached '
          'the worklet.',
      fix: "Don't hold onto a PearConnection past its own data stream "
          'closing -- get the new PearConnection from '
          'PearSwarm.connections instead of reusing an old one.',
    ),
    PearErrorCode.connectionClosed: PearErrorCatalogEntry(
      problem: 'Called write() on a PearConnection that has already '
          'closed.',
      cause: 'The connection dropped (peer disconnected, network change, '
          'etc.) -- a PearConnection is ephemeral and never revives once '
          'closed.',
      fix: 'Stop writing to this object; if the same peer reconnects, a '
          'brand-new PearConnection arrives on PearSwarm.connections -- '
          'write to that one instead.',
    ),
    PearErrorCode.unknownMethod: PearErrorCatalogEntry(
      problem: "The worklet doesn't recognize the RPC method that was "
          'called.',
      cause: 'Almost always a version skew between the Dart plugin and '
          'the bundled pear-end JS (e.g. a stale assets/pear-end.bundle '
          'after a plugin upgrade).',
      fix: 'Run `dart run flutter_pear:pack` to rebuild the bundle, or '
          'update flutter_pear so the Dart and JS sides agree on the '
          'schema again.',
    ),
    PearErrorCode.forcedError: PearErrorCatalogEntry(
      problem: 'This is a deliberately-raised test error, not a real '
          'failure.',
      cause: 'Something called the debug/force-error RPC hook to '
          "exercise the error path -- flutter_pear's own tests use this.",
      fix: "Nothing to fix -- if you're seeing this outside of "
          "flutter_pear's own tests, check what's calling the "
          'force-error hook.',
    ),
    PearErrorCode.rpcTimeout: PearErrorCatalogEntry(
      problem: 'An RPC call to the worklet never got a response within '
          'its timeout.',
      cause: "The worklet is slow, stuck, or the call's timeout is too "
          'short for what it was doing (e.g. a large replicate/mirror '
          'operation).',
      fix: 'Pass a longer `timeout` for long-running calls; otherwise '
          'check `Pear.worklet.onCrash` for why the worklet might be stuck.',
    ),
    PearErrorCode.workletDisposed: PearErrorCatalogEntry(
      problem: 'A call was still in flight when the Pear instance was '
          'disposed.',
      cause: 'Your app called `pear.dispose()` (or a wrapper close/'
          'dispose) before an in-flight call finished.',
      fix: 'Await or cancel pending calls before disposing, or treat '
          'this as an expected shutdown race and ignore it.',
    ),
    PearErrorCode.sendFailed: PearErrorCatalogEntry(
      problem: 'A request never reached the worklet at all.',
      cause: "The worklet wasn't running (already stopped or crashed) "
          'when the call tried to send.',
      fix: 'Make sure `Pear.start()` has completed, and the worklet '
          "hasn't crashed (check `Pear.worklet.onCrash`), before issuing calls.",
    ),
    PearErrorCode.storageUnavailable: PearErrorCatalogEntry(
      problem: 'A storage operation (Corestore, Hypercore, bulk file '
          'write, ...) failed on the worklet side.',
      cause: 'The underlying filesystem/storage layer rejected the '
          'operation (disk full, permissions, a corrupted store, ...).',
      fix: "Check the device's available storage and that the app has "
          'write access to its own files directory -- `.details` usually '
          'names the specific failure.',
    ),
    PearErrorCode.bundleVersionMismatch: PearErrorCatalogEntry(
      problem: "The bundled pear-end JS doesn't match the version this "
          'plugin expects.',
      cause: 'assets/pear-end.bundle is stale -- pear-end/ (or the '
          "pinned Bare Kit version) changed without re-running the "
          'pack step.',
      fix: 'Run `dart run flutter_pear:pack` from the flutter_pear '
          'package to rebuild and re-pin the bundle, then rebuild your '
          'app.',
    ),
    PearErrorCode.workletCrashed: PearErrorCatalogEntry(
      problem: 'The worklet crashed (or its IPC connection ended) while '
          'a call was pending.',
      cause: 'An uncaught JS exception or native failure inside the '
          'Bare worklet.',
      fix: 'Listen to `Pear.worklet.onCrash` for the underlying reason and '
          'restart via `Pear.start()` again; file an issue if the crash '
          'looks like a bug in flutter_pear itself.',
    ),
    PearErrorCode.bareRuntimeMissing: PearErrorCatalogEntry(
      problem: 'The `bare` runtime is not installed on this desktop '
          'machine, so `Pear.start()` could not boot a worklet at all.',
      cause: 'macOS and Linux desktop hosts run pear-end as a real `bare` '
          'subprocess found on `PATH` -- unlike mobile, there is no '
          'bundled/linked runtime to fall back to.',
      fix: 'Install the Bare runtime globally with `npm i -g bare`, then '
          'restart your app.',
    ),
    PearErrorCode.connectTimeout: PearErrorCatalogEntry(
      problem: 'PearSwarm.join never found and connected to a peer '
          'within its timeout.',
      cause: 'No peer joined the same topic, or network conditions '
          '(NAT/firewall) prevented discovery or connection.',
      fix: 'Confirm both peers are using the exact same topic bytes; if '
          'this happens consistently, also check for UDP_BLOCKED.',
    ),
    PearErrorCode.udpBlocked: PearErrorCatalogEntry(
      problem: "The worklet's best-effort guess that UDP is blocked on "
          'this network.',
      cause: 'Some carrier/enterprise NATs and firewalls block the UDP '
          "traffic Hyperswarm's DHT needs.",
      fix: 'Try a different network (e.g. switch off a restrictive '
          'Wi-Fi/VPN) -- this is a network-environment issue, not '
          'something flutter_pear can work around.',
    ),
    PearErrorCode.indexOutOfRange: PearErrorCatalogEntry(
      problem: 'PearCore.get was asked for an index at or past the '
          "core's current length.",
      cause: "The caller requested a block that hasn't been appended "
          '(locally or by a peer) yet.',
      fix: 'Check `PearCore.length` (or wait for a peer append to '
          'replicate) before calling `get()` with that index.',
    ),
    PearErrorCode.coreClosed: PearErrorCatalogEntry(
      problem: 'A call targeted a PearCore that has already been '
          'closed.',
      cause: '`PearCore.close()` already ran before this call.',
      fix: "Don't call methods on a PearCore after closing it -- "
          're-open via `PearStore.get()` if you need it again.',
    ),
    PearErrorCode.unknownCore: PearErrorCatalogEntry(
      problem: 'A call referenced a core key this worklet generation '
          'never opened.',
      cause: 'Usually a stale key held across a hot restart/worklet-'
          "generation change, or a typo'd key.",
      fix: 'Re-open the core via `PearStore.get()` in the current '
          'worklet generation before using it.',
    ),
    PearErrorCode.unknownBee: PearErrorCatalogEntry(
      problem: 'A call referenced a Hyperbee this worklet generation '
          'never opened.',
      cause: 'A stale reference held across a worklet restart, or a '
          "typo'd key.",
      fix: 'Re-open via `PearBee.open()` in the current worklet '
          'generation before using it.',
    ),
    PearErrorCode.beeClosed: PearErrorCatalogEntry(
      problem: 'A call targeted a PearBee that has already been closed.',
      cause: '`PearBee.close()` already ran before this call.',
      fix: "Don't call methods on a PearBee after closing it -- re-open "
          'via `PearBee.open()` if you need it again.',
    ),
    PearErrorCode.unknownDrive: PearErrorCatalogEntry(
      problem: 'A call referenced a Hyperdrive this worklet generation '
          'never opened.',
      cause: 'A stale reference held across a worklet restart, or a '
          "typo'd key.",
      fix: 'Re-open via `PearDrive.open()` in the current worklet '
          'generation before using it.',
    ),
    PearErrorCode.driveClosed: PearErrorCatalogEntry(
      problem: 'A call targeted a PearDrive that has already been '
          'closed.',
      cause: '`PearDrive.close()` already ran before this call.',
      fix: "Don't call methods on a PearDrive after closing it -- "
          're-open via `PearDrive.open()` if you need it again.',
    ),
    PearErrorCode.fileNotFound: PearErrorCatalogEntry(
      problem: 'PearDrive.get targeted a path with no entry in the '
          'drive.',
      cause: "Nothing has been put() at that path (locally or "
          'replicated from a peer) yet.',
      fix: 'Check `PearDrive.exists()` first, and that the path matches '
          'exactly what the writer put() -- drive paths are '
          'case-sensitive.',
    ),
    PearErrorCode.invalidInvite: PearErrorCatalogEntry(
      problem: 'The invite bytes passed to acceptInvite could not be '
          'decoded.',
      cause: "The bytes are corrupted, truncated, or aren't a real "
          'flutter_pear invite at all (e.g. pasted or scanned '
          'incorrectly).',
      fix: 'Re-share the invite (re-scan the QR code or re-copy the '
          'bytes) from `PearPairing.createInvite`\'s output.',
    ),
    PearErrorCode.inviteExpired: PearErrorCatalogEntry(
      problem: 'The invite passed to acceptInvite is past its own ttl.',
      cause: '`PearPairing.createInvite` was called with a `ttl`, and '
          'more time than that has passed.',
      fix: 'Create a fresh invite by calling `createInvite` again; if '
          'this happens often, consider a longer `ttl`.',
    ),
    PearErrorCode.pairingTimeout: PearErrorCatalogEntry(
      problem: "acceptInvite's bound elapsed with nobody confirming.",
      cause: 'Either the inviter is genuinely slow/offline, or the '
          'invite was revoked -- a revoked invite never confirms either.',
      fix: "Confirm the inviter's device is online and still listening "
          'on `PearInvite.candidates`; if revoked intentionally, this is '
          'expected.',
    ),
    PearErrorCode.unknownInvite: PearErrorCatalogEntry(
      problem: 'A call referenced an invite id this worklet generation '
          'never created.',
      cause: 'A stale invite id held across a worklet restart, or '
          'confirming/revoking an invite from a different generation.',
      fix: 'Create a new invite via `PearPairing.createInvite` in the '
          'current worklet generation.',
    ),
    PearErrorCode.unknownCandidate: PearErrorCatalogEntry(
      problem: 'A call referenced a pairing candidate that is not '
          'currently pending on that invite.',
      cause: 'The candidate already confirmed, or never existed (a '
          'stale or duplicate confirm call).',
      fix: 'Only call `PearPairingCandidate.confirm` once per '
          'candidate, using the candidate from the most recent '
          '`PearInvite.candidates` event.',
    ),
    PearErrorCode.pairingFailed: PearErrorCatalogEntry(
      problem: 'A pairing call failed for a reason none of the more '
          'specific pairing codes cover.',
      cause: 'An internal blind-pairing/Protomux failure -- e.g. a '
          'malformed confirm key.',
      fix: 'Check `.details` for the underlying JS error; if it looks '
          'like a flutter_pear bug, file an issue with the details '
          'attached.',
    ),
    PearErrorCode.malformedOp: PearErrorCatalogEntry(
      problem: 'An Autobase recipe rejected an operation it could not '
          'interpret.',
      cause: "The op's shape doesn't match what the chosen PearRecipe "
          "(lww/orderedLog/crdtMap) expects -- e.g. a `del` referencing "
          'the wrong tag encoding.',
      fix: 'Check the exact op shape your PearRecipe expects, and that '
          "you're not mixing operations meant for a different recipe.",
    ),
    PearErrorCode.unknownRecipe: PearErrorCatalogEntry(
      problem: "PearBase.open's recipe name doesn't match any recipe "
          'pear-end exports.',
      cause: '`PearBase.open`\'s typed API only ever accepts a real '
          '`PearRecipe` enum value, so normal usage can\'t trigger this '
          '-- reaching it means the typed enum was bypassed entirely '
          '(a raw RPC call) or the Dart plugin and bundled pear-end JS '
          'have drifted out of sync on recipe names.',
      fix: 'If you\'re calling `PearBase.open(recipe: ...)` normally, '
          'this points to a version mismatch -- try `dart run '
          'flutter_pear:pack` to rebuild the bundle. If you\'re making a '
          'raw RPC call, use one of the `PearRecipe` enum\'s own values '
          '(lww/orderedLog/crdtMap) instead.',
    ),
    PearErrorCode.unknownBase: PearErrorCatalogEntry(
      problem: 'A call referenced an Autobase this worklet generation '
          'never opened.',
      cause: 'A stale reference held across a worklet restart, or a '
          "typo'd key.",
      fix: 'Re-open via `PearBase.open()` in the current worklet '
          'generation before using it.',
    ),
    PearErrorCode.baseClosed: PearErrorCatalogEntry(
      problem: 'A call targeted a PearBase that has already been '
          'closed.',
      cause: '`PearBase.close()` already ran before this call.',
      fix: "Don't call methods on a PearBase after closing it -- "
          're-open via `PearBase.open()` if you need it again.',
    ),
  };
}

/// The stable docs anchor for [code] in `packages/flutter_pear/ERRORS.md` --
/// always mechanically derived from the code itself (never hand-typed
/// alongside 30 catalog entries, where it could silently drift).
String anchorFor(String code) => 'ERRORS.md#$code';
