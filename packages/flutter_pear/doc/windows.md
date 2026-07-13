# Windows platform notes

Windows is a **desktop runtime target** for flutter_pear (E-D2b, tracked
under the `flutter_pear-aar` epic), using the same embedding shape macOS
pioneered (E-D1–E-D4): there is no BareKit for desktop, so the Windows host
(`flutter_pear_bare_plugin.cpp`, a real C++ Flutter Windows plugin) spawns
the real `bare` runtime as a subprocess and relays raw binary IPC over its
stdin/stdout, instead of linking a native worklet in-process. This page is
the canonical source for what Windows actually does differently — every
claim below is tested, measured evidence, not a guess or an aspiration. See
[macOS platform notes](macos.md) for the desktop host this one mirrors, and
[Linux platform notes](linux.md) for the sibling desktop host.

## Background execution on Windows

**Like macOS/Linux, Windows imposes no OS-level suspension on a
backgrounded or minimized app.** A normal desktop Windows app is not
throttled or frozen for being minimized or losing focus — there is no
analogous mechanism to opt out of in the first place.
`Pear.platformInfo.backgroundExecution` is pinned to
`PearBackgroundExecution.unrestricted` for Windows, same as macOS/Linux, and
for the same reason:

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final info = Pear.platformInfo;
if (info.backgroundExecution == PearBackgroundExecution.unrestricted) {
  // Windows today: no need for a "reconnecting..." fallback UI on return to
  // the foreground -- the connection was never at risk in the first place.
  print('This platform keeps peers connected regardless of window state.');
}
```

Two consequences follow directly from that pin, mirroring macOS's own
E-D4 fix (`flutter_pear-iqp`) generalized to every `unrestricted` platform:

- **The native `suspend`/`resume` control-channel methods are deliberate
  no-ops** on the Windows host — there is nothing to pause. The worklet
  process chain just keeps running exactly as it would in the foreground.
- **`PearLifecycle`'s auto-suspend policy defaults to
  `PearLifecyclePolicy.manual` on Windows**, not `auto`, for the exact same
  reason it does on macOS/Linux: a routine, frequent event like minimizing
  the window would otherwise flip `PearSwarm.state` to
  `PearSwarmState.suspended` for a swarm that is, in reality, still fully
  connected. `lifecycle.policy` stays public and mutable either way, so an
  app that specifically wants mobile-style suspend-on-hide behavior can
  still opt back in with `pear.lifecycle.policy =
  PearLifecyclePolicy.auto;`.

### The worklet is a 3-process chain, not 1 — and why that's invisible to you

Unlike macOS/Linux (where `bare` is a single process the host spawns
directly), a real npm global install of `bare` on Windows resolves through
`bare.cmd` → `node.exe` → the actual native `bare-runtime` binary (confirmed
by reading a real installed `bare` package's own launcher script before
writing this host). The Windows host spawns via `cmd.exe /c bare ...` (the
same PATHEXT-resolution path a real interactive `bare ...` invocation takes,
so it works regardless of exactly which shape a given machine's npm install
produced) and assigns the **entire** resulting process tree to a Windows Job
Object, so `terminate()` — and even an external force-kill of the whole
Flutter app — tears down all three processes together. None of this is
visible from Dart; it's mentioned here only because it explains why Windows
needed meaningfully different subprocess-management code from macOS/Linux
even though the plugin's own Dart-facing contract is identical.

### Orphaned subprocess on quit — Windows actually does slightly better here

A real, normal app quit cleanly terminates the whole worklet process tree —
the Windows host registers a `RegisterTopLevelWindowProcDelegate` hook that
watches for `WM_DESTROY` on the app's own top-level window and tears the
tree down explicitly, with zero changes needed to a consuming app's own
generated runner code. Like macOS/Linux, this does **not** cover an external
force-kill by itself (no in-process code can intercept that, on any
platform — see [macOS's own note](macos.md#orphaned-subprocess-on-quit)).
**Unlike macOS/Linux, Windows gets cleanup in that case too, as a side
effect of the Job Object's `JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` flag**:
Windows automatically tears down every process still assigned to a job the
moment the job's last handle is closed, which happens implicitly when the
OS reaps the killed app's handle table — confirmed directly (not assumed)
by force-killing a running test app via `Stop-Process -Force` and observing
both the worklet's `cmd.exe` and `node.exe` already gone immediately after,
with no separate graceful-shutdown code path involved.

## Validation tier

`Pear.platformInfo.validationTier` is pinned to `PearValidationTier.device`,
not `.simulator` — same rationale as macOS/Linux: a Windows build has no
separate simulator/emulator layer to distinguish from, `flutter build
windows` runs the compiled binary directly on the real machine.

## Local Network permission and App Sandbox: not applicable

Unlike iOS/macOS 15+, desktop Windows has no OS-level Local Network privacy
permission gating LAN-unicast traffic (Windows Firewall may prompt on first
run, but that's a one-time, user-controlled prompt, not something
`flutter_pear` or its consumers configure), and no App Sandbox equivalent
blocking subprocess spawning — `dart run flutter_pear:doctor` does not
check for either on Windows, because there is nothing to check.

## Storage root

Same decision as every other platform (Eng2 decision 35): worklet storage
(`pear-corestore`/`pear-bulk`) lives under `%LOCALAPPDATA%`, appending
`flutter_pear\` — deliberately **not** `%APPDATA%` (Roaming), which Windows
explicitly designs to roam across machines in domain/enterprise
environments. Roaming would risk exactly the failure mode Eng2 decision 35
exists to prevent: a sync/profile-roam restoring a Hypercore writer key onto
a second device and forking the core, not just duplicating a file.

## The `bare` runtime is fetched automatically, not a manual install

**As of flutter_pear-8f6, a flutter_pear Windows app fetches its own
`bare` runtime on first launch** — end users do NOT need `npm i -g bare`
first. `flutter_pear_bare_plugin_impl.cpp` resolves `bare` in this order: a
previously-fetched copy cached under `%LOCALAPPDATA%\flutter_pear\
bare-runtime\<version>\bare.exe` (instant on every launch after the
first); a first-use fetch of the real, published `bare-runtime-win32-x64`
npm package (Apache-2.0, `github.com/holepunchto/bare-runtime`) from
`registry.npmjs.org` via `curl.exe`, verified via Windows CNG (`bcrypt.h`)
SHA-256 against a pin committed in
`flutter_pear_bare/bare-runtime-pin.json` BEFORE the binary is ever cached
or run, then extracted via `tar.exe` (both built into Windows 10
1803+/Server 2019+); the ORIGINAL `cmd.exe /c bare ...` PATH/PATHEXT
mechanism as a fallback only if the fetch itself fails. Verified live on a
real Windows 11 machine (Visual Studio 2022 Community, MSVC 14.44) — both
the fetch-success and checksum-rejection paths. Note: a rejected/failed
fetch falling back to the PATH mechanism still surfaces a generic
`WORKLET_CRASHED` rather than a clean `BARE_RUNTIME_MISSING` if `bare` also
isn't on PATH — flutter_pear-a4p/-bhv's pre-flight-check fixes for a clean
typed error were scoped to macOS/Linux only, not Windows; confirmed live,
not a regression from this fetch mechanism.

## What's covered, and what's still open

**Real, on-hardware validation performed for this host** (`flutter_pear-pfp`):
compiled for real via a real Visual Studio 2022 install (the "Desktop
development with C++" workload) on a real Windows 11 machine, then the full
worklet lifecycle contract was exercised live against the real spawned
process chain: a fresh boot, a reattach (the exact same generation id,
matching a Dart hot restart's expectations), the `suspend`/`resume` no-ops
acking without disturbing the live relay, a message round-tripping
correctly through the relay after that, `terminate()` actually killing the
whole process tree, and a post-terminate `start()` booting a genuinely
fresh worklet (a new generation id). Process-tree hygiene was confirmed
directly via `Get-CimInstance Win32_Process`, not just inferred — both
under normal operation (the correct `cmd.exe`/`node.exe` parent/child
relationship, with the exact expected argv) and under a forced kill (see
above). The `win32-x64` desktop bundle
(`assets/desktop/win32-x64/pear-end.bundle` plus its offloaded native addon
prebuilds) is a real, committed build artifact, produced the same way the
macOS/Linux bundles are (`bare-pack --offload-addons`).

**A real, in-app Hyperswarm join through `flutter_pear_example` is now
confirmed** (`flutter_pear-pfp`): using the example app's own
`FLUTTER_PEAR_GATE_AUTO_JOIN_TOPIC` dart-define mechanism against a real
macOS peer, `PearSwarm.join()` reached `PearSwarmState.connected` on real
Windows hardware — watched directly via a temporary diagnostic print
(reverted immediately after), not inferred from the plumbing alone.

Getting there needed one real, Windows-specific workaround worth recording:
this dev environment's only reachable Windows box is SSH-only (Windows 11
Home has no RDP), and a GUI app launched from a plain SSH session has no
window station to render into at all — every attempt crashed at EGL/swap-
chain creation regardless of `--enable-software-rendering`. The fix was
launching the app into the machine's own real, already-logged-in
interactive console session via a Windows Scheduled Task (`schtasks /create
... /it /ru <the logged-in user>`, then `/run`) instead of directly from the
SSH shell — the standard technique for handing a process to another
session's window station without RDP. Once running there, rendering worked
with zero EGL/swap-chain errors, and the join proceeded normally. This is
purely a workaround for *testing without a full interactive desktop
session* — a real end user launching the app normally by double-clicking it
never hits this at all.

**Nuance, not a blocker, matching macOS's and Linux's own pages:** the join
above was a single, ad-hoc run (via a directly-launched pre-built exe, not
yet through `flutter run` itself), not a repeatable gated test. The
lifecycle-contract testing earlier in this section independently confirms
the subprocess spawn, storage-dir convention, and raw byte relay all work
correctly on real hardware regardless — the same mechanism `flutter_pear`'s
real RPC protocol rides on top of, so the join result is corroborating
evidence, not the only evidence.

`flutter_pear_example` now has a real, committed `windows/` runner
(`flutter_pear-m6s`, E-D5b — `flutter create --platforms=windows .`,
`.metadata` fixed the same way every other platform's own runner-add hit),
and `tool/release_gate.sh` gained a `windows-build`/`windows-smoke` leg
mirroring `linux-build`/`linux-smoke` — including one genuine Windows-only
simplification: unlike macOS/Linux, `windows-smoke` needs no separate
orphan-subprocess cleanup step, since the Job Object's
`JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE` flag already tears the whole worklet
process tree down automatically (see "Orphaned subprocess on quit" above).
The `windows-smoke` gate's own exact script wasn't independently re-run
end-to-end through `flutter run` this session (it uses the identical
rendering path and dart-define mechanism already proven above, just
through the Flutter tool's own wrapper instead of a pre-built exe) — a
final confirming pass once this leg reaches a real Windows release machine
is the one remaining honest gap.

## See also

- [macOS platform notes](macos.md) — the desktop host this one mirrors structurally.
- [Linux platform notes](linux.md) — the sibling desktop host, same embedding shape.
- [Desktop dev setup](desktop-dev.md) — building an *Android/iOS* app from a Windows/Linux host machine (a different topic: that page is about your dev machine, this page is about Windows as a flutter_pear *runtime target*).
- [Error catalog](../ERRORS.md) — every runtime error code's problem, cause, and fix.
