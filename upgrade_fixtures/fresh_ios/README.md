# fresh_ios upgrade fixture

D15 upgrade-reliability fixture: a `flutter create`d app, **outside** the
melos workspace (`melos.yaml`'s `packages/*` glob never sees this
directory), that adds `flutter_pear` from **hosted pub.dev only** -- never a
`path:` dependency -- and proves the whole real-world path a new iOS app dev
would take: create app -> `flutter pub add flutter_pear` -> run on a
simulator -> `Pear.start()` handshake succeeds.

## KNOWN GAP: the Info.plist block is a placeholder

`ios/Runner/Info.plist`'s `NSLocalNetworkUsageDescription` string is a
**placeholder**, not the doc-prescribed copy-paste block. The authoritative
recipe is planned to ship with `flutter_pear-ovt.6` (the docs epic), and
that doc itself depends on `flutter_pear-ovt.1.12`'s TCC spike (which
Info.plist key(s) iOS 14+ Local Network access actually requires, whether a
multicast entitlement or `NSBonjourServices` array is also needed) --
neither has landed as of this fixture's creation (2026-07-07). This fixture
proves harness integrity and failure detection today; the Info.plist step
must be swapped for the real recipe once it ships, and this is flagged
`bd human` on `flutter_pear-ovt.5.11` rather than silently guessed at as
final.

## Purpose

Precondition for the v0.2.0 release (DX2 decision 56): the prerelease
`0.2.0-dev.1` cohort must pass this fixture on real hosted pub.dev archives
before stable `0.2.0` ships.

## Commands

```bash
cd upgrade_fixtures/fresh_ios
FLUTTER_PEAR_VERSION=0.2.0-dev.1 ./run_check.sh
```

- `FLUTTER_PEAR_VERSION` (default `0.2.0-dev.1`): version constraint added as
  `flutter_pear:^$FLUTTER_PEAR_VERSION` via `flutter pub add`, matching DX2
  decision 46's exact upgrade command.
- No `ADB_SERIAL`-equivalent env var: the script always locates an already-
  booted iPhone simulator if one exists, else boots the first available one
  itself (and shuts it back down on exit only if it booted it).

## Simulator prerequisites

None beyond Xcode + at least one iOS simulator runtime installed (checked
via `xcrun simctl list devices available`) -- the script boots one itself if
none is already running.

## What a T4 pass means

`run_check.sh` exits `0` and prints `FIXTURE RESULT: ATTACHED`: the
requested `flutter_pear` version resolved from hosted pub.dev, the app ran
on the simulator, and `Pear.start()` completed a real handshake (confirmed
via the `FLUTTER_PEAR_FIXTURE_ATTACHED` marker in the captured `flutter run`
log).

## WAITING-FOR-HOSTED-ARCHIVE semantics

If the requested version isn't hosted yet, the script prints
`WAITING-FOR-HOSTED-ARCHIVE` and exits `2` -- a precondition gap (the
prerelease hasn't been published), not a fixture or plugin failure.
Hosted `flutter_pear` 0.0.1 ships **no iOS support at all**
(`flutter_pear_bare` 0.0.1 has no `ios/`) -- running this fixture with
`FLUTTER_PEAR_VERSION=0.0.1` is EXPECTED to resolve (0.0.1 is a real hosted
version) but then fail at the marker step with a clear
`MissingPluginException`/`FLUTTER_PEAR_FIXTURE_FAILED` in the captured log
rather than hanging. That captured, clearly-reported failure is this
fixture's proof that harness failure-detection works, not a regression.

## Rule

No `flutter_pear`-specific manual step is permitted beyond the documented
Info.plist paste (once the real recipe ships). If a real T4 run needs a
manual workaround beyond running `run_check.sh`, that is itself a release
blocker to fix in the plugin or this fixture, not a step to document here.
