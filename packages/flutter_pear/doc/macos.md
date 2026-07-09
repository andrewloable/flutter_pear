# macOS platform notes

macOS is the first **desktop runtime target** for flutter_pear (E-D1–E-D4,
tracked under the `flutter_pear-aar` epic) — a fundamentally different
embedding shape from Android/iOS: there is no BareKit for desktop, so the
macOS host (`FlutterPearBarePlugin.swift`) spawns the real `bare` runtime as
a subprocess and relays raw binary IPC over its stdin/stdout, instead of
linking a native worklet in-process. This page is the canonical source for
what macOS actually does differently — every claim below is tested, measured
evidence from the E-D2a–E-D4 host epics, not a guess or an aspiration.
Windows/Linux are tracked separately (`flutter_pear-pfp`/`flutter_pear-65g`)
and are not yet implemented.

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

## Storage root

Same decision as iOS/Android (Eng2 decision 35): worklet storage
(`pear-corestore`/`pear-bulk`) lives under `Application Support`
(`FileManager.default.url(for: .applicationSupportDirectory, ...)`),
appending `flutter_pear/`, never `Documents` or anywhere iCloud-synced —
restoring Hypercore writer keys onto a second device via a document sync
would fork cores, not just duplicate a file.

## What's not yet covered

`flutter_pear_example` has a real `macos/` runner (`flutter_pear-b6g`,
E-D5a) that builds and boots cleanly — worklet attach, swarm join, and the
full `discovering` → `connecting` state machine all confirmed live. `dart
run flutter_pear:doctor` recognizes macOS as a build target (Xcode,
packaging path, `Info.plist`, entitlements, the committed desktop bundle,
deployment target).

**A live, in-app chat round trip against a real peer has NOT been confirmed
end-to-end on this dev machine** — every attempt reached a real Hyperswarm
connection (raw bytes flow, the Protomux channel opens) but never completed
DHT topic correlation, so `PearSwarm.state` never reaches `connected`. This
is very likely this specific machine's own local networking, not a
flutter_pear defect: `dart run flutter_pear:doctor`'s own pre-existing
`Local loopback self-test` (`tool/doctor-checks.js`, unrelated to this
task's own changes) independently fails with the *exact same symptom*
("two peers on THIS machine never connected... likely a local firewall
blocking loopback UDP") for two plain Node peers with no flutter_pear code
involved at all. Confirm this on a real second machine (or a dev box
without this constraint) before treating it as a flutter_pear bug — this is
a documented, open item for whoever picks up desktop validation next, not
silently swept under the rug. Physical two-device (macOS ↔ another real
machine) validation is a documented follow-up, not a release gate.

## See also

- [iOS platform notes](ios.md) — the mobile-side background execution story this page is the desktop counterpart to.
- [Desktop dev setup](desktop-dev.md) — building an *Android/iOS* app from a Windows/Linux host machine (a different topic: that page is about your dev machine, this page is about macOS as a flutter_pear *runtime target*).
- [Error catalog](../ERRORS.md) — every runtime error code's problem, cause, and fix.
