# E5.9 — Key persistence, backup & migration posture

**Pinned open question, resolved:** where do identity/replication keys live,
are they protected from silently leaking into Android's cloud backup, what
(if anything) survives an app reinstall or device migration, and can key
material ever end up in a log?

## Where keys live

Every Hypercore/Corestore keypair (including this device's own identity as
a writer, and every Hyperbee/Hyperdrive/Autobase structure built on top)
lives entirely inside the worklet's own Corestore storage, at
`<app files dir>/pear-corestore` (`pear-end/index.js`'s
`new Corestore(path.join(Bare.argv[0], 'pear-corestore'))`, where
`Bare.argv[0]` is `applicationContext.filesDir.absolutePath` — see
`FlutterPearBarePlugin.kt`'s own comment on that wiring). Bulk file
transfers (E5.5/E4.4) use a sibling directory, `<app files dir>/pear-bulk`.

Dart never sees a private key directly — the JS side generates and manages
all keypairs internally; only PUBLIC keys (as hex strings) ever cross the
RPC boundary into `PearKey` objects.

## Backup exclusion (v0.1 decision: EXCLUDE)

Both directories are excluded from Android's cloud backup and
device-to-device transfer, via `flutter_pear_bare`'s own
`android:dataExtractionRules` (API 31+) and `android:fullBackupContent`
(API 23-30) manifest attributes — see
`packages/flutter_pear_bare/android/src/main/res/xml/flutter_pear_data_extraction_rules.xml`
and its `full_backup_content` counterpart. This merges automatically into
any consuming app's manifest (no manual step), unless that app already sets
one of these attributes itself, in which case Gradle's manifest merger
surfaces a build-time conflict requiring `tools:replace` — a loud failure,
never a silent gap.

**Why exclude, not just accept the default:** an identity keypair silently
riding along in a cloud backup is a real, easy-to-miss security hole —
restoring that backup onto a different/compromised device would hand over
this device's P2P identity along with it. Excluding it is the conservative,
correct default; `android:allowBackup="false"` (disabling backup for the
WHOLE app) was considered and rejected as too blunt an instrument for a
library to impose on its host app — that's the app developer's call to
make about their OWN data, not this library's to make for them.

**Verified by:** `packages/flutter_pear_bare/test/backup_rules_test.dart`
parses the manifest and both XML rule files with `package:xml` (so a
malformed-XML regression that would break the actual Android build, not
just a substring match, fails this test too) and cross-checks the
exclusion rules' directory names against `pear-end/index.js`'s actual
`Corestore`/`BULK_STORAGE_DIR` paths, so a future rename of either can't
silently drift the two out of sync. The device-level guarantee itself
(`bmgr backupnow` actually skipping these paths) is deferred to
`flutter_pear-doi`, per this project's standing hardware-validation-last
decision.

## What survives reinstall (v0.1 decision: NOTHING)

**Honest answer: uninstalling the app deletes everything that matters here.**
Android wipes an app's internal storage (`Context.getFilesDir()`, where
`pear-corestore`/`pear-bulk` live) on uninstall — this is standard OS
behavior, not something flutter_pear controls or could change even if it
wanted to. Verified on real hardware (`flutter_pear-doi`): with Android
Backup Manager enabled and an active backup for this app — not the default
state, but a real, reachable one — `pear-corestore` still never comes back,
even through the OS's own install-time auto-restore path (other,
non-identity files the app happened to write, e.g. plain preference files,
can survive that specific path; the identity/replication data governed by
this file's exclusion rules above cannot). That means:

- This device's own writer identity is gone and cannot be recovered.
- Every locally-held Hypercore/Hyperbee/Hyperdrive/Autobase replica is gone.
- A peer this device was previously admitted as a writer on (E5.8's
  `addWriter`) will NOT recognize a reinstalled app as the same writer —
  from every other peer's perspective, this is a brand-new, never-seen
  identity that would need to be re-admitted from scratch (there is no
  "restore my old identity" path in v0.1).

If your app needs identity/data to survive a reinstall or migrate to a new
device, you are responsible for your own backup/restore of whatever you
consider portable (e.g. exporting an invite, or your own
key-material-adjacent app data) — flutter_pear does not provide this in
v0.1, and this doc is the explicit record that "nothing survives" is a
decided posture, not an oversight.

## Invite TTL & replay (already resolved — E5.6)

Blind-pairing invites (`PearPairing.createInvite`) already carry an
optional `ttl`; an expired invite is rejected with a typed
`PearErrorCode.inviteExpired`, and a revoked invite blocks any further
`acceptInvite` from ever completing (bounded by that call's own timeout) —
see `pairing.dart`'s own dartdoc and `pairing_test.dart`'s
revoke/expiry/timeout coverage. No new decision needed here; referenced for
completeness since this ticket's own pinned question bundled it in.

## Logging hygiene (v0.1 decision: zero-tolerance, enforced by a test)

**Decision: no `print()`/`debugPrint()` call anywhere in flutter_pear's own
Dart source, and no `console.*` call anywhere in pear-end's own JS source
— at all, regardless of whether a given call site would touch key
material.** A library printing to the app's console is already an
unwanted side effect independent of key safety; banning it outright is far
simpler to keep true than auditing every individual call site for whether
it happens to touch something sensitive.

Enforced by `packages/flutter_pear/test/log_hygiene_test.dart` — a
grep-able assertion (plain text scanning, not a static analyzer) that
scans every `.dart` file under `lib/` and every top-level `.js` file under
`pear-end/` for `print(`/`debugPrint(`/`console.` and fails the build if
any exist. As of this ticket, both scans are already clean; the test's
value is catching a FUTURE accidental debug print before it ships, not
fixing an existing one.

As defense-in-depth (not a substitute for the test above): `PearKey.toString()`
already truncates to the first 8 hex characters (`PearKey(a1b2c3d4…)`), so
even a future `'$key'` string interpolation slipping past the log-hygiene
test would only ever expose 4 of the 32 key bytes, never the full key.

## Cross-references

- `packages/flutter_pear_bare/android/src/main/res/xml/flutter_pear_data_extraction_rules.xml` / `flutter_pear_full_backup_content.xml` — the actual exclusion rules.
- `packages/flutter_pear_bare/test/backup_rules_test.dart` — keeps them in sync with `index.js`.
- `packages/flutter_pear/test/log_hygiene_test.dart` — the log-hygiene guardrail.
- `PearKey`, `PearPairing` (`lib/src/crypto.dart`, `lib/src/pairing.dart`) — carry pointers to this doc in their dartdoc.
- Logged in `~/.gstack/projects/andrewloable-flutter_pear/decisions.jsonl`
  (kind: `decide`) alongside this project's other pinned-question
  resolutions.
- `flutter_pear-doi` — the deferred on-device `bmgr backupnow` verification.
