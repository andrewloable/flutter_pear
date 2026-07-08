# E6.4 — Background execution reality

**Foreground is the supported guarantee on every platform. Background
behavior is platform-specific, and on both platforms it is entirely at the
OS's discretion.** flutter_pear cannot make Android or iOS keep a P2P swarm
alive indefinitely while your app is backgrounded — no P2P library can. An
OS that suspends or kills a backgrounded app's networking is not a
flutter_pear bug; it's normal OS behavior.

This page covers **Android**, in depth, below. For **iOS**'s background
story — which differs substantially (no equivalent of Android's Doze/App
Standby/OEM-battery-manager layers, but a much harder OS-level suspend
timeline, and a native-vs-Dart suspend distinction that doesn't exist on
Android) — see [`doc/ios.md`](doc/ios.md). Both platforms funnel through the
same `Pear.platformInfo.backgroundExecution` signal (see below, and
`doc/ios.md`'s own coverage of it) so app code can branch on one API instead
of platform-checking directly.

Every claim in this doc either matches tested behavior (E6.1–E6.3, closed
this session) or is explicitly marked OS-dependent — nothing here is
aspirational.

## What this library actually does (Android)

1. **Foregrounded**: the worklet runs normally; `PearSwarm.state` reflects
   real Hyperswarm connectivity (`discovering` → `connecting` → `connected`,
   `reconnecting` if every peer drops, `failed` on a bounded join timeout).
2. **Backgrounded** (`AppLifecycleState.paused`/`hidden`) for longer than
   `PearLifecycleDefaults.linger` (20 seconds by default) with no foreground
   return in between: `PearLifecycle` automatically calls `Pear.suspend()`,
   which suspends the native Bare Kit worklet and sets every joined
   `PearSwarm.state` to `PearSwarmState.suspended`. A quick app-switch
   (foregrounding again before the linger window elapses — a notification
   pull-down, a permission dialog, a share sheet) never suspends anything at
   all; nothing observable changes.
3. **Foregrounded again**: `PearLifecycle` calls `Pear.resume()`, which
   resumes the native worklet. `PearSwarm.state` immediately reflects
   whatever this generation already knows locally (`connected` if a peer
   connection is still tracked, `reconnecting` if it was connected before
   and lost its peers, `discovering` if it never connected before
   suspending) — a same-worklet-generation, best-effort signal. If pear-end
   itself independently notices a real change once running again (e.g. the
   OS actually dropped every socket while backgrounded), that arrives
   separately, in its own time, as an ordinary `PearSwarmState` transition.
4. **Manual override**: `pear.lifecycle.policy = PearLifecyclePolicy.manual`
   opts out of automatic suspend/resume entirely — `Pear.suspend()`/
   `Pear.resume()` stay public and callable directly either way.
5. **Hot restart / process relaunch**: reattaching to a still-running
   worklet (unchanged bundle) or a version-mismatched worklet triggers
   exactly one kill + clean restart (E6.3) — never an app reinstall. If the
   OS killed the whole process (not just backgrounded the app), the native
   worklet died with it (it's a child process); the next launch boots a
   fresh worklet and every `PearSwarm` starts over at `discovering` — any
   in-flight session state (connections, unflushed writes) from before the
   kill is gone, the same as for any Android app whose process is killed.

None of the above prevents Android itself from suspending or killing your
app's process during the up-to-20-second linger window, or at any point
Android decides to — see below.

## Doze and App Standby

**OS-dependent — not controlled by this library.** Android's own
power-management features apply system-wide, to every app, regardless of
what flutter_pear or your app requests:

- **Doze** (device idle, screen off, not on a charger): after a
  device-determined idle period, Android defers network access for every
  app not on its Doze allowlist. A backgrounded worklet's UDP sockets are
  subject to this — Doze can pause them even before `PearLifecycle`'s
  linger window would have suspended the worklet itself.
- **App Standby buckets**: apps the OS judges "rarely used" get
  progressively tighter background network/job restrictions, decided
  algorithmically — not something an app or library can fully opt out of.

## OEM battery managers

**OS-dependent, and often more aggressive than stock Android.** Many device
manufacturers (Samsung, Xiaomi/MIUI, Huawei, OnePlus/OxygenOS, and others)
layer their own, more restrictive battery-optimization policies on top of
stock Android — some kill backgrounded app processes outright, regardless of
Doze allowlisting. This is a well-known, widely-documented class of behavior
across the Android ecosystem, not specific to Flutter or flutter_pear;
searching your target device's manufacturer + "background app kill" or
"battery optimization" turns up current, device-specific guidance (exempting
your app from battery optimization, if the OEM exposes that setting, is the
usual mitigation).

## What this means for your app

- Do not assume a P2P connection or Hyperswarm discovery survives
  backgrounding beyond the `linger` window — plan your UX around
  `PearSwarm.state`, not around an assumption of silent continuity.
- Render `PearSwarm.state` in your UI (e.g. a "reconnecting…" or "paused"
  indicator) rather than hiding the reality of `suspended`/`reconnecting`
  from the end user — that stream exists specifically so an honest state is
  always available to show (see `PearSwarmState`'s own doc for the full
  vocabulary).
- If your use case genuinely needs the swarm to keep running while the user
  is in another app (e.g. an ongoing file transfer or an active call-like
  session), see the foreground-service option below — flutter_pear does not
  do this automatically, by design (a permanent notification is a real cost
  to the end user, and this library defaults to the common case: app in
  active use).

## Foreground-service escape hatch

flutter_pear itself does not ship a foreground-service integration — this is
standard Android platform capability your app opts into directly, unrelated
to any flutter_pear API. A foreground service reduces (it does not
eliminate) the odds of Doze/OEM policies suspending or killing your process,
in exchange for a persistent, user-visible notification while active (a
platform requirement, not a flutter_pear one).

Illustrative sketch (not a flutter_pear API — a plain Android foreground
service, started from your own app code before or alongside `Pear.start()`):

```kotlin
class KeepAliveForegroundService : Service() {
    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val notification = NotificationCompat.Builder(this, CHANNEL_ID)
            .setContentTitle("Syncing")
            .setContentText("Keeping your P2P session active")
            .setSmallIcon(R.drawable.ic_notification)
            .build()
        startForeground(NOTIFICATION_ID, notification)
        return START_STICKY
    }

    override fun onBind(intent: Intent?): IBinder? = null
}
```

Several community Flutter packages wrap this pattern (search pub.dev for
"foreground service" / "foreground task") if you'd rather not write the
platform channel plumbing yourself — evaluate them independently; flutter_pear
neither requires nor bundles one.

## Cross-references

- `PearLifecycle` / `Pear.suspend` / `Pear.resume` (`lib/src/lifecycle.dart`,
  `lib/src/pear.dart`) — the auto suspend/resume mechanism this doc describes.
- `PearSwarmState` (`lib/src/schema.dart`) — the full connection-state
  vocabulary, including `suspended`.
- `RECONNECT_CONTRACT.md` (E6.5) — what a dropped-then-reconnected
  `PearConnection` actually guarantees (ephemeral connection objects, no
  swarm-layer delivery guarantee) — the same underlying mechanism a
  suspend/resume cycle drives, just triggered by an external network change
  instead of `Pear.suspend`.
- `flutter_pear-doi` (internal issue tracker) — the deferred real-device
  validation pass for E6.1–E6.3's actual on-device suspend/resume/reattach
  behavior this doc's claims rest on.

## What's deferred

Every behavioral claim above about `PearLifecycle`/`Pear.suspend`/
`Pear.resume`/hot-restart is backed by automated (mocked-platform-channel)
tests, per this project's standing "automated tests first, hardware last"
decision — real on-device confirmation (does Doze/an OEM killer actually
behave as described against a live flutter_pear swarm, does the linger
window feel right in practice) is tracked centrally in `flutter_pear-doi`
alongside every other deferred hardware leg, not repeated here.
