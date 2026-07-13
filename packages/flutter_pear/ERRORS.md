# E8.3 — Error catalog

Every `err.code` a `PearException` can carry, documented as problem / cause
/ fix. This is the same text `PearErrorCatalog`
(`lib/src/error_catalog.dart`) renders into `PearException.toString()` — a
consistency test (`test/error_catalog_test.dart`) keeps this file and that
catalog from drifting apart, in both directions.

Anchors below are explicit `<a id="...">` tags, not derived heading slugs —
they're guaranteed stable regardless of which Markdown renderer displays
this file (GitHub, pub.dev, a local viewer, ...).

## Connection / discovery

<a id="UNKNOWN_PEER"></a>
### UNKNOWN_PEER

- **Problem:** Tried to write to a peer that has no open connection.
- **Cause:** The connection to that peer already closed (the peer
  disconnected, reconnected as a new `PearConnection`, or the connection was
  never established) before this write reached the worklet.
- **Fix:** Don't hold onto a `PearConnection` past its own data stream
  closing — get the new `PearConnection` from `PearSwarm.connections`
  instead of reusing an old one.

<a id="CONNECTION_CLOSED"></a>
### CONNECTION_CLOSED

- **Problem:** Called `write()` on a `PearConnection` that has already
  closed.
- **Cause:** The connection dropped (peer disconnected, network change,
  etc.) — a `PearConnection` is ephemeral and never revives once closed
  (see `RECONNECT_CONTRACT.md`).
- **Fix:** Stop writing to this object; if the same peer reconnects, a
  brand-new `PearConnection` arrives on `PearSwarm.connections` — write to
  that one instead.

<a id="CONNECT_TIMEOUT"></a>
### CONNECT_TIMEOUT

- **Problem:** `PearSwarm.join` never found and connected to a peer within
  its timeout.
- **Cause:** No peer joined the same topic, or network conditions
  (NAT/firewall) prevented discovery or connection.
- **Fix:** Confirm both peers are using the exact same topic bytes; if this
  happens consistently, also check for `UDP_BLOCKED`.

<a id="UDP_BLOCKED"></a>
### UDP_BLOCKED

- **Problem:** The worklet's best-effort guess that UDP is blocked on this
  network.
- **Cause:** Some carrier/enterprise NATs and firewalls block the UDP
  traffic Hyperswarm's DHT needs.
- **Fix:** Try a different network (e.g. switch off a restrictive Wi-Fi/
  VPN) — this is a network-environment issue, not something flutter_pear
  can work around.

## RPC / worklet lifecycle

<a id="UNKNOWN_METHOD"></a>
### UNKNOWN_METHOD

- **Problem:** The worklet doesn't recognize the RPC method that was
  called.
- **Cause:** Almost always a version skew between the Dart plugin and the
  bundled pear-end JS (e.g. a stale `assets/pear-end.bundle` after a plugin
  upgrade).
- **Fix:** Run `dart run flutter_pear:pack` to rebuild the bundle, or
  update flutter_pear so the Dart and JS sides agree on the schema again.

<a id="FORCED_ERROR"></a>
### FORCED_ERROR

- **Problem:** This is a deliberately-raised test error, not a real
  failure.
- **Cause:** Something called the debug/force-error RPC hook to exercise
  the error path — flutter_pear's own tests use this.
- **Fix:** Nothing to fix — if you're seeing this outside of flutter_pear's
  own tests, check what's calling the force-error hook.

<a id="RPC_TIMEOUT"></a>
### RPC_TIMEOUT

- **Problem:** An RPC call to the worklet never got a response within its
  timeout.
- **Cause:** The worklet is slow, stuck, or the call's timeout is too short
  for what it was doing (e.g. a large replicate/mirror operation).
- **Fix:** Pass a longer `timeout` for long-running calls; otherwise check
  `Pear.worklet.onCrash` for why the worklet might be stuck.

<a id="WORKLET_DISPOSED"></a>
### WORKLET_DISPOSED

- **Problem:** A call was still in flight when the `Pear` instance was
  disposed.
- **Cause:** Your app called `pear.dispose()` (or a wrapper close/dispose)
  before an in-flight call finished.
- **Fix:** Await or cancel pending calls before disposing, or treat this as
  an expected shutdown race and ignore it.

<a id="SEND_FAILED"></a>
### SEND_FAILED

- **Problem:** A request never reached the worklet at all.
- **Cause:** The worklet wasn't running (already stopped or crashed) when
  the call tried to send.
- **Fix:** Make sure `Pear.start()` has completed, and the worklet hasn't
  crashed (check `Pear.worklet.onCrash`), before issuing calls.

<a id="BUNDLE_VERSION_MISMATCH"></a>
### BUNDLE_VERSION_MISMATCH

- **Problem:** The bundled pear-end JS doesn't match the version this
  plugin expects.
- **Cause:** `assets/pear-end.bundle` is stale — `pear-end/` (or the pinned
  Bare Kit version) changed without re-running the pack step.
- **Fix:** Run `dart run flutter_pear:pack` from the flutter_pear package
  to rebuild and re-pin the bundle, then rebuild your app.

<a id="WORKLET_CRASHED"></a>
### WORKLET_CRASHED

- **Problem:** The worklet crashed (or its IPC connection ended) while a
  call was pending.
- **Cause:** An uncaught JS exception or native failure inside the Bare
  worklet.
- **Fix:** Listen to `Pear.worklet.onCrash` for the underlying reason and restart
  via `Pear.start()` again; file an issue if the crash looks like a bug in
  flutter_pear itself.

<a id="BARE_RUNTIME_MISSING"></a>
### BARE_RUNTIME_MISSING

- **Problem:** The `bare` runtime could not be resolved on this desktop
  machine, so `Pear.start()` could not boot a worklet at all.
- **Cause:** macOS, Linux, and Windows desktop hosts run pear-end as a
  real `bare` subprocess -- unlike mobile, there is no linked-in runtime.
  As of desktop, each host fetches its own `bare` automatically on first
  launch (checksum-verified, then cached) instead of requiring a manual
  install, so this should now be rare -- it means the fetch itself failed
  (e.g. no network on this machine's first launch) *and* no `bare` was
  found on `PATH` either.
- **Fix:** Check your network connection and restart the app to retry the
  fetch; as a manual fallback, install the Bare runtime globally with
  `npm i -g bare` and restart. **Platform note:** on Windows specifically,
  this exact scenario (fetch failed, nothing on `PATH`) currently surfaces
  as [`WORKLET_CRASHED`](#WORKLET_CRASHED) instead of this code -- the
  clean pre-flight check that produces `BARE_RUNTIME_MISSING` is
  implemented on macOS and Linux only today.

## Storage (Corestore / Hypercore / Hyperbee / Hyperdrive / Autobase)

<a id="STORAGE_UNAVAILABLE"></a>
### STORAGE_UNAVAILABLE

- **Problem:** A storage operation (Corestore, Hypercore, bulk file write,
  ...) failed on the worklet side.
- **Cause:** The underlying filesystem/storage layer rejected the operation
  (disk full, permissions, a corrupted store, ...).
- **Fix:** Check the device's available storage and that the app has write
  access to its own files directory — `.details` usually names the
  specific failure.

<a id="INDEX_OUT_OF_RANGE"></a>
### INDEX_OUT_OF_RANGE

- **Problem:** `PearCore.get` was asked for an index at or past the core's
  current length.
- **Cause:** The caller requested a block that hasn't been appended
  (locally or by a peer) yet.
- **Fix:** Check `PearCore.length` (or wait for a peer append to
  replicate) before calling `get()` with that index.

<a id="CORE_CLOSED"></a>
### CORE_CLOSED

- **Problem:** A call targeted a `PearCore` that has already been closed.
- **Cause:** `PearCore.close()` already ran before this call.
- **Fix:** Don't call methods on a `PearCore` after closing it — re-open
  via `PearStore.get()` if you need it again.

<a id="UNKNOWN_CORE"></a>
### UNKNOWN_CORE

- **Problem:** A call referenced a core key this worklet generation never
  opened.
- **Cause:** Usually a stale key held across a hot restart/worklet-
  generation change, or a typo'd key.
- **Fix:** Re-open the core via `PearStore.get()` in the current worklet
  generation before using it.

<a id="UNKNOWN_BEE"></a>
### UNKNOWN_BEE

- **Problem:** A call referenced a Hyperbee this worklet generation never
  opened.
- **Cause:** A stale reference held across a worklet restart, or a typo'd
  key.
- **Fix:** Re-open via `PearBee.open()` in the current worklet generation
  before using it.

<a id="BEE_CLOSED"></a>
### BEE_CLOSED

- **Problem:** A call targeted a `PearBee` that has already been closed.
- **Cause:** `PearBee.close()` already ran before this call.
- **Fix:** Don't call methods on a `PearBee` after closing it — re-open via
  `PearBee.open()` if you need it again.

<a id="UNKNOWN_DRIVE"></a>
### UNKNOWN_DRIVE

- **Problem:** A call referenced a Hyperdrive this worklet generation never
  opened.
- **Cause:** A stale reference held across a worklet restart, or a typo'd
  key.
- **Fix:** Re-open via `PearDrive.open()` in the current worklet generation
  before using it.

<a id="DRIVE_CLOSED"></a>
### DRIVE_CLOSED

- **Problem:** A call targeted a `PearDrive` that has already been closed.
- **Cause:** `PearDrive.close()` already ran before this call.
- **Fix:** Don't call methods on a `PearDrive` after closing it — re-open
  via `PearDrive.open()` if you need it again.

<a id="FILE_NOT_FOUND"></a>
### FILE_NOT_FOUND

- **Problem:** `PearDrive.get` targeted a path with no entry in the drive.
- **Cause:** Nothing has been `put()` at that path (locally or replicated
  from a peer) yet.
- **Fix:** Check `PearDrive.exists()` first, and that the path matches
  exactly what the writer `put()` — drive paths are case-sensitive.

### `PearDrive.mirrorToDisk` silently-rejected entries (not an error code)

Not a `PearException` — `mirrorToDisk` still succeeds, but some entries
from the source drive may not have been written:

- **Problem:** A file you expected `mirrorToDisk` to write never showed up
  in the destination directory, with no exception thrown.
- **Cause:** Zip-slip hardening — the worklet rejects, instead of writing,
  any entry that was either a symlink from the source drive
  (`'symlink-rejected'`, rejected unconditionally regardless of its target)
  or whose resolved destination path wasn't strictly inside the mirror
  directory (`'path-escape'`). Both are only possible from an untrusted
  peer's drive; your own writes never trigger this.
- **Fix:** Check `PearDriveMirrorResult.rejected` (nonzero means something
  was skipped) and subscribe to `PearDrive.mirrorWarnings` for the
  per-entry `{path, reason}` detail — see `doc/troubleshooting.md` for a
  walked-through example.

<a id="MALFORMED_OP"></a>
### MALFORMED_OP

- **Problem:** An Autobase recipe rejected an operation it could not
  interpret.
- **Cause:** The op's shape doesn't match what the chosen `PearRecipe`
  (lww/orderedLog/crdtMap) expects — e.g. a `del` referencing the wrong tag
  encoding.
- **Fix:** Check the exact op shape your `PearRecipe` expects, and that
  you're not mixing operations meant for a different recipe.

<a id="UNKNOWN_RECIPE"></a>
### UNKNOWN_RECIPE

- **Problem:** `PearBase.open`'s recipe name doesn't match any recipe
  pear-end exports.
- **Cause:** `PearBase.open`'s typed API only ever accepts a real
  `PearRecipe` enum value, so normal usage can't trigger this — reaching it
  means the typed enum was bypassed entirely (a raw RPC call) or the Dart
  plugin and bundled pear-end JS have drifted out of sync on recipe names.
- **Fix:** If you're calling `PearBase.open(recipe: ...)` normally, this
  points to a version mismatch — try `dart run flutter_pear:pack` to
  rebuild the bundle. If you're making a raw RPC call, use one of the
  `PearRecipe` enum's own values (lww/orderedLog/crdtMap) instead.

<a id="UNKNOWN_BASE"></a>
### UNKNOWN_BASE

- **Problem:** A call referenced an Autobase this worklet generation never
  opened.
- **Cause:** A stale reference held across a worklet restart, or a typo'd
  key.
- **Fix:** Re-open via `PearBase.open()` in the current worklet generation
  before using it.

<a id="BASE_CLOSED"></a>
### BASE_CLOSED

- **Problem:** A call targeted a `PearBase` that has already been closed.
- **Cause:** `PearBase.close()` already ran before this call.
- **Fix:** Don't call methods on a `PearBase` after closing it — re-open
  via `PearBase.open()` if you need it again.

## Pairing (blind pairing / invites)

<a id="INVALID_INVITE"></a>
### INVALID_INVITE

- **Problem:** The invite bytes passed to `acceptInvite` could not be
  decoded.
- **Cause:** The bytes are corrupted, truncated, or aren't a real
  flutter_pear invite at all (e.g. pasted or scanned incorrectly).
- **Fix:** Re-share the invite (re-scan the QR code or re-copy the bytes)
  from `PearPairing.createInvite`'s output.

<a id="INVITE_EXPIRED"></a>
### INVITE_EXPIRED

- **Problem:** The invite passed to `acceptInvite` is past its own `ttl`.
- **Cause:** `PearPairing.createInvite` was called with a `ttl`, and more
  time than that has passed.
- **Fix:** Create a fresh invite by calling `createInvite` again; if this
  happens often, consider a longer `ttl`.

<a id="PAIRING_TIMEOUT"></a>
### PAIRING_TIMEOUT

- **Problem:** `acceptInvite`'s bound elapsed with nobody confirming.
- **Cause:** Either the inviter is genuinely slow/offline, or the invite
  was revoked — a revoked invite never confirms either.
- **Fix:** Confirm the inviter's device is online and still listening on
  `PearInvite.candidates`; if revoked intentionally, this is expected.

<a id="UNKNOWN_INVITE"></a>
### UNKNOWN_INVITE

- **Problem:** A call referenced an invite id this worklet generation never
  created.
- **Cause:** A stale invite id held across a worklet restart, or
  confirming/revoking an invite from a different generation.
- **Fix:** Create a new invite via `PearPairing.createInvite` in the
  current worklet generation.

<a id="UNKNOWN_CANDIDATE"></a>
### UNKNOWN_CANDIDATE

- **Problem:** A call referenced a pairing candidate that is not currently
  pending on that invite.
- **Cause:** The candidate already confirmed, or never existed (a stale or
  duplicate confirm call).
- **Fix:** Only call `PearPairingCandidate.confirm` once per candidate,
  using the candidate from the most recent `PearInvite.candidates` event.

<a id="PAIRING_FAILED"></a>
### PAIRING_FAILED

- **Problem:** A pairing call failed for a reason none of the more
  specific pairing codes cover.
- **Cause:** An internal blind-pairing/Protomux failure — e.g. a malformed
  confirm key.
- **Fix:** Check `.details` for the underlying JS error; if it looks like a
  flutter_pear bug, file an issue with the details attached.

## iOS-specific notes

These aren't `PearErrorCode`s (no code, no catalog entry) -- they're
failure modes worth landing on this page anyway, since a dev debugging an
iOS-specific problem often starts here first.

### A custom worklet bundle fails to boot on iOS with no useful RPC error

If you built a **custom** pear-end bundle yourself (`BareWorklet
.start(customBundle)`, the documented advanced escape hatch -- see the root
README) and it fails to boot specifically on iOS while working fine on
Android, the most common cause is building it without iOS in `bare-pack`'s
own `--host` list. The default bundled pear-end is built via (`dart run
flutter_pear:pack`, `bin/pack.dart`'s `bundleHosts` constant):

```
bare-pack --linked --host android-arm64 --host android-x64 --host ios-arm64 --host ios-arm64-simulator --out <path> <entry>
```

Omit `--host ios-arm64`/`--host ios-arm64-simulator` and the resulting
bundle has no iOS-linked native addons at all -- on iOS this fails at
worklet boot, often before any RPC call can even complete, so it doesn't
surface as a clean, specific error: expect either `WORKLET_CRASHED` (via
`Pear.onCrash`) or an unexplained `RPC_TIMEOUT`/`CONNECT_TIMEOUT` on the
very first `attach.info` call, neither of which names the real cause on
its own.

**Fix:** rebuild your custom bundle with `--host ios-arm64 --host
ios-arm64-simulator` included alongside whatever Android hosts you need --
match `bin/pack.dart`'s `bundleHosts` constant for the exact, currently-
pinned host list this plugin's own default bundle uses.

### A file never arrives after `mirrorToDisk`, with no exception thrown

Not a `PearErrorCode` either -- it's a warning **event**,
`PearDrive.mirrorWarnings` (`PearEventName.driveMirrorWarning`,
`'drive.mirrorWarning'`), carrying `{path, reason}` where `reason` is
`'symlink-rejected'` or `'path-escape'` (a hostile entry in an untrusted
peer's drive, rejected per-entry rather than failing the whole call). See
[doc/troubleshooting.md's "A file never arrived after
`mirrorToDisk`"](doc/troubleshooting.md#a-file-never-arrived-after-mirrortodisk-with-no-exception-thrown)
for the full symptom-first writeup, including the exact code to listen for
it -- this cross-reference exists because a silently-missing file with no
exception at all is exactly the shape of problem someone comes to this
error catalog looking for first.

## Cross-references

- `packages/flutter_pear/lib/src/error_catalog.dart` — the Dart-side
  catalog this file mirrors, and what `PearException.toString()` actually
  renders.
- `packages/flutter_pear/test/error_catalog_test.dart` — the drift test
  keeping this file and the catalog in sync.
- `packages/flutter_pear/lib/src/schema.dart`'s `PearErrorCode` — the
  registry of code strings themselves (this file documents them, it
  doesn't define them).
