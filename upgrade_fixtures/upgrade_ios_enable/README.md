# upgrade_ios_enable upgrade fixture

D15 upgrade-reliability fixture: a **locked, Android-only v0.1 consumer**
(`flutter_pear: 0.0.1` pinned exactly, `pubspec.lock` committed, **no
committed `ios/`**) that then runs the documented upgrade-and-enable-iOS
recipe **verbatim, step by step** -- so a wording change in that recipe
breaks this script instead of silently drifting out of sync.

This directory lives **outside** the melos workspace -- `melos.yaml`'s
`packages/*` glob never sees it -- and depends on `flutter_pear` from
**hosted pub.dev only**, never a `path:` dependency.

## Recipe provenance and KNOWN GAP

The recipe (plan F1/D18, DX2 decision 46), each step in `run_check.sh`
annotated with its source:

1. `flutter create --platforms=ios .` -- Flutter-standard, not
   `flutter_pear`-specific.
2. `dart pub add flutter_pear:^$FLUTTER_PEAR_VERSION` -- DX2 decision 46 (a
   bare `pub upgrade` cannot cross the already-published `^0.0.1` caret).
3-4. Paste the `NSLocalNetworkUsageDescription` Info.plist block --
   **PLACEHOLDER**, not the doc-prescribed copy-paste text.
   `flutter_pear-ovt.6` (the docs epic) and its prerequisite
   `flutter_pear-ovt.1.12` (the TCC spike that determines the real required
   Info.plist key(s)/wording) have not landed as of this writing
   (2026-07-07). Flagged `bd human` on `flutter_pear-ovt.5.11` -- swap in
   the real block and update the doc-source comment in `run_check.sh` once
   it ships.
5. `flutter run` on a simulator -- Flutter-standard.

## Commands

```bash
cd upgrade_fixtures/upgrade_ios_enable

# leg 1 alone: prove the locked, Android-only 0.0.1 base itself builds.
./run_check.sh --locked-only

# both legs: leg 1, then the real upgrade-and-enable-iOS recipe (leg 2).
FLUTTER_PEAR_VERSION=0.2.0-dev.1 ./run_check.sh
```

- `FLUTTER_PEAR_VERSION` (default `0.2.0-dev.1`): leg 2's upgrade target.
- No `ADB_SERIAL`-equivalent env var for leg 2's simulator run: the script
  always locates an already-booted iPhone simulator if one exists, else
  boots the first available one itself (and shuts it back down on exit
  only if it booted it).
- `ios/` is `.gitignore`d in this fixture -- leg 2 generates it locally via
  `flutter create --platforms=ios .`, and it must never be committed.

## What a T4 pass means

- **Today** (leg 1 / `--locked-only`): the locked, Android-only 0.0.1 base
  itself is sound and buildable -- verifiable now, and a precondition for
  trusting leg 2's result later.
- **At T4** (both legs, once the docs epic's real recipe replaces the
  placeholder): `run_check.sh` exits `0` and prints
  `FIXTURE RESULT: ATTACHED (upgraded-and-enabled-iOS to ...)` -- the
  recipe's every step succeeded verbatim and the simulator reached a real
  `Pear.start()` handshake.

If the requested version isn't hosted yet, leg 2 prints
`WAITING-FOR-HOSTED-ARCHIVE` and exits `2` -- a precondition gap, not a
fixture or plugin failure.

## Rule

No `flutter_pear`-specific manual step is permitted beyond the documented
recipe itself (once the real recipe ships). If a real T4 run needs a manual
workaround beyond running `run_check.sh`, that is itself a release blocker
to fix in the plugin, the docs, or this fixture -- not a step to document
here.
