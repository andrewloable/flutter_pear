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
| 0.2.0-dev.1 | 2.3.0 | 7.28.1 | 4.7.3 | 3.0.1 | 2.3.1 | 2.10.1 | 3.3.0 | 7.11.0 | 2.27.3 | 3.7.0 | 13.3.2 | 4.17.0 | 2.2.1 | 1.14.2 | 3.11.0 | 2.28.0 |
| 0.2.0 | 2.3.0 | 7.28.1 | 4.7.3 | 3.0.1 | 2.3.1 | 2.10.1 | 3.3.0 | 7.11.0 | 2.27.3 | 3.7.0 | 13.3.2 | 4.17.0 | 2.2.1 | 1.14.2 | 3.11.0 | 2.28.0 |
| 0.2.1 | 2.3.0 | 7.28.1 | 4.7.3 | 3.0.1 | 2.3.1 | 2.10.1 | 3.3.0 | 7.11.0 | 2.27.3 | 3.7.0 | 13.3.2 | 4.17.0 | 2.2.1 | 1.14.2 | 3.11.0 | 2.28.0 |
| 0.3.0 | 2.3.0 | 7.28.1 | 4.7.3 | 3.0.1 | 2.3.1 | 2.10.1 | 3.3.0 | 7.11.0 | 2.27.3 | 3.7.0 | 13.3.2 | 4.17.0 | 2.2.1 | 1.14.2 | 3.11.0 | 2.28.0 |
| 0.3.1 | 2.3.0 | 7.28.1 | 4.7.3 | 3.0.1 | 2.3.1 | 2.10.1 | 3.3.0 | 7.11.0 | 2.27.3 | 3.7.0 | 13.3.2 | 4.17.0 | 2.2.1 | 1.14.2 | 3.11.0 | 2.28.0 |

## Toolchain

Source of truth per column, left to right: `packages/flutter_pear/pubspec.yaml`
and `packages/flutter_pear_bare/pubspec.yaml`'s `environment:` block (Flutter
SDK / Dart SDK — both packages' pubspecs are checked and must each agree with
this table); the repo-root `pubspec.yaml`'s `melos` dev dependency (Melos);
`packages/flutter_pear_bare/android/build.gradle` (Android Gradle Plugin,
Kotlin, compileSdk, minSdk, supported ABIs); `packages/flutter_pear_example/android/gradle/wrapper/gradle-wrapper.properties`
(Gradle); a repo-wide scan for a literal `ndkVersion` pin (NDK); this repo's
own root `CLAUDE.md` Toolchain table (JDK); the `:pack`-generated
`packages/flutter_pear_bare/ios/flutter_pear_bare/Package.swift`'s
`platforms: [.iOS(.vNN)]` (iOS deployment target).

| flutter_pear version | Flutter SDK | Dart SDK | Melos | Android Gradle Plugin (flutter_pear_bare) | Kotlin (flutter_pear_bare) | Gradle (example app dev/CI wrapper) | Android compileSdk | Android minSdk | Android NDK | Supported ABIs | JDK | iOS deployment target | Xcode |
|---|---|---|---|---|---|---|---|---|---|---|---|---|---|
| 0.0.1 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 | 13 | >=15.0 |
| 0.2.0-dev.1 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 | 13 | >=15.0 |
| 0.2.0 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 | 13 | >=15.0 |
| 0.2.1 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 | 13 | >=15.0 |
| 0.3.0 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 | 13 | >=15.0 |
| 0.3.1 | >=3.24.0 | >=3.5.0 <4.0.0 | ^6.3.2 | 8.3.0 | 1.9.24 | 9.1.0 | 34 | 24 | not pinned | arm64-v8a, x86_64 | 17 | 13 | >=15.0 |

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
- **iOS deployment target (flutter_pear-ovt.3.5, 3.6)** is `flutter_pear_bare`'s
  SPM manifest's own `platforms: [.iOS(.v13)]`, generated by `:pack` from
  the same template every run — not a separate hand-maintained pin. The
  compat CocoaPods podspec (`s.platform = :ios, '13.0'`) records this same
  minimum a second way for CocoaPods-based consumers; both are checked
  against this SAME table cell independently (two `check()` calls, same
  shape as the "Flutter SDK" row's two-pubspec check above), so either side
  drifting — from each other, or from this row — is caught. There is
  currently no SEPARATE "Flutter SDK, iOS SPM path" row: this repo hasn't
  found or hit a real Flutter-version floor for SPM plugin support higher
  than the existing "Flutter SDK" row's `>=3.24.0` (every AUTO-VALIDATION
  build in this epic ran against Flutter 3.44.4) — if a genuinely higher
  SPM-specific floor is ever discovered, add a dedicated column then rather
  than guessing one now.
- **Xcode** is not itself pinned anywhere machine-checkable in this repo (no
  CI, no `xcode-select` version file) — the checker instead derives the
  floor transitively from `Package.swift`'s own real
  `// swift-tools-version:5.9` header via a small, explicit
  tools-version-to-minimum-Xcode table (`5.9` → Xcode 15.0, the first Xcode
  release supporting that Swift tools version — a public Apple/Swift
  toolchain fact, not measured on this dev machine specifically; the Xcode
  actually installed here during the v0.2 spike was 26.6, well above this
  floor, so that number was deliberately NOT used as the pin). Bumping
  `swift-tools-version` to one this table doesn't know maps to a loud
  checker failure naming the gap, not a silent wrong answer.

## Versioning and breaking-change policy

**All three published packages (`flutter_pear`, `flutter_pear_bare`,
`flutter_pear_test`) version in lockstep** — one version number moves all
three together, even when a given release only touches one of them, so a
consumer never has to reason about a compatibility matrix between them.
Prereleases (e.g. `0.2.0-dev.1`) land first against hosted pub.dev archives
before the matching stable version ships.

**Pre-1.0 semver stance:** as stated in the README, minor versions may break
the API without notice before 1.0. This section narrows that generality into
concrete, checkable rules for what "breaking" actually means for this repo.

**What counts as breaking (requires a minor bump + a CHANGELOG callout):**

- Removing or renaming any `PearMethod`, `PearEventName`, or `PearErrorCode`
  constant in `packages/flutter_pear/lib/src/schema.dart` — these are the RPC
  contract's own vocabulary; a consumer's error handling or event listening
  can reference any of them by name.
- Any `pear-end` bundle change that breaks the session nonce/bundle-version
  handshake (`kPearEndBundleVersion` vs. what the bundle actually reports) —
  this is the mechanism that lets a hot-restarted or reattached worklet
  detect an incompatible bundle and fail loudly (`BUNDLE_VERSION_MISMATCH`)
  instead of silently misbehaving; changing its wire shape is inherently
  breaking for anyone running an old Dart side against a new bundle or vice
  versa.

**What does NOT count as breaking:**

- Purely additive `PearMethod`/`PearEventName`/`PearErrorCode` constants —
  new vocabulary a consumer wasn't depending on yet.

**Native packaging surface changes require a prerelease cohort first:** a
BareKit version bump, or a change to the committed native-addon set, must
land in at least one `dev.N` prerelease — validated against real hosted
archives via the upgrade fixtures — before it can ship in a stable release.
This repo has no CI; the prerelease cohort is what stands in for that
safety net.

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
