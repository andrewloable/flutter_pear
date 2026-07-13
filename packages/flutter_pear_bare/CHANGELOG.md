## 0.3.1

**Each desktop host now fetches and caches its own `bare` runtime binary**
instead of only resolving it from `PATH`: the real, published
`bare-runtime-<host>` npm packages for `darwin-arm64`/`darwin-x64`/
`linux-x64`/`win32-x64`, checksum-verified against a new
`bare-runtime-pin.json` before use and cached locally (Application Support
on macOS, XDG data dir on Linux, `%LOCALAPPDATA%` on Windows). `bare` on
`PATH` remains a fallback, used only if the fetch itself fails. Implemented
natively per host — `CryptoKit`/`Process` on macOS
(`FlutterPearBarePlugin.swift`), `GLib`/`GIO` on Linux
(`flutter_pear_bare_plugin.cc`), and Win32/CNG (`bcrypt.h`) on Windows
(`flutter_pear_bare_plugin_impl.cpp`) — with a distinct, catchable
`bare_runtime_missing` platform error surfaced on macOS and Linux when the
fetch fails and no `PATH` fallback is found (Windows currently surfaces a
generic crash for the same scenario instead of that specific code, a
smaller known gap).

No breaking changes to the lifecycle contract from 0.3.0.

## 0.3.0

**macOS, Linux, and Windows desktop hosts, new in 0.3.0.** No BareKit build
exists for desktop, so each host (`flutter_pear_bare_plugin.cc`/`.swift` for
Linux/macOS, a C++ Windows plugin) spawns the real `bare` CLI runtime as a
subprocess and relays raw binary IPC over its stdin/stdout — the same
`start`/`terminate`/`suspend`/`resume` lifecycle contract mobile's BareKit
binding already exposes, just a different transport underneath.

Real, on-hardware validation for all three: the full lifecycle contract
(fresh boot, reattach with the same generation id, `suspend`/`resume`
no-ops, a message round-tripping through the relay, `terminate()` actually
killing the subprocess tree, a post-terminate fresh boot) exercised live
against the real spawned process, plus a real end-to-end Hyperswarm join
through `flutter_pear`'s real `PearSwarm.join()` API reaching
`PearSwarmState.connected` on real hardware. One genuine per-OS difference
worth knowing: unlike macOS/Linux, a Windows process's Job Object
(`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE`) tears down the whole worklet process
tree automatically even on a forced kill — no orphaned subprocess gap to
work around there. See each platform's own notes (linked from
[Desktop dev setup](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/desktop-dev.md))
for exact detail.

No Android/iOS behavior changes.

## 0.2.1

Docs-only patch: this package's own README still said "Android-only, iOS
not started" after 0.2.0 shipped iOS support — corrected to match reality.
No code changes.

## 0.2.0

**No Android behavior changes.** Backed by the pack Android regression test
(`pack_android_regression_test.dart`) and the locked-`0.0.1` Android upgrade
fixture. Accept-and-disclose ([flutter/flutter#130210](https://github.com/flutter/flutter/issues/130210)):
this package's pub.dev download grows by its committed iOS addon
`.xcframework`s (~21 MB, measured via `git ls-files` + `du`) even for
Android-only consumers, though none of it enters an Android build.

**iOS support, new in 0.2.0 — SIMULATOR-VALIDATED.** `BareWorklet` now
boots and runs the real, committed `pear-end` bundle on the iOS Simulator
via a real Swift host — lifecycle (`start`/`terminate`/`suspend`/`resume`,
hot-restart reattach-or-kill), raw binary IPC, and a native `suspend(withLinger:)`
fix that honors the Dart-configured `PearLifecycle(linger:)` value on
backgrounding. Resolution is SwiftPM-first with a CocoaPods compat path,
both fetching a repacked, checksum-pinned `BareKit.xcframework` at consumer
build time — see `barekit-pin.json`. See the `flutter_pear` package's own
CHANGELOG for the full 5-step Enable-iOS recipe (the
`flutter pub add flutter_pear:^0.2.0` step covers this package
transitively; bump it directly too if you pinned it yourself).

**Minimums:** iOS deployment target 13.0; Xcode ≥ 15.0 (`Package.swift`'s
`swift-tools-version: 5.9` requirement). Expected first-build BareKit
download: ~107 MB via SwiftPM, or the same artifact via the CocoaPods
compat path (`ios/Pods/flutter_pear_bare/barekit_cache/<version>/`).

**Rollback:** pin back to `flutter_pear_bare: 0.0.1`. Maintainer-side:
`dart pub retract` the broken version.

## 0.2.0-dev.1

Prerelease of 0.2.0 above, published first so the upgrade fixtures could
validate against real hosted pub.dev archives before the stable release.

## 0.0.1

- `BareWorklet` low-level API: lifecycle (`start`/`terminate`/`suspend`/`resume`,
  hot-restart reattach-or-kill) and raw binary IPC to the real Bare Kit
  worklet on Android — boots, joins Hyperswarm, and relays bytes; verified on
  Android emulator/CI. The physical two-device hardware round trip is
  deferred to a later hardware-validation pass. iOS is a separate, not-yet-
  started v0.2 milestone.
