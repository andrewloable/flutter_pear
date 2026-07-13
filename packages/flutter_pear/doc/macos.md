# macOS platform notes

macOS is the first **desktop runtime target** for flutter_pear (E-D1–E-D4,
tracked under the `flutter_pear-aar` epic) — a fundamentally different
embedding shape from Android/iOS: there is no BareKit for desktop, so the
macOS host (`FlutterPearBarePlugin.swift`) spawns the real `bare` runtime as
a subprocess and relays raw binary IPC over its stdin/stdout, instead of
linking a native worklet in-process. This page is the canonical source for
what macOS actually does differently — every claim below is tested, measured
evidence from the E-D2a–E-D4 host epics, not a guess or an aspiration.
[Linux platform notes](linux.md) and [Windows platform notes](windows.md)
cover the sibling desktop hosts (`flutter_pear-65g`/`flutter_pear-pfp`),
which mirror this same embedding shape but haven't yet had their own
in-app Hyperswarm round trip confirmed the way macOS's has.

## Background execution on macOS

**Unlike iOS/Android, macOS imposes no OS-level suspension on a
backgrounded or minimized app.** A `flutter_pear` swarm connection stays
fully alive — no throttling, no socket kill — regardless of whether the
window is minimized, hidden behind another app, or simply not focused.
Verified directly: a real swarm connection to a companion peer, established
and confirmed live, survived every `AppLifecycleState` transition observed
during testing (`inactive`, `hidden`, `resumed`) with no drop and no state
change other than the connection itself.

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final info = Pear.platformInfo;
if (info.backgroundExecution == PearBackgroundExecution.unrestricted) {
  // macOS today: no need for a "reconnecting..." fallback UI on return to
  // the foreground -- the connection was never at risk in the first place.
  print('This platform keeps peers connected regardless of window state.');
}
```

`Pear.platformInfo.backgroundExecution` is pinned to
`PearBackgroundExecution.unrestricted` for macOS. Two consequences follow
directly from that pin, both shipped as of flutter_pear-iqp (E-D4):

- **The native `suspend`/`resume` control-channel methods are deliberate
  no-ops** on the macOS host — there is nothing to pause. A `bare`
  subprocess just keeps running exactly as it would in the foreground.
- **`PearLifecycle`'s auto-suspend policy defaults to
  `PearLifecyclePolicy.manual` on macOS**, not `auto` (the default on
  Android/iOS). This is not merely "unnecessary" on desktop — leaving the
  mobile-style `auto` policy active would be actively *wrong*: a routine,
  frequent event like minimizing the window or switching to another app
  would (after `PearLifecycle`'s linger window) flip
  `PearSwarm.state`/`currentState` to `PearSwarmState.suspended` for a
  swarm that is, in reality, still fully connected — a false signal
  directly contradicting the `unrestricted` pin above. This was caught by
  reproducing it live: launching a real macOS build spuriously transitioned
  through `AppLifecycleState.inactive`/`.hidden` shortly after boot (an
  artifact of how the app first gains window focus), and — before this
  fix — that alone was enough to auto-suspend a live, connected swarm
  roughly 20 seconds later, with no actual backgrounding involved.
  `lifecycle.policy` stays public and mutable either way, so an app that
  specifically wants mobile-style suspend-on-hide behavior on desktop can
  still opt back in with `pear.lifecycle.policy =
  PearLifecyclePolicy.auto;`.

If your use case wants the worklet to actually pause while the window is
hidden (e.g. to save battery on a laptop), call `Pear.suspend()`/
`Pear.resume()` yourself from your own window-visibility signal — macOS
itself gives you no such signal automatically the way iOS/Android's
`AppLifecycleState` does.

### Orphaned subprocess on quit

A real, normal app quit (Cmd-Q, Dock → Quit, or any path that reaches
`NSApplication.terminate(_:)`) cleanly terminates the `bare` subprocess —
the macOS host listens for `NSApplication.willTerminateNotification` and
kills it explicitly. This does **not** cover an external `SIGKILL` of the
Flutter app process itself (e.g. Activity Monitor "Force Quit", or a
debugger detaching via a raw process kill instead of a graceful quit) — no
in-process code can intercept that, on any platform. If your workflow
regularly force-kills the app during development, expect an orphaned `bare`
process left behind; this is a fundamental OS limit, not a bug.

## Validation tier

**This release is validated on real hardware for macOS** —
`Pear.platformInfo.validationTier` is pinned to `PearValidationTier.device`,
not `.simulator`. Unlike iOS/Android, a macOS build has no separate
simulator/emulator layer to distinguish from: `flutter build macos` and
`flutter run -d macos` both run the compiled binary directly on the real
machine.

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final info = Pear.platformInfo;
print('This release was validated at the ${info.validationTier} tier.');
// macOS: PearValidationTier.device
```

## Local Network permission

**Same requirement as iOS** (see [iOS platform notes](ios.md)'s own "Local
Network permission" section for the full background) — macOS 15+ gates
LAN-unicast traffic behind the system's Local Network privacy permission,
tied to `NSLocalNetworkUsageDescription` in `macos/Runner/Info.plist`, and
**silently drops it with no prompt at all** when the key is missing, rather
than failing loudly. `dart run flutter_pear:doctor` checks for this key
(flutter_pear-b6g, E-D5a) — add it if doctor flags it missing:

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>flutter_pear demos connect directly to your other devices over the local network to exchange chat messages and files.</string>
```

## App Sandbox must stay disabled

The macOS host spawns the real `bare` runtime as an external, non-bundled
subprocess (`flutter_pear-71g`, E-D2a) — the App Sandbox blocks spawning any
such subprocess unconditionally, with no entitlement that opts back in.
Both `macos/Runner/DebugProfile.entitlements` and
`macos/Runner/Release.entitlements` need
`com.apple.security.app-sandbox` set to `false` (`flutter create
--platforms=macos` defaults it to `true`, so this needs an explicit edit).
`dart run flutter_pear:doctor` checks both files. A sandboxed distribution
story (bundling `bare` as a same-bundle helper tool) is a real, deliberately
deferred follow-up, not yet available — this demo/example usage is meant to
be run locally via `flutter run -d macos`, not distributed through the Mac
App Store.

## The `bare` runtime is fetched automatically, not a manual install

**As of flutter_pear-8f6, a flutter_pear macOS app fetches its own `bare`
runtime on first launch** — end users do NOT need `npm i -g bare` first.
`FlutterPearBarePlugin.swift` resolves `bare` in this order:

1. A previously-fetched copy cached under `~/Library/Application
   Support/flutter_pear/bare-runtime/<version>/bare` (instant on every
   launch after the first).
2. A first-use fetch of the real, published `bare-runtime-darwin-<arch>` npm
   package (Apache-2.0, `github.com/holepunchto/bare-runtime`) from
   `registry.npmjs.org`, verified against a SHA-256 pin committed in
   `flutter_pear_bare/bare-runtime-pin.json` BEFORE the binary is ever
   cached or run, then cached at the path above for next time.
3. `bare` on `PATH` — the ORIGINAL mechanism (`npm i -g bare`), kept only as
   a fallback for when the fetch itself fails (e.g. no network on a machine
   that happens to have `bare` installed globally anyway).

The fetch is a synchronous network call on the same thread `Pear.start()`
blocks on, so a cold first launch pauses for as long as the ~20MB download
takes (typically a few seconds on a real network) before the worklet boots;
every launch after that is instant. A non-blocking fetch with a
Dart-visible progress signal is a documented follow-up, not yet built.

**macOS only, verified only on this dev machine's arm64 build** (both the
fetch-success and checksum-rejection paths were exercised live). Linux and
Windows still resolve `bare` from `PATH` only — extending the same
fetch-and-cache mechanism to those hosts is unverified, tracked as a
follow-up. The App Sandbox constraint above applies here too: the fetch
mechanism itself spawns `/usr/bin/tar` to extract the downloaded archive,
which the App Sandbox blocks the same way it blocks `bare` itself — this
does not change the sandboxing story, a sandboxed distribution is still not
supported.

## Storage root

Same decision as iOS/Android (Eng2 decision 35): worklet storage
(`pear-corestore`/`pear-bulk`) lives under `Application Support`
(`FileManager.default.url(for: .applicationSupportDirectory, ...)`),
appending `flutter_pear/`, never `Documents` or anywhere iCloud-synced —
restoring Hypercore writer keys onto a second device via a document sync
would fork cores, not just duplicate a file.

## What's covered, and what to expect while testing

`flutter_pear_example` has a real `macos/` runner (`flutter_pear-b6g`,
E-D5a) that builds and boots cleanly — worklet attach, swarm join, and the
full `discovering` → `connecting` → `connected` state machine all confirmed
live. `dart run flutter_pear:doctor` recognizes macOS as a build target
(Xcode, packaging path, `Info.plist`, entitlements, the committed desktop
bundle, deployment target).

**A live, in-app chat round trip is confirmed working end-to-end**
(`flutter_pear-xue`), against two genuinely different kinds of real peers:

- A remote Linux server (a separate public IP, reached over SSH from this
  dev machine): `PearSwarmState.connected` reached on both sides, sustained
  over several minutes, both sides' messages arriving cleanly.
- A real physical Android phone (`flutter_pear_example` running on real
  hardware, not an emulator): `PearSwarmState.connected` reached on both
  sides, with real chat messages exchanged interactively through the app's
  own UI.

**If a connection sits at `discovering`/`connecting` and doesn't progress,
two things to check before suspecting flutter_pear's own code:**

1. **Same-machine or same-NAT testing.** A connection between two peers that
   can only reach each other through *this dev machine's own local network
   path* (another process on the same Mac, or an emulator NAT'd through the
   same host) never completed DHT topic correlation in testing here, even
   though the raw connection itself succeeded (bytes flow, the Protomux
   channel opens). `dart run flutter_pear:doctor`'s own pre-existing `Local
   loopback self-test` (`tool/doctor-checks.js`, unrelated to this task's
   own changes) independently fails with the exact same symptom for two
   plain Node peers with no flutter_pear code involved — consistent with
   NAT hairpinning (many routers don't correctly loop a device's own
   traffic back to a sibling device behind the same NAT). Check `doctor`'s
   loopback self-test first if you hit this.
2. **A mobile peer backgrounding mid-connection.** The real-phone test above
   initially got stuck the same way — but the actual cause was the phone's
   own screen-timeout backgrounding the app mid-handshake, which suspends
   the worklet by design (see [iOS platform notes](ios.md) and
   `BACKGROUND_EXECUTION.md` for why — this is the same, deliberate,
   documented mobile lifecycle behavior, not a bug). Each suspend/resume
   cycle resets that side's swarm back to `discovering`, so a phone whose
   screen keeps locking during a slow real-DHT lookup can look permanently
   stuck even though the code is working correctly. Keep the mobile
   device's screen on and unlocked for the (real, sometimes 30s+, variable)
   DHT lookup window — the connection genuinely completes once it gets an
   uninterrupted run.

## See also

- [iOS platform notes](ios.md) — the mobile-side background execution story this page is the desktop counterpart to.
- [Linux platform notes](linux.md) and [Windows platform notes](windows.md) — the sibling desktop hosts this page's design is mirrored by.
- [Desktop dev setup](desktop-dev.md) — building an *Android/iOS* app from a Windows/Linux host machine (a different topic: that page is about your dev machine, this page is about macOS as a flutter_pear *runtime target*).
- [Error catalog](../ERRORS.md) — every runtime error code's problem, cause, and fix.
