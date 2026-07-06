# fresh_android upgrade fixture

D15 upgrade-reliability fixture: a `flutter create`d app, **outside** the
melos workspace (`melos.yaml`'s `packages/*` glob never sees this
directory), that adds `flutter_pear` from **hosted pub.dev only** -- never a
`path:` dependency -- and proves the whole real-world path a new app dev
would take: create app -> `flutter pub add flutter_pear` -> build -> install
-> launch -> `Pear.start()` handshake succeeds.

## Purpose

Precondition for the v0.2.0 release (DX2 decision 56): the prerelease
`0.2.0-dev.1` cohort must pass this fixture on real hosted pub.dev archives
before stable `0.2.0` ships. `check_pins.dart` / `pack.dart` only prove the
*plugin repo* is internally consistent; this fixture proves a *consumer* can
actually install and run it.

## Commands

```bash
cd upgrade_fixtures/fresh_android
FLUTTER_PEAR_VERSION=0.2.0-dev.1 ADB_SERIAL=192.168.0.251:5555 ./run_check.sh
```

- `FLUTTER_PEAR_VERSION` (default `0.2.0-dev.1`): version constraint added as
  `flutter_pear:^$FLUTTER_PEAR_VERSION` via `flutter pub add`, matching DX2
  decision 46's exact upgrade command (a bare `pub upgrade` cannot cross the
  `^0.0.1` caret already published for v0.1).
- `ADB_SERIAL` (optional): passed as `adb -s $ADB_SERIAL` for every adb call.
  If unset, whichever single device/emulator `adb` already sees is used.

## Device prerequisites

A device or emulator already visible to `adb devices`, matching this repo's
"already-running emulator/device" TTHW precondition (see
`packages/flutter_pear/tool/fresh_machine_check.sh`) -- this fixture does
not boot one itself. An AVD emulator (e.g. `Medium_Phone_API_35`) is an
accepted substitute for physical hardware in this dev environment, the same
standing decision already applied to `flutter_pear-doi`. Verified end to end
on `emulator-5554` (arm64 system image) 2026-07-07; the one physical Android
device otherwise reachable here (a BYD DiLink automotive head unit at
`192.168.0.251:5555`) is a different project's hardware and known
incompatible with `flutter_pear_bare` for an unrelated ROM-level
`libnativehelper.so` linker restriction (see `flutter_pear-ovt.1.8`) -- do
not use it for this fixture.

## What a T4 pass means

`run_check.sh` exits `0` and prints `FIXTURE RESULT: ATTACHED`: the
requested `flutter_pear` version resolved from hosted pub.dev, the app
built and installed, and `Pear.start()` completed a real handshake on the
device (confirmed via the `FLUTTER_PEAR_FIXTURE_ATTACHED` logcat marker).

If the requested version isn't hosted yet, the script prints
`WAITING-FOR-HOSTED-ARCHIVE` and exits `2` -- this is a precondition gap
(the prerelease hasn't been published), not a fixture or plugin failure;
`release_gate.sh` is responsible for sequencing publish-then-verify so this
never blocks on a race.

## Rule

No `flutter_pear`-specific manual step is permitted. If a real T4 run needs
a manual workaround beyond running `run_check.sh`, that is itself a release
blocker to fix in the plugin or this fixture, not a step to document here.
