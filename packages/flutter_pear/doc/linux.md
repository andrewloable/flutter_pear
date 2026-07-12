# Linux platform notes

Linux is a **desktop runtime target** for flutter_pear (E-D2c, tracked under
the `flutter_pear-aar` epic), using the same embedding shape macOS pioneered
(E-D1–E-D4): there is no BareKit for desktop, so the Linux host
(`flutter_pear_bare_plugin.cc`, a real GTK/GLib Flutter plugin) spawns the
real `bare` runtime as a subprocess and relays raw binary IPC over its
stdin/stdout, instead of linking a native worklet in-process. This page is
the canonical source for what Linux actually does differently — every claim
below is tested, measured evidence, not a guess or an aspiration. See
[macOS platform notes](macos.md) for the desktop host this one mirrors, and
[Windows platform notes](windows.md) for the sibling desktop host.

## Background execution on Linux

**Like macOS, Linux imposes no OS-level suspension on a backgrounded or
minimized app.** Desktop Linux window managers don't throttle or freeze a
minimized GUI app's process the way iOS/Android's OS does — there is no
analogous mechanism to opt out of in the first place.
`Pear.platformInfo.backgroundExecution` is pinned to
`PearBackgroundExecution.unrestricted` for Linux, same as macOS, and for the
same reason:

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final info = Pear.platformInfo;
if (info.backgroundExecution == PearBackgroundExecution.unrestricted) {
  // Linux today: no need for a "reconnecting..." fallback UI on return to
  // the foreground -- the connection was never at risk in the first place.
  print('This platform keeps peers connected regardless of window state.');
}
```

Two consequences follow directly from that pin, mirroring macOS's own
E-D4 fix (`flutter_pear-iqp`) generalized to every `unrestricted` platform:

- **The native `suspend`/`resume` control-channel methods are deliberate
  no-ops** on the Linux host — there is nothing to pause. A `bare`
  subprocess just keeps running exactly as it would in the foreground.
- **`PearLifecycle`'s auto-suspend policy defaults to
  `PearLifecyclePolicy.manual` on Linux**, not `auto`. Leaving the
  mobile-style `auto` policy active would be actively *wrong* here for the
  exact same reason it would be on macOS: a routine, frequent event like
  minimizing the window would (after `PearLifecycle`'s linger window) flip
  `PearSwarm.state` to `PearSwarmState.suspended` for a swarm that is, in
  reality, still fully connected. `lifecycle.policy` stays public and
  mutable either way, so an app that specifically wants mobile-style
  suspend-on-hide behavior can still opt back in with `pear.lifecycle.policy
  = PearLifecyclePolicy.auto;`.

### Orphaned subprocess on quit

A real, normal app quit (window close, or any path that reaches the
process's `GApplication` "shutdown" signal) cleanly terminates the `bare`
subprocess — the Linux host registers a `RegisterWithRegistrar`-time hook
via `g_application_get_default()` + `g_signal_connect(app, "shutdown", ...)`
that kills it explicitly, with zero changes needed to a consuming app's own
generated `my_application.cc`. This does **not** cover an external
`SIGKILL` of the Flutter app process itself — no in-process code can
intercept that, on any platform (same fundamental OS limit documented on
[macOS](macos.md#orphaned-subprocess-on-quit)). If your workflow regularly
force-kills the app during development, expect an orphaned `bare` process
left behind; this is not a bug.

## Validation tier

`Pear.platformInfo.validationTier` is pinned to `PearValidationTier.device`,
not `.simulator` — same rationale as macOS: a Linux build has no separate
simulator/emulator layer to distinguish from, `flutter build linux` runs the
compiled binary directly on the real machine.

## Local Network permission and App Sandbox: not applicable

Unlike iOS/macOS 15+, desktop Linux has no OS-level Local Network privacy
permission gating LAN-unicast traffic, and no App Sandbox equivalent
blocking subprocess spawning — `dart run flutter_pear:doctor` does not check
for either on Linux, because there is nothing to check.

## Storage root

Same decision as every other platform (Eng2 decision 35): worklet storage
(`pear-corestore`/`pear-bulk`) lives under the XDG data directory
(`$XDG_DATA_HOME`, default `~/.local/share`), appending `flutter_pear/` —
never a cloud-synced location. No Linux desktop environment syncs this
directory by default, matching the same "never let a backup/sync restore
fork a Hypercore writer key onto a second device" rationale documented for
the other platforms.

## What's covered, and what's still open

**Real, on-hardware validation performed for this host** (`flutter_pear-65g`):
compiled for real via the real Flutter Linux toolchain (clang, cmake, ninja,
GTK 3 dev headers) on a real Ubuntu 24.04 machine, then the full worklet
lifecycle contract was exercised live
against a real spawned `bare` subprocess: a fresh boot, a reattach (the
exact same generation id, matching a Dart hot restart's expectations), the
`suspend`/`resume` no-ops acking without disturbing the live relay, a
message round-tripping correctly through the relay after that, `terminate()`
actually killing the subprocess, and a post-terminate `start()` booting a
genuinely fresh worklet (a new generation id). Process-tree hygiene (no
orphaned `bare` process survives after the app exits) was confirmed
directly via `pgrep`, not just inferred. The `linux-x64` desktop bundle
(`assets/desktop/linux-x64/pear-end.bundle` plus its offloaded native addon
prebuilds) is a real, committed build artifact, produced the same way the
macOS bundles are (`bare-pack --offload-addons`).

**A real, in-app Hyperswarm join through `flutter_pear_example` is
confirmed** (`flutter_pear-65g`, `flutter_pear-ymz`): using the example
app's own `FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC` dart-define mechanism (the
same one `tool/release_gate.sh`'s `linux-smoke`/`macos-smoke` gates use)
against a real macOS peer, Linux's `PearSwarm.join()` reached
`PearSwarmState.connected` — confirmed twice, independently, on separate
runs. The real committed `linux-x64` `pear-end.bundle` boots, does a real
`attach.info` RPC round trip, joins a real Hyperswarm topic, and reaches a
real peer connection, all through `flutter_pear_example`'s real Dart API
(`flutter run -d linux`), not a throwaway scratch probe.

**Nuance, not a blocker:** the bidirectional chat message itself (as
opposed to reaching `connected`) was not confirmed received on either side
in these specific runs — likely a data-channel-vs-swarm-state timing
artifact of an ad-hoc, staggered-start test across two machines with
different build times (the macOS peer's own swarm never itself reached
`connected` in these particular runs), not a network or protocol defect;
macOS's own chat round trip is separately, definitively confirmed
end-to-end elsewhere (see [macOS platform notes](macos.md)). The underlying
byte-relay mechanism is also independently confirmed correct via the
lifecycle contract testing above. A cleaner, better-synchronized repeat of
this exact test would likely also confirm the message round trip.

`flutter_pear_example` has a real, committed `linux/` runner (`flutter
create --platforms=linux .`, `.metadata` fixed to keep the existing
android/ios/macos entries `flutter create` otherwise drops — same gotcha
macOS's own runner setup hit). `dart run flutter_pear:doctor` reports real
Linux desktop build readiness (`doctor_linux_checks.dart`: clang, cmake,
ninja, GTK 3 dev headers, and the committed `linux-x64` bundle).
`tool/release_gate.sh` has a `linux-build`/`linux-smoke` leg mirroring
`macos-build`/`macos-smoke`, using `xvfb-run` when available since a real
Linux release/CI machine is commonly headless (this project's own Linux
test box included).

## See also

- [macOS platform notes](macos.md) — the desktop host this one mirrors structurally.
- [Windows platform notes](windows.md) — the sibling desktop host, same embedding shape.
- [Desktop dev setup](desktop-dev.md) — building an *Android/iOS* app from a Windows/Linux host machine (a different topic: that page is about your dev machine, this page is about Linux as a flutter_pear *runtime target*).
- [Error catalog](../ERRORS.md) — every runtime error code's problem, cause, and fix.
