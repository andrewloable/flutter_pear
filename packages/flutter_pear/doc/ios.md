# iOS platform notes

flutter_pear v0.2 adds iOS. This page is the canonical source for what iOS
actually does differently from Android — every claim below is tested,
measured evidence recorded during the v0.2 iOS spike and host epics, not a
guess or an aspiration. `BACKGROUND_EXECUTION.md` covers Android's own
background story; this page covers iOS's.

## Background execution on iOS

**iOS suspends the app and kills its sockets within seconds of
backgrounding — there is no extended background execution today.** Plan
your UX around `Pear.platformInfo.backgroundExecution`, not around an
assumption of silent continuity:

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final info = Pear.platformInfo;
if (info.backgroundExecution == PearBackgroundExecution.foregroundOnly) {
  // iOS today: show a "reconnecting…" state on return to foreground
  // instead of promising the connection survived backgrounding.
  print('This platform only reliably keeps peers connected in the '
      'foreground.');
}
```

`Pear.platformInfo.backgroundExecution` is pinned to
`PearBackgroundExecution.foregroundOnly` for iOS, and that pin is correct
for what's shipped, not a placeholder:

- The Dart-side `PearLifecycle` linger timer (`PearLifecycleDefaults.linger`,
  20 seconds by default) that drives Android's graceful suspend **does not
  fire while the app is genuinely backgrounded on iOS** — the whole Dart
  isolate freezes the instant the app leaves the foreground and only catches
  up (firing `onSuspend` immediately before `onResume`) the moment the app
  returns. Measured directly: three background/foreground rounds of
  23s/37s/65s all showed the identical pattern — the timer never fired
  mid-background, only on return.
- To fix the resulting *unclean* suspend (the worklet was previously left in
  an undefined state for the whole background duration instead of suspending
  promptly), the iOS host now arms BareKit's own native
  `suspend(withLinger:)` directly from `UIApplication
  .didEnterBackgroundNotification`, inside a short `beginBackgroundTask`,
  passing through whatever linger value you configured via
  `PearLifecycle(linger:)` (the same value Android's Dart timer uses — a
  custom linger is never silently ignored on either platform). This has
  shipped and is verified end-to-end on the simulator: backgrounding at
  `12:47:36.966` armed `suspendWithLinger(20000ms)`; foregrounding again at
  `12:48:01.401` (~24.4s later, past the linger) resumed the worklet
  cleanly, with the app still fully responsive afterward — not crashed or
  wedged.
- That fix makes backgrounding **transition cleanly**; it does not make the
  worklet **stay connected while backgrounded**. The `beginBackgroundTask`
  used to make the native suspend call reliable is ended immediately after
  the call, not held open for the full linger — so iOS remains free to
  suspend the whole process at any point after backgrounding, exactly as
  `PearBackgroundExecution.foregroundOnly`'s own contract describes ("no
  guarantee of how long a connection survives first — the OS, not this
  library, decides"). Nothing here is a background-execution entitlement
  (no VoIP, no background fetch, no persistent-connection background mode);
  none is requested by flutter_pear today.
- **Sim-only caveat**: the simulator validates the suspend/resume *code
  path* only — the RPC calls fire and the worklet transitions states
  correctly — not real iOS background socket-kill timing on physical
  hardware, which can be far more aggressive than the simulator's own
  behavior. Physical-iPhone confirmation of this timing is a documented
  follow-up, not a release gate (see Validation tier below).

If your use case needs the swarm to keep running while the user is in
another app, you need a real iOS background mode (e.g. VoIP, if your
traffic pattern genuinely qualifies) wired up in your own app — flutter_pear
does not provide or require one.

## Validation tier

**This release is SIMULATOR-VALIDATED on iOS**: every iOS-side behavior
described in this doc and exercised by this package's test suite was
verified against the iOS Simulator, paired against physical Android over a
real LAN for cross-platform scenarios. Physical-iPhone validation is a
documented follow-up, not a release gate — the standing v0.2 decision is
that simulator-tier validation is sufficient to ship.

`Pear.platformInfo.validationTier` records exactly this, per platform, as a
release-time constant:

```dart snippet
import 'package:flutter_pear/flutter_pear.dart';

final info = Pear.platformInfo;
print('This release was validated at the ${info.validationTier} tier.');
// iOS: PearValidationTier.simulator
// Android: PearValidationTier.device
```

`validationTier` is pinned at release time — it never runtime-detects
whether the code happens to be running on a simulator or real device right
now, and it is gate-checked against `COMPATIBILITY.md` before every
release. Branch app behavior on `backgroundExecution`, not on
`validationTier` — the latter is a release-process fact, not a UX signal.

## Local Network permission — the top sim-invisible risk

Since iOS 14, unicast traffic to another device's local-network address
triggers the system's Local Network permission prompt, gated by
`NSLocalNetworkUsageDescription` in your app's `Info.plist`. **The iOS
Simulator does not enforce this check at all** — a same-Wi-Fi peer
connection that works perfectly on the simulator can fail outright on a
real iPhone if this key is missing or the user denies the prompt. This is
the single biggest risk this release's simulator-only validation cannot
surface for you.

### Does flutter_pear actually trigger it?

**Yes.** Confirmed by source inspection of the Hyperswarm/hyperdht
dependency stack (`flutter_pear-ovt.1.12`'s FEAS-TCC spike): every DHT
connection handshake unconditionally gathers this device's own LAN-local IP
addresses and offers them to the peer as connection candidates — exactly
the direct-unicast-to-a-LAN-address pattern that trips the prompt. There is
no way to opt out of this from flutter_pear's API, because doing so would
break same-Wi-Fi peer discovery, the common case this library exists for.

**No additional entitlement is needed.** The same inspection found zero
multicast, broadcast, or mDNS usage anywhere in the Hyperswarm dependency
stack — peer discovery is entirely DHT-based (unicast to bootstrap/relay
nodes, plus the LAN-candidate mechanism above). You do **not** need
`NSBonjourServices` or the `com.apple.developer.networking.multicast`
entitlement for flutter_pear specifically.

### Symptom table (works-on-simulator, fails-on-device)

| Symptom on a real iPhone | Simulator behavior | Cause |
|---|---|---|
| Same-Wi-Fi peers never reach `connected`, stuck at `discovering`/`connecting` | Works normally | `NSLocalNetworkUsageDescription` missing from `Info.plist` — the OS silently drops local-network unicast instead of showing a prompt at all |
| A first-run permission dialog appears, then peers never connect afterward | Never appears — nothing to test | User tapped **Don't Allow** on the Local Network prompt |
| `PearSwarm.state` sits in `reconnecting` indefinitely for peers on the same network | Not reproducible — TCC isn't enforced | Same as above, observed mid-session (e.g. permission revoked in Settings while the app was already running) |

### Required Info.plist key

Add this to your app's `ios/Runner/Info.plist` (the exact copy this
package's own example app ships):

```xml
<key>NSLocalNetworkUsageDescription</key>
<string>flutter_pear demos connect directly to your other devices over the local network to exchange chat messages and files.</string>
```

Adjust the description string to describe *your* app's actual use of the
local network — Apple requires it be accurate to what the prompt is asking
permission for, not necessarily this exact wording.

### In-app recovery

iOS gives your app no reliable way to distinguish "the user denied Local
Network access" from an ordinary NAT/UDP connectivity failure — both look
identical from `PearSwarm.state` alone. Never claim certainty you don't
have; word any in-app recovery UI as a possibility, not a diagnosis. The
`flutter_pear_example` app's own banner (`LocalNetworkTroubleBanner`,
`packages/flutter_pear_example/lib/local_network_banner.dart`) is the
reference pattern:

> Having trouble connecting over the local network
>
> If you denied Local Network access for this app, re-enable it in
> Settings.

paired with an **Open Settings** action that deep-links into your app's
Settings page (`UIApplication.openSettingsURLString`) rather than leaving
the user to find it themselves — a doc note alone does not rescue an end
user mid-flow.

## Storage roots, deliberately non-configurable

flutter_pear's worklet storage (Corestore, the underlying Hypercores/
Hyperbees/Hyperdrives) lives under **Application Support**
(`FileManager`'s `.applicationSupportDirectory`, at
`Application Support/flutter_pear/{pear-corestore,pear-bulk}`) and is
explicitly excluded from iCloud/iTunes backup
(`URLResourceValues.isExcludedFromBackup`). This is **never** configurable
to Documents, and that's deliberate: an iCloud backup restore of a
device's Hypercore **writer keys** onto a second device would fork every
core it wrote to — silent protocol corruption, not a recoverable UX
problem. Application Support is also where Android's own private
`filesDir` equivalent lives, so this mirrors the Android storage contract
exactly.

This is entirely separate from any **received files** your app saves via
`PearDrive`/the file-transfer demo pattern — those are ordinary app data
your own code chooses where to put, commonly the iOS Documents directory
(`getApplicationDocumentsDirectory()` from `path_provider`) specifically
*because* Documents is Files-app-visible, letting the user see, open, and
share what they received. `flutter_pear_example`'s own file-drop demo does
exactly this: worklet/staging storage under Application Support, received
files under a separate Documents subtree. Nothing about the worklet's own
protocol storage is ever exposed there.

If your app needs a different on-disk layout than this (a custom Corestore
location, additional native addons, etc.), the documented escape hatch is a
custom worklet bundle — `BareWorklet.start(customBundle)` — not a
configuration flag on the default bundled pear-end; see `README.md`'s
advanced-usage section.
