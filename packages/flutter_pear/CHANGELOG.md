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
