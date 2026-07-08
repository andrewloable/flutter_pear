# fresh_ios upgrade fixture

D15 upgrade-reliability fixture: a `flutter create`d app, **outside** the
melos workspace (`melos.yaml`'s `packages/*` glob never sees this
directory), that adds `flutter_pear` from **hosted pub.dev only** -- never a
`path:` dependency -- and proves the whole real-world path a new iOS app dev
would take: create app -> `flutter pub add flutter_pear` -> run on a
simulator -> `Pear.start()` handshake succeeds.

## Info.plist provenance and remaining gap

`ios/Runner/Info.plist`'s `NSLocalNetworkUsageDescription` string is the
**real, shipped copy** from `packages/flutter_pear_example/ios/Runner/Info.plist`
(added by `flutter_pear-ovt.4.1`) -- not an invented placeholder.
`flutter_pear-ovt.1.12`'s closed FEAS-TCC spike confirmed it's technically
sufficient: only this one key is needed, with no `NSBonjourServices` array
and no `com.apple.developer.networking.multicast` entitlement (source-level
proof: Hyperswarm/hyperdht always gathers and offers this device's
LAN-local addresses during connection handshake, unconditionally, and
nothing in the stack ever uses multicast/broadcast/mDNS).

**Remaining gap**: no polished `flutter_pear-ovt.6` consumer-facing doc page
exists yet to formally *prescribe* this copy -- that epic hasn't started.
This fixture uses the shipped example app's string as the best available
real-world source today. Once the docs epic ships its own copy-paste block,
re-point this file and the comment above at it; if the wording differs,
update both to match rather than let them drift silently. Tracked on
`flutter_pear-ovt.5.11`.

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
