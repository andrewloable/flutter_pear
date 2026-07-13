## 0.3.1

**`bare` is now fetched automatically on all three desktop platforms** —
macOS, Linux, and Windows each fetch their own `bare` runtime on first
launch (the real, published `bare-runtime-<host>` npm packages, checksum-
verified before use and cached locally), so `npm i -g bare` is a manual
fallback only, never a hard prerequisite. Previously this only worked
reliably on macOS; Linux and Windows needed `bare` on `PATH` first. A
missing/unfetchable `bare` now throws a typed, catchable
`PearException(BARE_RUNTIME_MISSING)` on macOS and Linux instead of
crashing; Windows currently surfaces the same scenario as a generic
`WORKLET_CRASHED` instead of that specific code (its pre-flight check isn't
as precise yet — a smaller known gap, not a regression). See
[ERRORS.md#BARE_RUNTIME_MISSING](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/ERRORS.md#BARE_RUNTIME_MISSING).

**`dart run flutter_pear:doctor --fix`, new in 0.3.1.** Applies the macOS
section's three run-blocking/LAN-breaking fixes automatically instead of
hand-editing XML/project settings: the App Sandbox entitlement in both
`macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements`,
Info.plist's `NSLocalNetworkUsageDescription`, and a below-minimum
`MACOSX_DEPLOYMENT_TARGET` in `project.pbxproj`. Idempotent — a file needing
no change is silently left alone. `bare` on `PATH` is a separate
precondition this does not and cannot fix (installing a runtime isn't a
file edit).

**`dart run flutter_pear:doctor` fixes:** `--help`/`-h` now prints usage
and exits immediately instead of silently running the full diagnostic
suite; a project with a real platform/packaging `[FAIL]` no longer prints
a contradictory "All checks passed." as its last line (that verdict
previously only reflected the runtime connectivity checks, blind to an
earlier Dart-side failure in the same output).

**Docs:** the Desktop quick-start now shows `dart run flutter_pear:doctor --fix`
as an explicit step between `flutter create` and `flutter run`, not just in
trailing prose — following it top-to-bottom now avoids the raw SwiftPM
`requires minimum platform version 10.15.4` error entirely.

No breaking changes. Requires `flutter_pear_bare: ^0.3.1`.

## 0.3.0

**macOS, Linux, and Windows desktop support, new in 0.3.0.** `flutter_pear`
apps now run on desktop, not just Android/iOS — same `Pear.start()`/`join()`
API, no platform branching required. There is no BareKit build for desktop,
so each desktop host spawns the real `bare` CLI runtime as a subprocess and
relays raw binary IPC over its stdin/stdout instead of linking a worklet
in-process; this is transparent to app code.

Real, on-hardware validation, not just a compiling build: all three desktop
hosts booted the real committed per-OS `pear-end.bundle`, completed the
`attach.info` RPC handshake ("worklet attached"), and — through
`flutter_pear_example`'s own real Dart `PearSwarm.join()` call — reached
`PearSwarmState.connected` against a real peer. See each platform's own
notes for exactly what's covered and what's still a documented gap (a
repeatable, gated smoke test on Windows/Linux; a fully round-tripped chat
message, not just `connected`, on Windows/Linux — both already confirmed on
macOS):

- [macOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/macos.md)
- [Linux platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/linux.md)
- [Windows platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/windows.md)
- [Desktop dev setup](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/desktop-dev.md) — the overview page linking all three, plus building an Android/iOS app *from* a Windows/Linux host machine.

`dart run flutter_pear:doctor` gained a desktop build-readiness section per
OS (toolchain presence, packaging path, the committed desktop bundle) —
not just the existing host-capability line.

No Android/iOS behavior changes. Requires `flutter_pear_bare: ^0.3.0`.

## 0.2.1

Version bump only, in lockstep with `flutter_pear_bare`/`flutter_pear_test`'s
0.2.1 (a docs-only README fix in those two packages — this package's own
README needed no change). No code changes.

## 0.2.0

**No Android behavior changes.** Backed by the pack Android regression test
(`pack_android_regression_test.dart`, asserts Android's pack outputs cannot
drift after the iOS extension) and the locked-`0.0.1` Android upgrade
fixture. Accept-and-disclose ([flutter/flutter#130210](https://github.com/flutter/flutter/issues/130210)):
the pub.dev download grows by `flutter_pear_bare`'s committed iOS addon
`.xcframework`s (~21 MB, measured via `git ls-files` + `du`) even for
Android-only apps, though none of it enters an Android build.

**iOS support, new in 0.2.0 — SIMULATOR-VALIDATED.** Enable it on an
existing app in 5 steps:

1. `flutter create --platforms=ios .` — plain Flutter, nothing
   `flutter_pear`-specific.
2. `flutter pub add flutter_pear:^0.2.0` — explicit, not a bare
   `flutter pub upgrade`: that command cannot cross the already-published
   `^0.0.1` caret. If you previously pinned `flutter_pear_bare` directly
   (a **transitive** dependency of `flutter_pear`), bump it the same way;
   if `pub add` reports a stale lock conflict, delete `pubspec.lock` and
   re-resolve.
3. Paste this into `ios/Runner/Info.plist` (see
   [`doc/ios.md`](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md#local-network-permission--the-top-sim-invisible-risk)
   for the full symptom table if you skip this step):
   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>flutter_pear demos connect directly to your other devices over the local network to exchange chat messages and files.</string>
   ```
4. `flutter run` on an iOS Simulator.
5. Exchange your first message with an Android peer.

**iOS behavior differences from Android** — see
[`doc/ios.md`](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md)
for the full detail:

- **Background execution is foreground-only** (`Pear.platformInfo.backgroundExecution
  == PearBackgroundExecution.foregroundOnly`) — a native suspend fix
  transitions backgrounding cleanly, but nothing keeps the worklet
  connected while backgrounded.
- **Validation tier is simulator** (`Pear.platformInfo.validationTier ==
  PearValidationTier.simulator`) — physical-iPhone validation is a
  documented follow-up, not a release gate.
- **Storage roots**: worklet storage lives under Application Support
  (never Documents, deliberately non-configurable — an iCloud restore of
  writer keys onto a second device forks cores); received files (if your
  app uses `PearDrive`) are a separate Documents subtree your own app code
  chooses to use, same as the example app's file-drop demo.

**Minimums:** iOS deployment target 13.0; Xcode ≥ 15.0 (`Package.swift`'s
`swift-tools-version: 5.9` requirement — the first Xcode release supporting
that Swift tools version). Expected first-build BareKit download: ~107 MB
via SwiftPM (the repacked, iOS-only `BareKit.xcframework`) or the same
artifact via the CocoaPods compat path — see the root README's First-build
download UX section for cache locations and force-refetch commands.

**Rollback:** consumers can pin back to `flutter_pear: 0.0.1` in either
direction. Maintainer-side: `dart pub retract` the broken version, triggered
by a broken consumer build reported within the retract window.

## 0.2.0-dev.1

Prerelease of 0.2.0 above, published first so the upgrade fixtures could
validate against real hosted pub.dev archives before the stable release.

## 0.0.1

- Scaffold: `Pear`, `PearSwarm`/`PearConnection`, `PearCrypto`/`PearKey`,
  exception hierarchy, and the JSON RPC bridge over the worklet's binary IPC.
  Re-exports `BareWorklet` from `flutter_pear_bare`.
