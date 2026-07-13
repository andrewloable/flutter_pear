# flutter_pear

The full [Pear](https://pears.com/) peer-to-peer stack as a Dart-idiomatic Flutter plugin. Build serverless, end-to-end-encrypted P2P apps — discovery, encrypted connections, append-only logs, key/value stores, file drives, and multi-writer sync — without writing a line of Kotlin, Swift, or JavaScript.

> **Platforms:** Android (stable, published) · iOS (**SIMULATOR-VALIDATED** — see [iOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md) before shipping) · macOS/Linux/Windows desktop (new in 0.3.0 — a real Hyperswarm join, reaching `connected`, is confirmed on real hardware for all three; see [Desktop dev setup](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/desktop-dev.md) and each platform's own notes for exactly what's covered). Requires Flutter SDK ≥ 3.24 (bundles Dart ≥ 3.5).
>
> **Status: pre-1.0, published on pub.dev (v0.3.1).** The Bare Kit worklet is real (not a stand-in), and every data-structure wrapper (Corestore/Hypercore, Hyperbee, Hyperdrive, Autobase, blind pairing) is implemented and fake-tested end-to-end, with real-worklet validation on a real Android emulator, the iOS Simulator, and real macOS/Linux/Windows desktop hardware. Physical two-device mobile hardware validation is a documented follow-up, not a release gate. See the [full repository README](https://github.com/andrewloable/flutter_pear#readme) for the complete API coverage table.
>
> Something stuck? Check [Troubleshooting](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/troubleshooting.md). Still stuck? [Open an issue](https://github.com/andrewloable/flutter_pear/issues).
>
> Unofficial. Not affiliated with [Holepunch](https://holepunch.to/).

## Install

```bash
flutter pub add flutter_pear
```

Native binaries and the P2P runtime resolve automatically — Gradle on Android, SwiftPM (with a CocoaPods compat path) on iOS, a committed per-OS bundle on desktop. No manual NDK, ABI, or Podfile edits on any platform. Desktop additionally needs the `bare` runtime at *run* time — see [Desktop](#desktop).

Pre-1.0: **minor versions may break the API without notice.** Pin an exact version once you depend on this for real.

**Time to hello world (TTHW):** P50 ≤ 5 minutes / P90 ≤ 10 minutes of active work, zero `flutter_pear`-specific build-wiring steps beyond one copy-paste `Info.plist` block on iOS — "hello world" means the first cross-device message, not just a successful build.

## Quick start — chat over Hyperswarm

Two phones that share a topic find each other over the internet and exchange end-to-end-encrypted messages, no server:

```dart snippet
import 'dart:convert';
import 'package:flutter_pear/flutter_pear.dart';

final pear = await Pear.start();

// A topic is a 32-byte rendezvous key both peers agree on out of band.
// unsafeTopicFromString is a GLOBAL, demo-only shortcut -- every device
// worldwide using the same string lands in the same room. Real apps
// derive a topic from a PearPairing invite instead.
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
2. Paste this into `ios/Runner/Info.plist` (copied from [iOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md#local-network-permission--the-top-sim-invisible-risk) — see that page for why, and for the full symptom table if you skip this step):
   ```xml
   <key>NSLocalNetworkUsageDescription</key>
   <string>flutter_pear demos connect directly to your other devices over the local network to exchange chat messages and files.</string>
   ```
   Adjust the description to your own app's actual local-network use — Apple requires it be accurate, not necessarily this exact wording.
3. `flutter run` on an iOS Simulator.
4. Exchange your first message with an Android peer — same `Pear.start()`/`join()` code as above, no platform branching required for the happy path.

Coming from an older release? Pin the new version explicitly (`flutter pub add flutter_pear:^0.3.0`) rather than a bare `flutter pub upgrade` — that can't cross a caret boundary between pre-1.0 minors on its own. If `pub add` reports a stale lock conflict, delete `pubspec.lock` and re-resolve.

## Desktop

macOS, Linux, and Windows are real runtime targets — same `Pear.start()`/`join()` code, no platform branching:

```bash
flutter create --platforms=macos .    # or: linux, windows
dart run flutter_pear:doctor --fix    # macOS only: sandbox/Info.plist/deployment-target -- no-op on Linux/Windows
flutter run -d macos                  # or: linux, windows
```

There is no BareKit build for desktop, so each desktop host spawns the real [`bare`](https://github.com/holepunchto/bare) CLI runtime as a **subprocess** and relays the same raw binary IPC over its stdin/stdout. Your Dart code never sees the difference — a desktop peer and a phone talk to each other with no special casing.

> **`bare` is fetched automatically on all three desktop platforms — no manual install.**
> macOS, Linux, and Windows each fetch their own `bare` runtime on first launch (checksum-verified, then cached) — end users do **not** need `npm i -g bare` first. `bare` on `PATH` remains a fallback on all three, used only if the fetch itself fails (e.g. no network on first launch). A missing/unfetchable `bare` throws a typed, catchable `PearException` instead of crashing on macOS/Linux; Windows currently surfaces a generic `WORKLET_CRASHED` in that same scenario instead (its pre-flight check isn't as precise yet) — see [ERRORS.md](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/ERRORS.md#BARE_RUNTIME_MISSING).
>
> ```bash
> npm i -g bare    # manual fallback only -- all three platforms fetch this automatically
> ```

Desktop does give you one thing free: **no OS-level background suspension** (`backgroundExecution` is `unrestricted`, so `PearLifecycle` defaults to `manual` — minimizing a window won't drop your swarm). The per-OS `pear-end` bundle ships committed inside the package, so there's nothing to fetch at build time either.

**macOS needs three more things** (Linux and Windows need none of them). A fresh `flutter create` macOS app won't even **build** flutter_pear until:

1. **The App Sandbox is disabled** in **both** `macos/Runner/DebugProfile.entitlements` and `macos/Runner/Release.entitlements` (`com.apple.security.app-sandbox` → `false`) — it unconditionally blocks spawning the `bare` subprocess, and `flutter create` enables it by default.
2. **`NSLocalNetworkUsageDescription` is added** to `macos/Runner/Info.plist` — macOS 15+ silently drops LAN traffic without it.
3. **The macOS Deployment Target is raised to 10.15.4+** in Xcode (Runner target → General) — `flutter create` defaults to 10.15, below flutter_pear's minimum. Missing this fails the build immediately with a raw SwiftPM error naming no flutter_pear file at all.

The `dart run flutter_pear:doctor --fix` step in the code block above applies all three automatically (run from your app's root, not from inside this package) — idempotent, prints exactly what it changed, and is a no-op on Linux/Windows. A plain `dart run flutter_pear:doctor` (no `--fix`) checks all three without changing anything and prints the exact fix for each.

Detail per platform: [macOS](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/macos.md) · [Linux](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/linux.md) · [Windows](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/windows.md).

**Received-file locations** (if your app uses `PearDrive`/file transfer) differ by platform, matching what `flutter_pear_example`'s own file-drop demo does: **iOS** saves into a `Documents` subtree (`path_provider`'s `getApplicationDocumentsDirectory()`), visible in the Files app; **Android** saves into the app's private files directory (`Context.getFilesDir()/received/`), not independently visible — open or share it through your app's own affordance (a `FileProvider` content URI + `ACTION_VIEW`, in the example app's case). Neither location is where the worklet's own protocol storage lives — see [Storage roots](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md#storage-roots-deliberately-non-configurable) for that.

## First-build download UX

Native binaries fetch once, then cache:

- **Android:** downloads Bare Kit's native binaries, cached under each app's `build/flutter_pear_bare/bare-kit/`; delete that directory, or run `flutter clean`, to force a re-download.
- **iOS (SwiftPM, the default):** downloads the repacked `BareKit.xcframework` (~107 MB), cached under `~/Library/Caches/org.swift.swiftpm`; delete that directory, or run `flutter clean`, to force a re-download.
- **iOS (CocoaPods compat path):** downloads the same artifact into `ios/Pods/flutter_pear_bare/barekit_cache/<version>/`; delete `ios/Pods/` and re-run `pod install` to force a re-download.

Desktop fetches nothing at build time — the per-OS `pear-end` bundle and its native addons are committed, versioned artifacts shipped inside the package.

Mobile fetches from the same upstream [holepunchto/bare-kit](https://github.com/holepunchto/bare-kit) release; iOS's SwiftPM/CocoaPods binary-target mechanisms need a single ready-made `BareKit.xcframework` zip rather than Android's raw ~354 MB multi-platform `prebuilds.zip`, so `flutter_pear` republishes just that one framework, repacked and checksum-pinned — see [`barekit-pin.json`](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear_bare/barekit-pin.json) for the exact pin chain.

**Download-size disclosure** (accept-and-disclose, standing decision — pub.dev downloads every dependency's committed files regardless of your target platform, [flutter/flutter#130210](https://github.com/flutter/flutter/issues/130210)): `flutter_pear_bare`'s committed iOS addon `.xcframework`s (bundled for every consumer, Android-only included) add **~21 MB** to that package's own tracked content — measured directly (`git ls-files` + `du`), not a pub.dev-computed archive size. The example app's iOS build produces a `Runner.app` of **~59.7 MB** (measured on the simulator archive) — an absolute number, not a delta.

## Learn more

- [Concepts](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/concepts.md) — topics vs. invites, the worklet model, replication, lifecycle.
- How-tos: [chat](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/howto-chat.md), [file sync](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/howto-filesync.md), [pairing](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/howto-pairing.md).
- Platform notes — what each platform genuinely does differently: [iOS](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md) · [macOS](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/macos.md) · [Linux](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/linux.md) · [Windows](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/windows.md).
- [Desktop dev setup](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/desktop-dev.md) — targeting desktop as a runtime, and building an Android/iOS app *from* a Windows/Linux host.
- [Background execution (Android)](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/BACKGROUND_EXECUTION.md) — what Android actually permits.
- [Error catalog](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/ERRORS.md) — every error code's problem, cause, and fix.
- [Troubleshooting](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/troubleshooting.md) — install-time failures that runtime error codes can't catch.
- [Full repository README](https://github.com/andrewloable/flutter_pear#readme) — API coverage table, testing your app, development setup, contributing.

## License

flutter_pear is **MIT** © 2026 Andrew Loable — see [LICENSE](https://github.com/andrewloable/flutter_pear/blob/main/LICENSE).

It bundles the Pear stack (Bare Kit + Hyper\* modules), which is **MIT /
Apache-2.0** — all permissive, no copyleft. Redistributed attributions ship in
`THIRD_PARTY_LICENSES` (generated at build time). See [LICENSING.md](https://github.com/andrewloable/flutter_pear/blob/main/LICENSING.md)
for the full dependency breakdown and obligations.
