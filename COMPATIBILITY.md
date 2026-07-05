# Compatibility + toolchain contract

This file is the **single tested contract** for flutter_pear: which `pear-end`
JS module versions and Bare Kit release a given plugin version was built and
tested against, plus which Android toolchain versions its own build
(`flutter_pear_bare/android/build.gradle`) is pinned to.

It is not aspirational documentation — every value below is checked against
its real source of truth by
[`packages/flutter_pear/bin/check_compatibility.dart`](packages/flutter_pear/bin/check_compatibility.dart).
This project does not use GitHub Actions/CI (deliberate decision — run
quality gates locally); run the checker by hand before every push. If a cell
here and the file it's supposed to describe ever disagree, that script fails,
naming the exact field, the two disagreeing values, and where the real one
lives.

**Pre-1.0 note:** flutter_pear has not yet had a git-tagged release, so there
is currently only one row in each table below: `0.0.1`, published to pub.dev
but not yet tagged in this repository. Once real tagged releases exist, each
new release **appends** a new row rather than editing the current one in
place — this file then doubles as a compatibility changelog.

## Plugin ↔ Bare Kit ↔ Hyper* module versions

Source of truth: `packages/flutter_pear_bare/android/build.gradle`'s
`bareKitVersion` for the Bare Kit column; `packages/flutter_pear/pear-end/package.json`'s
`dependencies` (exact-pinned, no ranges, per flutter_pear-df9.1) for every
other column.

| flutter_pear version | Bare Kit | autobase | bare-fs | bare-path | blind-pairing | blind-pairing-core | compact-encoding | corestore | hyperbee | hypercore-crypto | hyperdrive | hyperswarm | localdrive | mirror-drive | protomux | streamx |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.0.1 | 2.3.0 | 7.28.1 | 4.7.3 | 3.0.1 | 2.3.1 | 2.10.1 | 3.3.0 | 7.11.0 | 2.27.3 | 3.7.0 | 13.3.2 | 4.17.0 | 2.2.1 | 1.14.2 | 3.11.0 | 2.28.0 |

## Toolchain

Source of truth per column, left to right: `packages/flutter_pear/pubspec.yaml`
and `packages/flutter_pear_bare/pubspec.yaml`'s `environment:` block (Flutter
SDK / Dart SDK — both packages' pubspecs are checked and must each agree with
this table); the repo-root `pubspec.yaml`'s `melos` dev dependency (Melos);
`packages/flutter_pear_bare/android/build.gradle` (Android Gradle Plugin,
Kotlin, compileSdk, minSdk, supported ABIs); `packages/flutter_pear_example/android/gradle/wrapper/gradle-wrapper.properties`
(Gradle); a repo-wide scan for a literal `ndkVersion` pin (NDK); this repo's
own root `CLAUDE.md` Toolchain table (JDK).

| flutter_pear version | Flutter SDK | Dart SDK | Melos | Android Gradle Plugin (flutter_pear_bare) | Kotlin (flutter_pear_bare) | Gradle (example app dev/CI wrapper) | Android compileSdk | Android minSdk | Android NDK | Supported ABIs | JDK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.0.1 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 |

### Reading this table honestly (judgment calls made here)

- **"Android Gradle Plugin (flutter_pear_bare)" / "Kotlin (flutter_pear_bare)"
  are the *plugin's own* Android module's toolchain**, not
  `flutter_pear_example`'s. The example app pins a separate, newer AGP/Kotlin
  (currently AGP 9.0.1 / Kotlin 2.3.20, in
  `packages/flutter_pear_example/android/settings.gradle.kts`) for reasons
  specific to that sample app (see flutter_pear-jqe — a real, documented
  incompatibility between that combination and every camera/permission
  Flutter plugin, which is why the example hand-rolls its QR scanner). That
  is the example app's own dev-experience decision, not a promise made to
  every consumer of the plugin, so it is deliberately **not** in this table.
  Only `flutter_pear_bare/android/build.gradle` — what every consumer's
  Gradle build actually resolves through this plugin — is the contract.
- **"Gradle (example app dev/CI wrapper)" is *not* a plugin-level contract
  either.** `flutter_pear_bare` (the library module) carries no Gradle
  wrapper of its own — a consuming app supplies its own Gradle version,
  compatible with whatever AGP the app itself uses. The 9.1.0 value here is
  the Gradle version this repo's own example app + CI pin for reproducible
  local/CI builds; it is tracked here (and CI-checked) so it can't silently
  drift out of the doc, not because a consumer is promised Gradle 9.1.0.
- **NDK is genuinely not pinned anywhere in this repo.** Verified by grep
  (`ndkVersion`) across every `packages/*/android` tree: the only occurrence
  is `flutter_pear_example/android/app/build.gradle.kts`'s
  `ndkVersion = flutter.ndkVersion` — a delegation to whatever the installed
  Flutter SDK's own default NDK is, not a literal version pin. There is
  nothing to check this cell against beyond "still nothing is hard-pinned";
  the checker enforces exactly that (and will fail, naming the offending
  file, the day someone adds a real one without updating this row).
- **JDK is documented, not build-enforced.** No config file in this repo
  declares "JDK 17" as a single machine-checkable pin the way the others
  are (nothing in this repo runs a real Android build automatically — there
  is no CI — so nothing invokes `setup-java` at all). The checker instead
  cross-checks this cell against root `CLAUDE.md`'s own Toolchain table row
  ("JDK 17 + Android SDK/NDK"), which is the only place a JDK version is
  asserted anywhere in this repo. That catches the two docs drifting from
  each other; it does not catch either of them drifting from whatever JDK a
  given machine actually runs.
- **Melos is checked against the repo-root `pubspec.yaml`'s
  `melos: ^6.3.2` dev dependency**, which is a real, machine-checkable
  constraint. Note that a contributor bootstrapping this repo typically runs
  a bare `dart pub global activate melos` (no version argument, i.e.
  whatever's latest at the time), so this row documents the repo's own
  declared floor, not a guarantee of exactly what that global activation
  resolves to on a given machine — tightening that gap is a separate concern
  from this ticket's scope.
- **Supported ABIs** (`arm64-v8a, x86_64`) mirrors
  `flutter_pear_bare/android/build.gradle`'s `bareKitAbis` — 32-bit ABIs are
  a deliberate exclusion, documented at length in that file itself.
  `packages/flutter_pear/test/pack_test.dart` separately guards that
  `bin/pack.dart`'s native-addon ABI list (`nativeAddonAbis`) stays in sync
  with this same `bareKitAbis` list; this table's row is a third, independent
  check that the *documentation* also agrees, not a duplicate of that test.

## How this is enforced

```
packages/flutter_pear/bin/check_compatibility.dart
```

reads every cell in both tables above for the row matching the current
`flutter_pear` plugin version (from `packages/flutter_pear/pubspec.yaml`),
extracts the corresponding real value from its source file, and reports
every disagreement — field, the two values, and which file the real one
came from — then exits non-zero if any exist. Run it locally with:

```bash
cd packages/flutter_pear
dart run bin/check_compatibility.dart
```

There is no CI running this automatically (this project doesn't use GitHub
Actions) — running it locally before every push **is** the enforcement.

## Bump procedure

Whenever any pinned value below changes — a Hyper* dependency bump in
`pear-end/package.json`, a `bareKitVersion` bump in
`flutter_pear_bare/android/build.gradle`, an AGP/Kotlin/compileSdk/minSdk
change, a Flutter/Dart SDK floor raise, a Melos bump, or an example-app
Gradle wrapper bump:

1. **Update the pin at its real source first** — e.g. bump the version in
   `pear-end/package.json` and run `npm install` in `packages/flutter_pear/pear-end/`
   to refresh `package-lock.json`, or edit `build.gradle` directly. Do not
   edit this file first; the check script only cares that the two agree, not
   which one changed.
2. **Update the matching cell(s) in this file** to the same new value. If
   this is the plugin's first-ever tagged release (post E9.7), instead
   **append** a new row underneath the current one and leave prior rows
   untouched — do not overwrite history.
3. **Run the checker** (`cd packages/flutter_pear && dart run
   bin/check_compatibility.dart`) locally before pushing — this repo has no
   CI to catch a missed step 2 for you; a non-zero exit here means this
   procedure wasn't followed to completion.
