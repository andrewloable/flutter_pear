# flutter_pear

The full [Pear](https://pears.com/) peer-to-peer stack as a Dart-idiomatic Flutter plugin. Build serverless, end-to-end-encrypted P2P apps — discovery, encrypted connections, append-only logs, key/value stores, file drives, and multi-writer sync — without writing a line of Kotlin, Swift, or JavaScript.

![Chat demo: an Android emulator joins a room, connects to a desktop peer, and exchanges messages both ways](docs/chat-demo.gif)

> **Platforms — all five:** Android · iOS (**SIMULATOR-VALIDATED** — see [iOS platform notes](packages/flutter_pear/doc/ios.md) before shipping) · macOS · Linux · Windows (desktop is new in 0.3.0 — see [Desktop](#desktop-new-in-030)). Requires Flutter SDK ≥ 3.24 (bundles Dart ≥ 3.5).
>
> **Status: pre-1.0, published on pub.dev (v0.3.1).** Read [What works today](#what-works-today) below before assuming anything here is vaporware — the worklet is real, not a stand-in, and every capability in the coverage table is implemented and tested.
>
> Something stuck? Check [Troubleshooting](packages/flutter_pear/doc/troubleshooting.md) — install-time failures (slow/silent downloads, blocked fetches, checksum/ABI mismatches, manifest-merge conflicts) all have a symptom-first fix there. Still stuck? [Open an issue](https://github.com/andrewloable/flutter_pear/issues).
>
> Unofficial. Not affiliated with [Holepunch](https://holepunch.to/).

## Why

Pear (Bare + Hyperswarm + the Hypercore family) is a complete toolkit for building apps with no servers and no central authority. Its native surface is JavaScript. `flutter_pear` puts a typed Dart API in front of it so a Flutter dev gets Pear's guarantees with Flutter's ergonomics: `Future`s for calls, broadcast `Stream`s for events, `Uint8List` for bytes.

The design principle: **all P2P logic runs in JavaScript inside a bundled [Bare](https://github.com/holepunchto/bare) worklet; your Dart code is a typed remote control.** You never see the JS.

## What works today

flutter_pear is under active, incremental development — here's the honest breakdown of what actually runs versus what's still ahead, so you can tell the difference before relying on any of it.

- **The worklet is real, not a stand-in.** `Pear.start()` boots an actual Bare runtime running the bundled `pear-end` JS — not a native echo. On mobile that's the Bare Kit worklet; on desktop it's the real `bare` CLI runtime, spawned as a subprocess (no BareKit build exists for desktop), relaying the same raw binary IPC. Your Dart code can't tell the difference, and neither can the wire protocol.
- **A real, in-app Hyperswarm chat round trip is confirmed on real hardware** — `PearSwarmState.connected` reached on *both* sides with real messages arriving, through `flutter_pear_example`'s own Dart API, not a scratch probe:
  - **macOS ↔ a real physical Android phone** — real chat messages typed interactively through the app's UI, both directions.
  - **macOS ↔ a remote Linux server** (a genuinely separate public IP, not loopback) — sustained several minutes, both sides' messages arriving cleanly.
  - **Linux ↔ macOS** and **Windows ↔ macOS** — both reached `connected` against a real peer, on real hardware.
- **Every capability in the table below has a complete Dart wrapper and a complete, real `pear-end` JS implementation** — no stubs. Each is exhaustively unit/e2e-tested against `flutter_pear_test`'s in-memory fake (every happy path and every typed error path), plus real-worklet validation on real hardware.
- **The honest remaining gap:** each *data-structure* wrapper's own "does two-device replication actually converge on real hardware" question (`PearBee`, `PearDrive`, `PearBase`, `PearPairing`) was answered against the in-memory fake and the real worklet, not against two physically separate devices per wrapper. Swarm/connection/worklet-lifecycle — the layer everything else rides on — *is* real-hardware confirmed across all five platforms. See [project_plan.md](project_plan.md) for the full milestone breakdown.
- **iOS is simulator-validated**, by standing decision (sim-tier validation ships). The worklet boots and runs on the iOS Simulator against the real committed `pear-end` bundle, verified with a live cross-platform round trip (simulator-iOS ↔ physical Android). Physical-iPhone validation is a documented follow-up, not a release gate. See [iOS platform notes](packages/flutter_pear/doc/ios.md) for what's genuinely different on iOS: background execution, the Local Network permission (the single biggest sim-invisible risk), and storage roots.
- **Published on pub.dev.** `flutter_pear`, `flutter_pear_bare`, and `flutter_pear_test` are all live at **v0.3.1**.

## Install

```bash
flutter pub add flutter_pear
```

Native binaries and the P2P runtime resolve automatically — Gradle on Android, SwiftPM (with a CocoaPods compat path) on iOS, and a committed per-OS bundle on desktop. No manual NDK, ABI, or Podfile edits on any platform.

Pre-1.0: **minor versions may break the API without notice.** Pin an exact version once you depend on this for real.

**Time to hello world (TTHW):** P50 ≤ 5 minutes / P90 ≤ 10 minutes of active work, zero `flutter_pear`-specific build-wiring steps beyond one copy-paste `Info.plist` block on iOS — "hello world" means the first cross-device message, not just a successful build.

First-build download UX (native binaries fetch once, then cache):

- **Android:** downloads Bare Kit's native binaries, cached under each app's `build/flutter_pear_bare/bare-kit/`; delete that directory, or run `flutter clean`, to force a re-download.
- **iOS (SwiftPM, the default):** downloads the repacked `BareKit.xcframework` (~107 MB), cached under `~/Library/Caches/org.swift.swiftpm`; delete that directory, or run `flutter clean`, to force a re-download.
- **iOS (CocoaPods compat path):** downloads the same artifact into `ios/Pods/flutter_pear_bare/barekit_cache/<version>/`; delete `ios/Pods/` and re-run `pod install` to force a re-download.
- **Desktop (macOS/Linux/Windows):** nothing to download at build time — the per-OS `pear-end` bundle and its native addons are committed, versioned artifacts shipped inside the package. The `bare` runtime itself is fetched automatically **at run time, on all three platforms**, on first launch (checksum-verified, then cached) — `npm i -g bare` is a manual fallback only, not required; see [Desktop](#desktop-new-in-030).

Both platforms fetch from the same upstream [holepunchto/bare-kit](https://github.com/holepunchto/bare-kit) release; iOS's SwiftPM/CocoaPods binary-target mechanisms need a single ready-made `BareKit.xcframework` zip rather than Android's raw ~354 MB multi-platform `prebuilds.zip`, so `flutter_pear` republishes just that one framework, repacked and checksum-pinned — see [`barekit-pin.json`](packages/flutter_pear_bare/barekit-pin.json) for the exact pin chain.

**Download-size disclosure** (accept-and-disclose, standing decision — pub.dev downloads every dependency's committed files regardless of your target platform, [flutter/flutter#130210](https://github.com/flutter/flutter/issues/130210)): `flutter_pear_bare`'s committed iOS addon `.xcframework`s (bundled for every consumer, Android-only included) add **~21 MB** to that package's own tracked content — measured directly (`git ls-files` + `du`), not a pub.dev-computed archive size (this repo's `dart pub publish --dry-run` doesn't emit that line in this environment; a repo maintainer with pub.dev publish access should re-measure and correct this number at release time if it drifts). The example app's iOS build produces a `Runner.app` of **~59.7 MB** (measured on the simulator archive) — an absolute number, not a delta.

## Quick start — chat over Hyperswarm

Two phones that share a topic find each other over the internet and exchange end-to-end-encrypted messages, no server:

```dart snippet
import 'dart:convert';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();

// A topic is a 32-byte rendezvous key both peers agree on out of band.
// unsafeTopicFromString is a GLOBAL, demo-only shortcut -- every device
// worldwide using the same string lands in the same room. Real apps
// derive a topic from a PearPairing invite instead (see the coverage
// table below).
final topic = PearCrypto.unsafeTopicFromString('my-secret-room');
final swarm = await pear.join(topic);

swarm.connections.listen((PearConnection conn) {
  conn.data.listen((bytes) {
    print('peer: ${utf8.decode(bytes)}');
  });
  conn.write(utf8.encode('hello from Flutter'));
});

// ... later
await swarm.leave();
await pear.dispose();
```

Expected output on each phone, once the other side's message arrives:

```
peer: hello from Flutter
```

Everything is `Future`s and `Stream`s; keys are a `PearKey` value type with hex helpers (z-base-32 is planned, not yet implemented).

## Enable iOS on an existing Android app

Android-only today? Four steps get you to iOS:

1. `flutter create --platforms=ios .` — plain Flutter, nothing `flutter_pear`-specific.
2. Paste this into `ios/Runner/Info.plist` (copied from [`doc/ios.md`](packages/flutter_pear/doc/ios.md#local-network-permission--the-top-sim-invisible-risk) — see that page for why, and for the full symptom table if you skip this step):
   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>flutter_pear demos connect directly to your other devices over the local network to exchange chat messages and files.</string>
   ```
   Adjust the description to your own app's actual local-network use — Apple requires it be accurate, not necessarily this exact wording.
3. `flutter run` on an iOS Simulator.
4. Exchange your first message with an Android peer — same `Pear.start()`/`join()` code as above, no platform branching required for the happy path.

Coming from an older release? Pin the new version explicitly (`flutter pub add flutter_pear:^0.3.0`) rather than a bare `flutter pub upgrade` — that can't cross a caret boundary between pre-1.0 minors on its own. If `pub add` reports a stale lock conflict, delete `pubspec.lock` and re-resolve.

**Received-file locations** (if your app uses `PearDrive`/file transfer) differ by platform, matching what `flutter_pear_example`'s own file-drop demo does: **iOS** saves into a `Documents` subtree (`path_provider`'s `getApplicationDocumentsDirectory()`), visible in the Files app; **Android** saves into the app's private files directory (`Context.getFilesDir()/received/`), not independently visible — open or share it through your app's own affordance (a `FileProvider` content URI + `ACTION_VIEW`, in the example app's case). Neither location is where the worklet's own protocol storage lives — see [Storage roots](packages/flutter_pear/doc/ios.md#storage-roots-deliberately-non-configurable) for that.

## Desktop (new in 0.3.0)

macOS, Linux, and Windows are real runtime targets — same `Pear.start()`/`join()` code, no platform branching. Enable one the plain Flutter way:

```bash
flutter create --platforms=macos .    # or: linux, windows
dart run flutter_pear:doctor --fix    # macOS only: sandbox/Info.plist/deployment-target -- no-op on Linux/Windows
flutter run -d macos                  # or: linux, windows
```

**There is no BareKit build for desktop**, so the desktop hosts take a different shape than mobile: each spawns the real [`bare`](https://github.com/holepunchto/bare) CLI runtime as a **subprocess** and relays the same raw binary IPC over its stdin/stdout, instead of linking a worklet in-process. Your Dart code never sees the difference, and the wire protocol is identical — a desktop peer and a phone talk to each other with no special casing (that's exactly how the round trips above were confirmed).

> ### `bare` is fetched automatically on all three desktop platforms (flutter_pear-8f6)
>
> **macOS, Linux, and Windows** each fetch their own `bare` runtime on first launch — the real, published `bare-runtime-<host>` npm packages, checksum-verified before use and cached locally (Application Support / XDG data dir / `%LOCALAPPDATA%`) — so end users do **not** need `npm i -g bare` first. `bare` on `PATH` remains a fallback on all three, used only if the fetch itself fails (e.g. no network on first launch):
>
> ```bash
> npm i -g bare    # manual fallback only -- all three platforms fetch this automatically
> ```
>
> A missing/unfetchable `bare` throws a typed, catchable `PearException(BARE_RUNTIME_MISSING)` instead of crashing on **macOS and Linux** (flutter_pear-a4p/-bhv). **Windows** currently surfaces the same scenario as a generic `PearException(WORKLET_CRASHED)` instead of that specific code — its pre-flight check isn't as precise yet, a smaller known gap than the original missing-fetch problem. See [ERRORS.md#BARE_RUNTIME_MISSING](packages/flutter_pear/ERRORS.md#BARE_RUNTIME_MISSING) for the full detail.

One thing desktop genuinely gives you free: **no OS-level background suspension.** `Pear.platformInfo.backgroundExecution` is `unrestricted`, so `PearLifecycle` defaults to `manual` and minimizing a window doesn't drop your swarm. The per-OS `pear-end` bundle and its native addons also ship committed inside the package — nothing to fetch at build time.

**macOS specifically needs three more things** (Linux and Windows need none of them — they have no equivalent OS gates or deployment-target floor). A fresh `flutter create` macOS app will *not* even **build** flutter_pear until:

1. **The App Sandbox is disabled** in **both** `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements` (`com.apple.security.app-sandbox` → `false`). The sandbox unconditionally blocks spawning the `bare` subprocess, and `flutter create` turns it on by default.
2. **`NSLocalNetworkUsageDescription` is added** to `macos/Runner/Info.plist` — macOS 15+ gates LAN traffic behind it and silently drops it if the key is missing, with no prompt.
3. **The macOS Deployment Target is raised to 10.15.4+** in `macos/Runner.xcodeproj` (or in Xcode: Runner target → General → Minimum Deployments) — `flutter create` defaults to 10.15, one patch version below flutter_pear's minimum. Skip this and the build fails immediately with a raw SwiftPM error (`requires minimum platform version 10.15.4`) that names no flutter_pear file or fix at all.

The `dart run flutter_pear:doctor --fix` step in the code block above applies all three automatically — idempotent, prints exactly what it changed, and is a no-op on Linux/Windows (there's nothing to fix there). Run it before your first build, not after hitting the failure. See [macOS platform notes](packages/flutter_pear/doc/macos.md).

Per-platform detail, including exactly what's confirmed and what isn't: [macOS](packages/flutter_pear/doc/macos.md) · [Linux](packages/flutter_pear/doc/linux.md) · [Windows](packages/flutter_pear/doc/windows.md) · [Desktop dev setup](packages/flutter_pear/doc/desktop-dev.md).

## API coverage

| Capability | Dart class | Status |
|---|---|---|
| Worklet lifecycle | `BareWorklet` | **Real-hardware confirmed on all five platforms** — boots, attaches, suspends/resumes, terminates cleanly |
| Discovery + encrypted connections (Hyperswarm) | `PearSwarm`, `PearConnection` | **Real-hardware confirmed** — a live chat round trip reaching `connected` on both sides (macOS ↔ physical Android, macOS ↔ remote Linux, Linux/Windows ↔ macOS) |
| Keypairs, topics, hashes | `PearCrypto` | SHA-256 topics/hashes implemented; real per-device keypairs not yet exposed (`PearPairing` already covers real key exchange for invites) |
| Append-only logs (Corestore / Hypercore) | `PearStore`, `PearCore` | Implemented, fake-tested + real-worklet exercised; per-wrapper two-device replication proof pending |
| Key/value store (Hyperbee) | `PearBee` | Implemented, fake-tested + real-worklet exercised; per-wrapper two-device replication proof pending |
| File drive + mirror-to-disk (Hyperdrive) | `PearDrive` | Implemented, fake-tested + real-worklet exercised; per-wrapper two-device replication proof pending |
| Multi-writer sync (Autobase, prebuilt recipes) | `PearBase` | Implemented, fake-tested + real-worklet exercised; per-wrapper two-device replication proof pending |
| Invites / device linking (blind pairing) | `PearPairing` | Implemented, fake-tested + real-worklet exercised; per-wrapper two-device replication proof pending |

"Per-wrapper two-device replication proof pending" is narrow and specific: the transport underneath every row *is* real-hardware confirmed (rows 1–2), and each wrapper is exhaustively tested against the in-memory fake and exercised against the real worklet — what hasn't been individually demonstrated is each data structure converging across two physically separate devices. The automated test suite for every row above is green today.

App lifecycle (suspend/resume) is auto-wired to `AppLifecycleState` and overridable — see [Background execution](#background-execution).

## Learn more

- [Concepts](packages/flutter_pear/doc/concepts.md) — topics vs. invites (read this before you ship `unsafeTopicFromString` anywhere real), the worklet model, replication, lifecycle.
- How-tos: [chat](packages/flutter_pear/doc/howto-chat.md), [file sync](packages/flutter_pear/doc/howto-filesync.md), [pairing](packages/flutter_pear/doc/howto-pairing.md) — complete, copy-pasteable walkthroughs with expected output.
- Platform notes — what each platform genuinely does differently (background execution, permissions, storage roots, and exactly what's confirmed vs. not): [iOS](packages/flutter_pear/doc/ios.md) · [macOS](packages/flutter_pear/doc/macos.md) · [Linux](packages/flutter_pear/doc/linux.md) · [Windows](packages/flutter_pear/doc/windows.md).
- [Desktop dev setup](packages/flutter_pear/doc/desktop-dev.md) — both senses of "desktop": targeting it as a *runtime*, and building an Android/iOS app *from* a Windows/Linux host.
- [Error catalog](packages/flutter_pear/ERRORS.md) — every error code's problem, cause, and fix.
- [Troubleshooting](packages/flutter_pear/doc/troubleshooting.md) — install-time failures (Gradle fetch, checksum, ABI, manifest merge) that runtime error codes can't catch.

## Testing your app

`flutter_pear_test` ships in-memory fakes for the full API — swarm, Corestore/Hypercore, Hyperbee, Hyperdrive, Autobase, and blind pairing — so you can unit-test your P2P logic without radios or real peers.

## Background execution

**Mobile** (iOS/Android) aggressively suspends background apps, which can drop swarm connections. **Desktop** (macOS/Linux/Windows) does not — there is no OS-level suspension of a minimized window, so `PearLifecycle` defaults to `manual` there instead of `auto`, and minimizing doesn't touch your swarm.

`flutter_pear` wires suspend/resume to the app lifecycle by default on the platforms that need it. [`BACKGROUND_EXECUTION.md`](packages/flutter_pear/BACKGROUND_EXECUTION.md) covers what Android actually permits (foreground service, OS suspend timing), and [iOS platform notes](packages/flutter_pear/doc/ios.md#background-execution-on-ios) covers iOS's own story (a native suspend fix that transitions cleanly, but no extended background execution).

**Branch app behavior on `Pear.platformInfo.backgroundExecution`, not a platform check** — it reports `unrestricted` on desktop and the real constraint on mobile, so you write the policy once.

> A real gotcha worth knowing, learned the hard way: **a phone whose screen locks mid-handshake looks exactly like a broken connection.** Each suspend/resume cycle resets that side's swarm back to `discovering`, and a real DHT lookup can take 30s+ — so a locking screen can starve it forever. That's the designed lifecycle behavior, not a bug. Keep the screen on during a first connect.

## Development setup

This is a [melos](https://melos.invertase.dev/) monorepo. To work on it you need:

- **Flutter SDK ≥ 3.24** (bundles Dart ≥ 3.5)
- **Melos ≥ 6** — `dart pub global activate melos`
- **JDK 17 + Android SDK/NDK** to build the plugin and Android example
- **Xcode + CocoaPods** to build the plugin and the iOS/macOS examples (see [iOS](packages/flutter_pear/doc/ios.md) / [macOS](packages/flutter_pear/doc/macos.md) notes)
- **Desktop toolchains**, per OS you target: Linux needs clang/cmake/ninja/pkg-config + GTK 3 dev headers; Windows needs Visual Studio 2022 with the "Desktop development with C++" workload. `dart run flutter_pear:doctor` checks all of this and names anything missing.
- **The `bare` runtime** — fetched automatically on first launch on macOS, Linux, and Windows (flutter_pear-8f6); `npm i -g bare` is a manual fallback only, not required — see [Desktop](#desktop-new-in-030)
- **Node.js ≥ 18 + npm**, plus **bare-pack** (`npm i -g bare-pack`) *only* if you change the `pear-end/` worklet JS

```bash
melos bootstrap        # link packages + pub get
melos run analyze
melos run test --no-select
```

Every runner (`android/`, `ios/`, `macos/`, `linux/`, `windows/`) is checked in — no `flutter create` hydrate step. Two-peer chat demo, on any two of the five platforms:

```bash
flutter devices                       # note the device IDs (phones, emulators, and desktop all list here)
cd packages/flutter_pear_example
flutter run -d <device-id-A>          # terminal 1 -- e.g. a phone
flutter run -d <device-id-B>          # terminal 2 -- e.g. macos / linux / windows
```

Enter the same room name on both, tap **Join** — messages sent on one appear on the other, with the connection-state banner (discovering/connecting/connected/failed) visible the whole time. Read the matrix below before picking your two peers: **two separate machines, not two processes on one.**

**Pairing-combo matrix (honest — tested, not assumed):**

| Combo | Result | Note |
|---|---|---|
| macOS ↔ physical Android phone | ✅ Works | Real interactive chat, both directions, through the app's own UI. Two genuinely separate devices. |
| macOS ↔ remote Linux server | ✅ Works | Separate public IP. `connected` on both sides, sustained several minutes, both sides' messages arriving. |
| Linux ↔ macOS · Windows ↔ macOS | ✅ Works | Both reached `connected` against a real peer, on real hardware, through the real Dart API. |
| Android emulator ↔ desktop peer (`tool/peer.js`, same machine) | ⚠️ Unreliable | Confirmed working in earlier testing (it's what the demo GIF above shows), but same-machine peers later failed reproducibly on the same dev machine — see the NAT-hairpinning note below. Don't trust it as a clean signal. |
| Two peers behind the same NAT (emulator ↔ emulator, or any two processes on one machine) | ❌ Fails | **NAT hairpinning**, not a flutter_pear bug — many routers won't loop a device's own traffic back to a sibling behind the same NAT, which breaks the UDP hole-punching Hyperswarm's DHT discovery relies on. `dart run flutter_pear:doctor`'s own loopback self-test fails identically with **zero flutter_pear code involved** (two plain Node peers), which is how this got root-caused. |

**The rule that falls out of all of it: test across two genuinely separate machines or networks.** Same-machine and same-NAT setups are the single biggest source of "it just sits at `discovering`" — and it's your router, not this library. Run `dart run flutter_pear:doctor` first; if its loopback self-test fails, same-machine testing will too.

**Headless CLI peer:** `flutter_pear_example` ships a scriptable peer that joins a room with no Flutter app at all — handy as the other end of a test, and as a CI assertion:

```bash
cd packages/flutter_pear_example
dart run flutter_pear_example:peer --topic my-secret-room   # same room name as the app
```

Type a line + Enter to send once it connects; incoming messages print as `peer: <message>`. Exits nonzero if no peer connects within `--timeout <seconds>` (default 30). It runs as a plain Node process (see `tool/peer.js`'s own doc for why), reusing the exact Hyperswarm version `pear-end` bundles for the worklet — no install beyond the Node.js already required for `pear-end/`.

**Run it from a different machine than the app under test.** Pointing it at an app on the *same* machine is the same-NAT trap from the matrix above — it may connect, but a failure there tells you nothing about your code.

**Doctor:** `dart run flutter_pear:doctor` — run from **your own app's root**, not from inside the flutter_pear package (it needs your project's `macos/`/`linux/`/`windows/` directories to check anything platform-specific) — runs runtime connectivity diagnostics — real Hyperswarm DHT bootstrap reachability, a NAT/firewall estimate, and a local two-process loopback self-test — printing a `[PASS]`/`[FAIL]`/`[INFO]` line per check and naming the blocker (with a docs anchor) on a UDP-blocked network instead of shrugging. It's desktop-side network diagnostics, not a real worklet boot: a plain `dart run` CLI has no Flutter engine to drive `BareWorklet`'s platform channels the way a real app does. Its per-OS sections also check the `bare` runtime itself (a missing one is a `[FAIL]`, not a shrug) and, on macOS, the App Sandbox entitlement, Info.plist's `NSLocalNetworkUsageDescription`, and the deployment target — run `dart run flutter_pear:doctor --fix` to apply all three automatically instead of hand-editing XML/project settings.

**Android release packaging:** `flutter build appbundle --release` and `flutter build apk --release --split-per-abi` both build and run correctly — verified on a real arm64-v8a Android emulator (release-mode R8/native-lib loading, not just debug). Both artifact types include a 32-bit `armeabi-v7a` variant by default that is **missing this plugin's native libraries entirely** (Flutter's own ABI splitting has no way to know a dependency only ships arm64-v8a/x86_64 binaries) — installing that specific variant on a device that reports `armeabi-v7a` support (a real 32-bit device, or an ARM-translation layer) fails fast with a clear error at worklet-start time instead of a cryptic native-loader crash; it is not a supported configuration. Always ship the `arm64-v8a`/`x86_64` splits (or let an app bundle's per-device delivery pick one of those).

## Contributing

Roadmap and design rationale live in [project_plan.md](project_plan.md). The low-level `flutter_pear_bare` core is deliberately small; the per-data-structure packages (`PearBee`, `PearDrive`, `PearBase`, …) are the best places to contribute.

## License

flutter_pear is **MIT** © 2026 Andrew Loable — see [LICENSE](LICENSE).

It bundles the Pear stack (Bare Kit + Hyper\* modules), which is **MIT /
Apache-2.0** — all permissive, no copyleft. Redistributed attributions ship in
`THIRD_PARTY_LICENSES` (generated at build time). See [LICENSING.md](LICENSING.md)
for the full dependency breakdown and obligations.
