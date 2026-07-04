/// The RPC/event contract shared between Dart and the pear-end worklet.
///
/// This is the single source of truth for method names, event names, error
/// codes, and wire constants — the fake (`flutter_pear_test`) conforms to it,
/// wrappers consume it, pear-end implements it. Mirrored by hand in
/// `pear-end/schema.js`; there is no codegen (LOCKED — see E2.1).
///
/// The wire protocol has five primitives:
/// 1. request/response ([PearMethod] + the `{"id","m","p"}`/`{"id","ok"|"err"}`
///    envelope in `rpc.dart`)
/// 2. events ([PearEventName] + the `{"ev","p"}` envelope)
/// 3. a typed error/crash envelope (`message`/`code`/`stack`, see
///    [PearErrorCode] and [PearException])
/// 4. binary framing via a 1-byte frame-type discriminator ([PearFrameType],
///    prefixed on every frame — see `rpc.dart`'s encode/decode)
/// 5. chunked-stream + backpressure for bulk transport — RESERVED ONLY
///    (LOCKED: no machinery until a throughput benchmark demands it; M3's
///    Hyperdrive work is expected to be the first consumer)
library;

/// RPC method names — the `m` field of a request frame.
abstract final class PearMethod {
  /// Join a Hyperswarm topic.
  static const swarmJoin = 'swarm.join';

  /// Leave a previously-joined topic.
  static const swarmLeave = 'swarm.leave';

  /// Write bytes to a peer connection.
  static const connectionWrite = 'connection.write';

  /// Debug-only: throws a forced JS error so the RPC error path can be
  /// exercised end-to-end. Not part of the production surface.
  static const debugForceError = 'debug.forceError';

  /// Debug-only: schedules a genuinely uncaught exception (escaping this
  /// call's own promise chain, unlike [debugForceError]) so the
  /// [PearEventName.workletCrash] path can be exercised end-to-end,
  /// including on a real device. Not part of the production surface.
  static const debugForceCrash = 'debug.forceCrash';

  /// Debug-only: echoes `p.data` (base64) straight back as `{data}` with no
  /// other processing — a raw in-channel round trip with no JS-side work
  /// to attribute latency to. Exists for E5.1's platform-channel throughput
  /// benchmark (`packages/flutter_pear_example/integration_test/
  /// bulk_transport_benchmark_test.dart`); not part of the production
  /// surface.
  static const debugEcho = 'debug.echo';

  /// Returns the current worklet's session identity: `{nonce, bundleVersion}`
  /// (see [PearHandshakeField]). Answerable at any time after boot -- unlike
  /// an attach *event*, a request/response works correctly whether this is
  /// the worklet's first-ever query or a Dart hot restart re-querying an
  /// already-running worklet it just reattached to.
  static const attachInfo = 'attach.info';

  /// Writes `p.data` (whole-payload base64, NOT chunked/streamed) to a new
  /// file inside the worklet's own storage and returns `{path}` — the
  /// file-path bulk seam (E4.4, codex #4 LOCKED): a primitive for moving
  /// bulk bytes (Hyperdrive contents, E5) without inflating them through
  /// JSON/base64 on every access, by handing the caller a path to read
  /// directly instead. Distinct from the reserved [PearFrameType.raw]
  /// chunked-stream primitive (still unimplemented, M3) — this method
  /// still travels as one ordinary JSON request/response; it's the
  /// *destination* (a file, not the response payload) that avoids the
  /// inflation, not the transport.
  static const bulkWriteFile = 'bulk.writeFile';

  /// Opens (creating if new) a Hypercore by `p.name`, or attaches to an
  /// existing one by its public `p.key` (hex) — exactly one is given. See
  /// [PearMethod.storeGet]'s Dart consumer, `PearStore.get` in `store.dart`
  /// (E5.2). Returns `{key, length}`.
  static const storeGet = 'store.get';

  /// Appends `p.data` (a list of base64-encoded blocks) to the core `p.key`
  /// (hex). Returns `{length}` — the core's new length. See `PearCore.append`.
  static const coreAppend = 'core.append';

  /// Returns the block at `p.index` of core `p.key` (hex) as `{data}`
  /// (base64). See `PearCore.get`.
  static const coreGet = 'core.get';

  /// Replicates core `p.key` (hex) over the existing peer connection `p.peer`
  /// (hex) — the peer must already be connected (see [swarmJoin]/
  /// [PearEventName.swarmConnection]). See `PearCore.replicate`.
  static const coreReplicate = 'core.replicate';

  /// Closes core `p.key` (hex). Idempotent. Further [coreAppend]/[coreGet]/
  /// [coreReplicate] calls against that key fail with
  /// [PearErrorCode.coreClosed]. See `PearCore.close`.
  static const coreClose = 'core.close';

  /// Opens (creating if new) a Hyperbee by `p.name`, or attaches to an
  /// existing one by its public `p.key` (hex) — exactly one is given, same
  /// contract as [storeGet]. Returns `{key}`. See `PearBee.open` in
  /// `bee.dart` (E5.3).
  static const beeOpen = 'bee.open';

  /// Reads the value at `p.key` (base64) in bee `p.bee` (hex). Returns
  /// `{found, value}` — `value` (base64) is only present when `found` is
  /// true, distinguishing a missing key from an empty value. See
  /// `PearBee.get`.
  static const beeGet = 'bee.get';

  /// Writes `p.key`/`p.value` (both base64) in bee `p.bee` (hex). Returns
  /// nothing. See `PearBee.put`.
  static const beePut = 'bee.put';

  /// Deletes `p.key` (base64) from bee `p.bee` (hex). Returns nothing —
  /// deleting an already-absent key is a no-op, not an error. See
  /// `PearBee.del`.
  static const beeDel = 'bee.del';

  /// Replicates bee `p.bee` (hex)'s underlying core over the existing peer
  /// connection `p.peer` (hex) — same contract as [coreReplicate] (needed
  /// for a bee's changes to ever reach another peer; watching alone never
  /// moves bytes). See `PearBee.replicate`.
  static const beeReplicate = 'bee.replicate';

  /// Reads every entry in bee `p.bee` (hex) within the optional
  /// `p.gt`/`p.gte`/`p.lt`/`p.lte` bounds (base64), honoring `p.reverse`
  /// (bool) and `p.limit` (int), as a single bounded snapshot — not a live
  /// subscription (see [beeWatch] for that). Returns
  /// `{entries: [{key, value}, ...]}` (all base64). See `PearBee.range`.
  static const beeRange = 'bee.range';

  /// Starts watching bee `p.bee` (hex) for changes within the optional
  /// `p.gt`/`p.gte`/`p.lt`/`p.lte` bounds (base64), tagged `p.watch` (a
  /// caller-generated id disambiguating concurrent watches on the same
  /// bee). Returns nothing; emits [PearEventName.beeUpdate] on every
  /// change until [beeUnwatch]. See `PearBee.watch`.
  static const beeWatch = 'bee.watch';

  /// Stops the watch `p.watch` on bee `p.bee` (hex) started by [beeWatch].
  /// Idempotent. See `PearBee.watch`'s stream-cancel behavior.
  static const beeUnwatch = 'bee.unwatch';

  /// Closes bee `p.bee` (hex) — also stops every outstanding [beeWatch] on
  /// it. Idempotent. Further [beeGet]/[beePut]/[beeDel]/[beeRange]/
  /// [beeWatch] calls against that key fail with [PearErrorCode.beeClosed].
  /// See `PearBee.close`.
  static const beeClose = 'bee.close';

  /// Opens (creating if new) a Hyperdrive by `p.name`, or attaches to an
  /// existing one by its public `p.key` (hex) — exactly one is given, same
  /// contract as [storeGet]/[beeOpen]. Returns `{key}`. See `PearDrive.open`
  /// in `drive.dart` (E5.5).
  static const driveOpen = 'drive.open';

  /// Streams the local file at `p.localSourcePath` into drive `p.drive`
  /// (hex) at virtual path `p.path` — the whole file NEVER travels through
  /// this call's own JSON envelope (E5.1 codex #4 LOCKED, the file-path
  /// bulk seam): only the two path strings do, so a payload of any size
  /// never inflates through JSON/base64 the way [PearMethod.bulkWriteFile]
  /// does. See `PearDrive.put`.
  static const drivePut = 'drive.put';

  /// Streams the content at virtual path `p.path` in drive `p.drive` (hex)
  /// to the local file `p.destinationPath` — same never-inflates-through-
  /// JSON guarantee as [drivePut]. Throws [PearErrorCode.fileNotFound] if
  /// `p.path` doesn't exist. See `PearDrive.get`.
  static const driveGet = 'drive.get';

  /// Returns `{exists}` for virtual path `p.path` in drive `p.drive` (hex).
  /// See `PearDrive.exists`.
  static const driveExists = 'drive.exists';

  /// Deletes virtual path `p.path` from drive `p.drive` (hex). A no-op, not
  /// an error, if `p.path` isn't present. See `PearDrive.delete`.
  static const driveDelete = 'drive.delete';

  /// Lists every virtual path under `p.folder` (default `/`) in drive
  /// `p.drive` (hex) as a single bounded snapshot — same shape/caveat as
  /// [beeRange]. Returns `{paths: [...]}`. See `PearDrive.list`.
  static const driveList = 'drive.list';

  /// Replicates drive `p.drive` (hex)'s underlying core over the existing
  /// peer connection `p.peer` (hex) — same contract as [coreReplicate]/
  /// [beeReplicate]. See `PearDrive.replicate`.
  static const driveReplicate = 'drive.replicate';

  /// Mirrors the ENTIRE drive `p.drive` (hex) to the local directory
  /// `p.localDir`, using the Pear ecosystem's own `mirror-drive` (streaming,
  /// diff-aware — only changed files actually copy). Returns
  /// `{added, changed, removed}` file counts. See `PearDrive.mirrorToDisk`.
  static const driveMirrorToDisk = 'drive.mirrorToDisk';

  /// Closes drive `p.drive` (hex). Idempotent. Further [drivePut]/
  /// [driveGet]/[driveExists]/[driveDelete]/[driveList]/[driveReplicate]/
  /// [driveMirrorToDisk] calls against that key fail with
  /// [PearErrorCode.driveClosed]. See `PearDrive.close`.
  static const driveClose = 'drive.close';

  /// Creates a blind-pairing invite, optionally expiring at `p.expiresAt`
  /// (epoch milliseconds; omitted/0 means never). Returns
  /// `{invite, inviteId}` (`invite` base64 — the shareable/QR-encodable
  /// bytes; `inviteId` hex — this invite's identity, used by
  /// [pairingConfirmCandidate]/[pairingRevoke]). See `PearPairing.createInvite`
  /// (E5.6).
  static const pairingCreateInvite = 'pairing.createInvite';

  /// Accepts the blind-pairing invite `p.invite` (base64), optionally
  /// announcing `p.userData` (base64) to the inviter, bounded by
  /// `p.timeoutMs` (default 30000). Blocks until the inviter calls
  /// [pairingConfirmCandidate] and returns `{key}` (base64, 32 bytes — the
  /// key the inviter chose to share). Throws [PearErrorCode.invalidInvite]
  /// for undecodable bytes, [PearErrorCode.inviteExpired] if past
  /// `p.expiresAt`, or [PearErrorCode.pairingTimeout] if nobody confirms in
  /// time (including a revoked invite, which never confirms). See
  /// `PearPairing.acceptInvite`.
  static const pairingAcceptInvite = 'pairing.acceptInvite';

  /// Completes pairing for candidate `p.candidateId` on invite `p.inviteId`
  /// (both hex), sending back `p.key` (base64, exactly 32 bytes) — the
  /// counterpart's [pairingAcceptInvite] call resolves with this key. See
  /// `PearPairingCandidate.confirm`.
  static const pairingConfirmCandidate = 'pairing.confirmCandidate';

  /// Stops listening for new candidates on invite `p.inviteId` (hex).
  /// Idempotent. Any [pairingAcceptInvite] already waiting on it fails with
  /// [PearErrorCode.pairingTimeout] once its own bound elapses (revoking
  /// doesn't reach across to cancel an in-flight accept immediately -- see
  /// that method's doc). See `PearInvite.revoke`.
  static const pairingRevoke = 'pairing.revoke';

  /// Opens the Autobase `p.recipe` (a [PearRecipe] name) known locally as
  /// `p.name` (creating it on first use), or attaches to an existing one by
  /// its public `p.key` -- exactly one of `p.name`/`p.key` must be given,
  /// same contract as `PearStore.get`. `p.recipe` is required even when
  /// reattaching by key: the worklet has no other way to know which
  /// open/apply pair (pear-end's recipes module, E5.7) to construct this
  /// generation's Autobase instance with. Returns `{key, writerKey}` (both
  /// hex) -- `writerKey` is THIS worklet generation's own local writer
  /// identity for this base, share it with a peer (e.g. over
  /// `PearPairing`) so THEY can pass it to their own [baseAppend]'s
  /// `addWriter` op to admit you. See `PearBase.open` (E5.8).
  static const baseOpen = 'base.open';

  /// Replicates base `p.base` (hex)'s underlying cores over the existing
  /// peer connection `p.peer` (hex) — same contract as [coreReplicate]/
  /// [beeReplicate]/[driveReplicate]: watching or appending alone never
  /// moves bytes, this is what lets another writer's ops ever reach this
  /// peer (and vice versa). See `PearBase.replicate`.
  static const baseReplicate = 'base.replicate';

  /// Appends `p.value` to base `p.base` (hex)'s local writer log --
  /// `p.value` is whatever op shape the base's own recipe expects (see
  /// pear-end's recipes module), OR the shared `{addWriter}`/`{removeWriter}`
  /// directive every recipe recognizes identically. See `PearBase.put`/
  /// `PearBase.del`/`PearBase.append`/`PearBase.addWriter`/
  /// `PearBase.removeWriter`.
  static const baseAppend = 'base.append';

  /// Reads the CURRENT materialized value for `p.key` (base64) from base
  /// `p.base` (hex)'s merged view -- lww/crdtMap recipes only (orderedLog
  /// has no keyed read; see [baseRange]). Returns `{exists}`, plus `value`
  /// (base64) when `exists` is true. See `PearBase.get`.
  static const baseGet = 'base.get';

  /// Reads entries `p.start` (inclusive, default 0) through `p.end`
  /// (exclusive, default the current length) of base `p.base` (hex)'s
  /// merged view as a single bounded snapshot -- same shape/caveat as
  /// [beeRange]; orderedLog only (lww/crdtMap have no ordered log; see
  /// [baseGet]). Returns `{entries: [...]}` (each base64). See
  /// `PearBase.range`.
  static const baseRange = 'base.range';

  /// Subscribes to merged-view changes on base `p.base` (hex), tagged
  /// `p.watch` (caller-generated, since a base can have more than one
  /// concurrent watch) -- same subscribe-lifecycle contract as
  /// [beeWatch]/[beeUnwatch]. See `PearBase.watch`.
  static const baseWatch = 'base.watch';

  /// Unsubscribes watch `p.watch` on base `p.base` (hex) -- same contract
  /// as [beeUnwatch]. See `PearBase.watch`.
  static const baseUnwatch = 'base.unwatch';

  /// Closes base `p.base` (hex). Idempotent. Also stops every outstanding
  /// [baseWatch] on it. Further [baseAppend]/[baseGet]/[baseRange]/
  /// [baseWatch] calls against that key fail with
  /// [PearErrorCode.baseClosed]. See `PearBase.close`.
  static const baseClose = 'base.close';
}

/// Worklet-emitted event names — the `ev` field of an event frame.
abstract final class PearEventName {
  /// A new peer connection was established on a joined topic.
  static const swarmConnection = 'swarm.connection';

  /// Bytes arrived on a peer connection.
  static const connectionData = 'connection.data';

  /// A peer connection closed.
  static const connectionClose = 'connection.close';

  /// A swarm-level lifecycle notice (joining, errors, …) not tied to one peer.
  static const swarmLifecycle = 'swarm.lifecycle';

  /// A frame the RPC layer couldn't handle — an unrecognized
  /// [PearFrameType] byte, or a JSON control frame that failed to parse.
  /// Synthesized on whichever side detects it (Dart or pear-end); never
  /// travels as a real worklet-to-worklet wire event. Payload always
  /// includes `reason`; other fields depend on what went wrong.
  static const rpcDiagnostic = 'rpc.diagnostic';

  /// The worklet is reporting its own imminent death (an uncaught JS
  /// exception or unhandled rejection, self-reported via `Bare.on(...)`
  /// before calling `Bare.exit()` -- see pear-end/index.js) so Dart doesn't
  /// have to wait out a timeout to learn a pending call will never be
  /// answered. Payload: `{kind, message, stack?}`. This is the DETAILED
  /// crash signal; see also `WorkletIpc.onCrash` for the NATIVE-detected,
  /// detail-less backstop for crashes that predate this worklet even
  /// getting far enough to report on itself.
  static const workletCrash = 'worklet.crash';

  /// A core's length changed — either a local [PearMethod.coreAppend] or
  /// blocks arriving over an active [PearMethod.coreReplicate] session.
  /// Payload: `{key, length}`. See `PearCore.updates` (E5.2).
  static const coreUpdate = 'core.update';

  /// A bee changed within an active [PearMethod.beeWatch]'s bounds.
  /// Payload: `{bee, watch}` — `watch` identifies which [PearMethod.beeWatch]
  /// call this belongs to (a bee may have more than one concurrent watch).
  /// See `PearBee.watch` (E5.3).
  static const beeUpdate = 'bee.update';

  /// A new candidate wants to pair on an invite created by
  /// [PearMethod.pairingCreateInvite]. Payload: `{inviteId, candidateId,
  /// userData}` (`userData` base64 — the candidate's own
  /// [PearMethod.pairingAcceptInvite] `p.userData`, arbitrary length,
  /// possibly empty). See `PearInvite.candidates` (E5.6).
  static const pairingCandidate = 'pairing.candidate';

  /// A base's merged view changed within an active [PearMethod.baseWatch]'s
  /// subscription. Payload: `{base, watch}` — `watch` identifies which
  /// [PearMethod.baseWatch] call this belongs to (a base may have more than
  /// one concurrent watch). See `PearBase.watch` (E5.8).
  static const baseUpdate = 'base.update';
}

/// Connection-state vocabulary for `PearSwarm.state` — also the wire value
/// of a [PearEventName.swarmLifecycle] event's `state` field. Each member's
/// [Enum.name] IS its wire string (e.g. `PearSwarmState.discovering.name ==
/// 'discovering'`) — no separate string-constant class to keep in sync,
/// cross-checked against pear-end/schema.js's `SwarmState` object instead.
enum PearSwarmState {
  /// Actively searching the DHT for peers on the joined topic.
  discovering,

  /// At least one peer candidate was found; a connection attempt is underway.
  connecting,

  /// At least one peer connection is open.
  connected,

  /// Was [connected] at least once; every peer connection has since closed
  /// and discovery has resumed automatically.
  reconnecting,

  /// The worklet is suspended (see `BareWorklet.suspend`) — emitted by
  /// `Pear.suspend` (whether called directly or automatically by
  /// `PearLifecycle`, E6.2). A suspended worklet can't run JS at all, so
  /// pear-end never emits this itself; `PearRpc.workletSuspendedChanges` is
  /// the Dart-local substitute every `PearSwarm` listens to. On resume,
  /// transitions to [connected] (a peer is still tracked), [reconnecting]
  /// (was connected before, none tracked now), or [discovering] (never
  /// connected before this suspend cycle) — a same-worklet-generation
  /// best-effort signal, not a promise that pear-end has itself confirmed
  /// anything; a real change still arrives separately as its own ordinary
  /// transition once pear-end notices it. See `BACKGROUND_EXECUTION.md`
  /// for what this state actually reflects on Android versus what's
  /// outside this library's control entirely (Doze/App Standby/OEM
  /// killers, E6.4).
  suspended,

  /// Discovery/connection failed outright — never reached [connected]
  /// within `PearSwarmDefaults.joinTimeout`, or the worklet reported a
  /// swarm-level error. The accompanying `PearSwarmStatus.error` carries
  /// why (e.g. [PearErrorCode.connectTimeout] or [PearErrorCode.udpBlocked]).
  failed,
}

/// Which built-in Autobase merge recipe a `PearBase.open` call (E5.8) picks,
/// by name. Each member's [Enum.name] IS its wire string (same convention as
/// [PearSwarmState]) — no separate string-constant class to keep in sync,
/// cross-checked against pear-end/schema.js's `Recipe` object instead; the
/// pear-end recipes module (E5.7) exports one entry per member here, keyed
/// by that same `.name`. LOCKED (project decision, "codex #2"): app-facing
/// Autobase access is always by recipe name, never a generic Dart-driven
/// open/apply — see the pear-end recipes module's own doc comment for why
/// (deterministic multi-writer indexing across an RPC boundary is
/// slow/reentrant/failure-prone) and for exactly what each recipe guarantees.
enum PearRecipe {
  /// Last-writer-wins map: `key -> value`. "Latest" means Autobase's own
  /// deterministic per-node ordering (writer + that writer's local
  /// sequence number), never wall-clock time.
  lww,

  /// An append-only merged log: every writer's entries interleaved into
  /// one order, deterministic because it's exactly Autobase's own causal
  /// linearization — no extra recipe-level tiebreak on top of it.
  orderedLog,

  /// An add-wins observed-remove map: `key -> value`, where a concurrent
  /// put and delete resolve so the put survives unless the deleter had
  /// already observed it. See the pear-end recipes module's doc comment
  /// for the exact CRDT variant (an OR-Set of `(tag, value)` pairs per
  /// key, materialized to one scalar via the same tiebreak as [lww]).
  crdtMap,
}

/// Which typed exception subtype (see `exceptions.dart`) a [PearErrorCode]
/// maps to. A code with no entry in [PearErrorCode.categories] falls back to
/// the base `PearException` — see `pearExceptionFor` in `exceptions.dart`.
enum PearErrorCategory {
  /// Maps to `PearConnectionException`.
  connection,

  /// Maps to `PearStorageException`.
  storage,
}

/// Known `err.code` values a failed call's error envelope may carry.
///
/// [unknownPeer], [unknownMethod], [forcedError], and [storageUnavailable]
/// are thrown by the worklet and travel here over RPC. [rpcTimeout] and
/// [workletDisposed] are synthesized entirely on the Dart side by [PearRpc]
/// (the worklet never sees or sends them) — same registry either way, since
/// a caller catching a [PearException] shouldn't have to care which side
/// detected the failure.
abstract final class PearErrorCode {
  /// [PearMethod.connectionWrite] targeted a peer with no open connection.
  static const unknownPeer = 'UNKNOWN_PEER';

  /// `PearConnection.write` was called on a connection that has already
  /// closed (E6.5, see `RECONNECT_CONTRACT.md`) — synthesized entirely on
  /// the Dart side by `PearConnection` itself, never sent by the worklet.
  /// Distinct from [unknownPeer]: that's the WORKLET reporting no live
  /// connection for a peer hex (which a reconnected peer's new
  /// `PearConnection` would no longer trigger); this is the Dart object
  /// itself refusing to resurrect a specific, already-dead connection
  /// instance, even if the same peer has since reconnected as a new one.
  static const connectionClosed = 'CONNECTION_CLOSED';

  /// The requested [PearMethod] has no handler.
  static const unknownMethod = 'UNKNOWN_METHOD';

  /// Raised by [PearMethod.debugForceError] for RPC error-path testing.
  static const forcedError = 'FORCED_ERROR';

  /// A call's [PearRpcDefaults.callTimeout] elapsed with no response.
  static const rpcTimeout = 'RPC_TIMEOUT';

  /// The call was still pending when [PearRpc.dispose] ran.
  static const workletDisposed = 'WORKLET_DISPOSED';

  /// The frame never reached the worklet at all (e.g. it wasn't running) —
  /// distinct from [rpcTimeout], where the frame was sent but nothing came
  /// back.
  static const sendFailed = 'SEND_FAILED';

  /// A worklet-side storage operation failed — first thrown by
  /// [PearMethod.bulkWriteFile] (E4.4) when writing to its own storage
  /// fails; E5's Corestore/Hypercore data-structure wrappers are expected
  /// to reuse it too.
  static const storageUnavailable = 'STORAGE_UNAVAILABLE';

  /// [PearMethod.attachInfo] kept reporting a bundle version that didn't
  /// match this package's shipped one even after one kill+restart attempt —
  /// the bundled asset itself is stale (someone forgot to re-run `dart run
  /// flutter_pear:pack`). Synthesized on the Dart side; never sent by the
  /// worklet.
  static const bundleVersionMismatch = 'BUNDLE_VERSION_MISMATCH';

  /// The worklet crashed (or its IPC otherwise ended unexpectedly) while
  /// this call was still pending -- it will never be answered. Synthesized
  /// on the Dart side by [PearRpc] in response to [PearEventName.workletCrash]
  /// or `WorkletIpc.onCrash`; never sent by the worklet as an `err.code`
  /// itself (a crashed worklet reports via the event, not a response).
  static const workletCrashed = 'WORKLET_CRASHED';

  /// [PearSwarmState.failed] reason: `PearSwarm.join`'s bounded
  /// discovery/connect timeout (`PearSwarmDefaults.joinTimeout`) elapsed
  /// with no peer connection ever established. Synthesized entirely on the
  /// Dart side by `PearSwarm` — the worklet never sends this code. This is
  /// what GUARANTEES a bounded [PearSwarmState.failed] regardless of
  /// whether the worklet ever manages to classify why (see [udpBlocked]).
  static const connectTimeout = 'CONNECT_TIMEOUT';

  /// [PearSwarmState.failed] reason: the worklet's best-effort guess that
  /// UDP is blocked on this network (a common cause of P2P discovery never
  /// finding a peer, e.g. some carrier/enterprise NATs) — see pear-end's
  /// swarm error handling. Not a certainty, unlike [connectTimeout].
  static const udpBlocked = 'UDP_BLOCKED';

  /// [PearMethod.coreGet] targeted an index at or past the core's current
  /// length (E5.2). Distinct from waiting on a not-yet-replicated remote
  /// block: this is a bound this version of the API never waits past.
  static const indexOutOfRange = 'INDEX_OUT_OF_RANGE';

  /// [PearMethod.coreAppend], [PearMethod.coreGet], or
  /// [PearMethod.coreReplicate] targeted a core [PearMethod.coreClose] has
  /// already closed (E5.2).
  static const coreClosed = 'CORE_CLOSED';

  /// A `p.key` in [PearMethod.coreAppend], [PearMethod.coreGet],
  /// [PearMethod.coreReplicate], or [PearMethod.coreClose] doesn't match any
  /// core this worklet generation has opened via [PearMethod.storeGet]
  /// (E5.2) — analogous to [unknownPeer].
  static const unknownCore = 'UNKNOWN_CORE';

  /// A `p.bee` in [PearMethod.beeGet], [PearMethod.beePut],
  /// [PearMethod.beeDel], [PearMethod.beeRange], [PearMethod.beeWatch],
  /// [PearMethod.beeUnwatch], or [PearMethod.beeClose] doesn't match any
  /// bee this worklet generation has opened via [PearMethod.beeOpen]
  /// (E5.3) — analogous to [unknownCore].
  static const unknownBee = 'UNKNOWN_BEE';

  /// A [PearMethod.beeGet]/[PearMethod.beePut]/[PearMethod.beeDel]/
  /// [PearMethod.beeRange]/[PearMethod.beeWatch] targeted a bee
  /// [PearMethod.beeClose] already closed (E5.3) — analogous to
  /// [coreClosed].
  static const beeClosed = 'BEE_CLOSED';

  /// A `p.drive` in [PearMethod.drivePut], [PearMethod.driveGet],
  /// [PearMethod.driveExists], [PearMethod.driveDelete],
  /// [PearMethod.driveList], [PearMethod.driveReplicate],
  /// [PearMethod.driveMirrorToDisk], or [PearMethod.driveClose] doesn't
  /// match any drive this worklet generation has opened via
  /// [PearMethod.driveOpen] (E5.5) — analogous to [unknownBee].
  static const unknownDrive = 'UNKNOWN_DRIVE';

  /// A drive call targeted a drive [PearMethod.driveClose] already closed
  /// (E5.5) — analogous to [beeClosed].
  static const driveClosed = 'DRIVE_CLOSED';

  /// [PearMethod.driveGet] targeted a virtual path with no entry in the
  /// drive (E5.5).
  static const fileNotFound = 'FILE_NOT_FOUND';

  /// [PearMethod.pairingAcceptInvite]'s invite bytes failed to decode, or
  /// failed to open with the invite's own key (garbage/corrupted invite,
  /// E5.6).
  static const invalidInvite = 'INVALID_INVITE';

  /// [PearMethod.pairingAcceptInvite] targeted an invite past its
  /// `expiresAt` (E5.6). Enforced by this wrapper, not by blind-pairing
  /// itself — see `PearPairing.createInvite`'s doc for why.
  static const inviteExpired = 'INVITE_EXPIRED';

  /// [PearMethod.pairingAcceptInvite]'s bound elapsed with nobody ever
  /// confirming — covers both a genuinely slow/absent inviter and a
  /// revoked invite, which never confirms either (E5.6).
  static const pairingTimeout = 'PAIRING_TIMEOUT';

  /// A `p.inviteId` in [PearMethod.pairingConfirmCandidate] doesn't match
  /// any invite this worklet generation created via
  /// [PearMethod.pairingCreateInvite] (E5.6) — analogous to [unknownCore].
  /// [PearMethod.pairingRevoke] does NOT throw this for an unknown id —
  /// see [PearInvite.revoke]'s doc — revoke is idempotent, like every other
  /// wrapper's `close()`.
  static const unknownInvite = 'UNKNOWN_INVITE';

  /// A `p.candidateId` in [PearMethod.pairingConfirmCandidate] doesn't
  /// match any candidate currently pending on that invite (E5.6) —
  /// e.g. already confirmed, or never existed.
  static const unknownCandidate = 'UNKNOWN_CANDIDATE';

  /// An E5.6 pairing call failed for a reason none of the more specific
  /// codes above cover (e.g. blind-pairing/Protomux internals rejecting a
  /// malformed confirm key) — the pairing-wrapper analog of
  /// [storageUnavailable] for the storage-category wrappers, but
  /// categorized [PearErrorCategory.connection] since a pairing failure
  /// isn't a storage-substrate issue.
  static const pairingFailed = 'PAIRING_FAILED';

  /// An Autobase recipe's `apply` (E5.7) rejected an op it couldn't
  /// interpret (wrong shape, unknown `type`, a `del` referencing tags of
  /// the wrong encoding, ...). Thrown before mutating the recipe's view,
  /// never after — a malformed op is a typed failure, not silent
  /// corruption of shared multi-writer state.
  static const malformedOp = 'MALFORMED_OP';

  /// [PearMethod.baseOpen]'s `p.recipe` doesn't match any name pear-end's
  /// recipes module (E5.7) exports — i.e. not one of [PearRecipe]'s
  /// members. Reaching Dart at all means the typed [PearRecipe] enum was
  /// bypassed (a raw RPC call, or a future schema drift) — E5.8.
  static const unknownRecipe = 'UNKNOWN_RECIPE';

  /// A `p.base` in [PearMethod.baseAppend]/[PearMethod.baseGet]/
  /// [PearMethod.baseRange]/[PearMethod.baseWatch]/[PearMethod.baseUnwatch]/
  /// [PearMethod.baseClose] doesn't match any base this worklet generation
  /// has opened via [PearMethod.baseOpen] (E5.8) — analogous to
  /// [unknownBee].
  static const unknownBase = 'UNKNOWN_BASE';

  /// A base call targeted a base [PearMethod.baseClose] already closed
  /// (E5.8) — analogous to [beeClosed].
  static const baseClosed = 'BASE_CLOSED';

  /// The explicit err.code -> exception-category registry (LOCKED: entries
  /// only, no prefix/substring heuristics). A code not listed here —
  /// including one this version of the schema simply doesn't know about
  /// yet — falls back to the base `PearException` rather than guessing.
  static const categories = <String, PearErrorCategory>{
    unknownPeer: PearErrorCategory.connection,
    connectionClosed: PearErrorCategory.connection,
    storageUnavailable: PearErrorCategory.storage,
    connectTimeout: PearErrorCategory.connection,
    udpBlocked: PearErrorCategory.connection,
    indexOutOfRange: PearErrorCategory.storage,
    coreClosed: PearErrorCategory.storage,
    unknownCore: PearErrorCategory.storage,
    unknownBee: PearErrorCategory.storage,
    beeClosed: PearErrorCategory.storage,
    unknownDrive: PearErrorCategory.storage,
    driveClosed: PearErrorCategory.storage,
    fileNotFound: PearErrorCategory.storage,
    invalidInvite: PearErrorCategory.connection,
    inviteExpired: PearErrorCategory.connection,
    pairingTimeout: PearErrorCategory.connection,
    unknownInvite: PearErrorCategory.connection,
    unknownCandidate: PearErrorCategory.connection,
    pairingFailed: PearErrorCategory.connection,
    malformedOp: PearErrorCategory.storage,
    unknownRecipe: PearErrorCategory.storage,
    unknownBase: PearErrorCategory.storage,
    baseClosed: PearErrorCategory.storage,
  };
}

/// Runtime policy defaults for `PearSwarm` — Dart-side only, like
/// [PearRpcDefaults].
abstract final class PearSwarmDefaults {
  /// How long `PearSwarm.join` waits to reach [PearSwarmState.connected]
  /// before giving up and reporting [PearSwarmState.failed] with
  /// [PearErrorCode.connectTimeout]. Overridable per call. This is what
  /// makes an unreachable network (e.g. UDP blocked by a NAT) an honest,
  /// bounded failure instead of an infinite silent wait.
  static const joinTimeout = Duration(seconds: 30);
}

/// Runtime policy defaults. Unlike the rest of this file, these aren't part
/// of the wire protocol (the worklet never sees them) — just Dart-side
/// [PearRpc] behavior that happens to live alongside the schema it configures.
abstract final class PearRpcDefaults {
  /// How long [PearRpc.call] waits for a response before failing with
  /// [PearErrorCode.rpcTimeout]. Overridable per call.
  static const callTimeout = Duration(seconds: 10);

  /// How long `Pear.start`'s [PearMethod.attachInfo] health probe waits
  /// before giving up on an ALREADY-RUNNING worklet it just reattached to
  /// (E6.3, see `BareWorklet.reattached`) — deliberately shorter than
  /// [callTimeout], so a genuinely unresponsive reattached worklet is
  /// detected quickly and a fresh boot is taken instead of every hot
  /// restart waiting out the full default call timeout first. Scoped
  /// specifically to that reattach case: a worklet known to have just
  /// cold-booted (a first-ever launch, or the mandatory retry after a
  /// kill) uses the normal [callTimeout] instead — real JS engine + native
  /// module init legitimately takes real time, and applying this shorter
  /// bound there too would make `Pear.start` fail forever on a device
  /// merely slow to cold-boot, not one running anything unhealthy.
  static const attachHealthTimeout = Duration(seconds: 3);
}

/// The 1-byte IPC frame-type discriminator every frame is prefixed with.
///
/// [raw] has no reader yet — nothing sends it today (M3's bulk transport is
/// the first planned consumer) — but any frame carrying it, or an
/// unrecognized byte, is surfaced via [PearEventName.rpcDiagnostic] rather
/// than silently dropped, on both the Dart and pear-end sides.
abstract final class PearFrameType {
  /// A UTF-8 JSON control frame.
  static const json = 0x00;

  /// A raw binary payload frame (reserved for bulk transport, e.g. M3).
  static const raw = 0x01;
}

/// Session-handshake field names.
abstract final class PearHandshakeField {
  /// [PearMethod.attachInfo] response payload field: a random value
  /// generated once when the worklet boots, identifying this specific
  /// worklet process/generation.
  static const nonce = 'nonce';

  /// [PearMethod.attachInfo] response payload field: the pear-end bundle
  /// version (baked in at pack time by `pack.dart`), so a stale-bundle
  /// mismatch is diagnosable instead of failing with an unrelated
  /// method-not-found error somewhere else entirely.
  static const bundleVersion = 'bundleVersion';

  /// Envelope-level field (a sibling of `id`/`ev`/`ok`/`err`/`p`, NOT nested
  /// inside `p`) stamped by the worklet on EVERY frame it sends, carrying
  /// [nonce]'s value. Lets Dart drop a frame from a worklet generation it has
  /// since killed or replaced — including one already in flight when the
  /// kill happened, which arriving-before-the-new-attach alone wouldn't
  /// catch (LOCKED, see E2.5 audit note). Never present on Dart-to-worklet
  /// request frames — only the worklet stamps this.
  static const envelopeNonce = 'n';
}
