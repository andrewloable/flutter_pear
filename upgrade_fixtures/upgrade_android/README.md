# upgrade_android upgrade fixture

D15 upgrade-reliability fixture: a **locked v0.1 consumer**. Unlike
`fresh_android` (which always adds the latest constraint), this app pins
`flutter_pear: 0.0.1` exactly in `pubspec.yaml`, commits `pubspec.lock`, and
customizes `android/` like a real project -- so the bump-only upgrade path
(`dart pub add flutter_pear:^0.2.0-dev.1`, per DX2 decision 46; a bare
`pub upgrade` cannot cross the already-published `^0.0.1` caret) is proven
against something closer to a real consumer than a stock template.

This directory lives **outside** the melos workspace -- `melos.yaml`'s
`packages/*` glob never sees it -- and depends on `flutter_pear` from
**hosted pub.dev only**, never a `path:` dependency.

## Realistic customization (android/app/build.gradle.kts)

- Custom application ID: `com.fpfixture.upgrade_android` (not the
  `com.example.*` default).
- Non-default but supported `minSdk = 26` (Flutter's own template default,
  and flutter_pear_bare's stated floor, is 24).
- A custom `buildConfigField` (`FIXTURE_TAG`), requiring
  `buildFeatures { buildConfig = true }` -- a realistic "app already has its
  own Gradle customization" scenario the upgrade must survive.

## Commands

```bash
cd upgrade_fixtures/upgrade_android

# leg 1 alone: prove the locked 0.0.1 state itself builds, installs, and
# reaches a successful Pear.start() handshake.
ADB_SERIAL=192.168.0.251:5555 ./run_check.sh --locked-only

# both legs: leg 1, then the real upgrade (leg 2).
FLUTTER_PEAR_VERSION=0.2.0-dev.1 ADB_SERIAL=192.168.0.251:5555 ./run_check.sh
```

- `FLUTTER_PEAR_VERSION` (default `0.2.0-dev.1`): leg 2's upgrade target,
  added as `flutter_pear:^$FLUTTER_PEAR_VERSION` via `dart pub add` --
  exactly DX2 decision 46's command.
- `ADB_SERIAL` (optional): passed as `adb -s $ADB_SERIAL` for every adb
  call. If unset, whichever single device/emulator `adb` already sees is
  used.
- Leg 2 deliberately never runs `flutter clean` before rebuilding -- a real
  upgrade must work against existing build state, not require nuking it.

## Device prerequisites

A device or emulator already visible to `adb devices` (see
`packages/flutter_pear/tool/fresh_machine_check.sh` for this repo's
established "already-running emulator/device" TTHW precondition) -- this
fixture does not boot one itself. An AVD emulator (e.g. `Medium_Phone_API_35`)
is an accepted substitute for physical hardware in this dev environment, the
same standing decision already applied to `flutter_pear-doi`. Leg 1 verified
end to end on `emulator-5554` (arm64 system image) 2026-07-07; the one
physical Android device otherwise reachable here (a BYD DiLink automotive
head unit at `192.168.0.251:5555`) is a different project's hardware and
known incompatible with `flutter_pear_bare` for an unrelated ROM-level
`libnativehelper.so` linker restriction (see `flutter_pear-ovt.1.8`) -- do
not use it for this fixture.

## What a T4 pass means

- **Today** (leg 1 / `--locked-only`): the locked 0.0.1 state itself is a
  sound, buildable, launchable fixture -- this is verifiable now and is a
  precondition for trusting leg 2's result later.
- **At T4** (both legs): `run_check.sh` exits `0` and prints
  `FIXTURE RESULT: ATTACHED (upgraded to ...)` -- leg 2's upgrade resolved
  from hosted pub.dev, rebuilt without a clean, and reached a successful
  `Pear.start()` handshake on the device. This is `release_gate.sh`'s
  responsibility once the `0.2.0-dev.1` prerelease is hosted, not a manual
  step.

If the requested upgrade version isn't hosted yet, leg 2 prints
`WAITING-FOR-HOSTED-ARCHIVE` and exits `2` -- a precondition gap, not a
fixture or plugin failure.

## Rule

No `flutter_pear`-specific manual step is permitted. If a real T4 run needs
a manual workaround beyond running `run_check.sh`, that is itself a release
blocker to fix in the plugin or this fixture, not a step to document here.
