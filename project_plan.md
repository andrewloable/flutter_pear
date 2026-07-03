# flutter_pear — Project Plan

## 1. Vision

Make the full Pear stack (Bare runtime + Hyperswarm, Hypercore, Hyperbee, Hyperdrive, Autobase, Corestore, blind pairing) usable from Flutter with a Dart-idiomatic API, so a Flutter dev can build a serverless, E2E-encrypted P2P app without touching Kotlin, Swift, or the JS bridge.

**Non-goals (v1):** Dart reimplementation of any protocol; Flutter web/desktop (mobile first, desktop later since Bare supports it); Pear's app-distribution layer (`pear run` / OTA) — apps still ship via app stores.

## 2. Architecture

One principle: **all P2P logic stays in JavaScript inside a Bare worklet; Dart is a typed remote control.**

```
Dart API (flutter_pear)              ← what devs touch
   │  bare-rpc protocol (request/response + event streams)
Platform channel / FFI (flutter_pear_bare)
   │
Bare Kit worklet (bundled JS: "pear-end")
   ├─ Hyperswarm (discovery + Noise-encrypted connections)
   ├─ Corestore / Hypercore / Hyperbee / Hyperdrive
   ├─ Autobase, blind-pairing
   └─ suspend/resume lifecycle hooks
```

- The plugin ships a **prebuilt, versioned JS bundle** (the "pear-end") built with `bare-pack`, exposing every module through a stable RPC schema. Devs never write JS unless they opt into a custom worklet.
- Escape hatch: `BareWorklet.start(customBundle)` for advanced users.

## 3. Repo & packages

Monorepo `flutter_pear`, managed with melos:

| Package | Contents |
|---|---|
| `flutter_pear` | Umbrella: high-level Dart API + bundled pear-end |
| `flutter_pear_bare` | Low-level Bare Kit bindings (worklet lifecycle, raw IPC) |
| `flutter_pear_example` | Chat + file-sync demo apps |
| `tools/` | pear-end build scripts, RPC codegen, prebuild fetcher |

## 4. API coverage map (Pear module → Dart)

| Pear/JS | Dart class | v |
|---|---|---|
| Bare Kit worklet | `BareWorklet` | 0.1 |
| Hyperswarm + secret-stream | `PearSwarm`, `PearConnection` (Stream/Sink of bytes) | 0.1 |
| hypercore-crypto | `PearCrypto` (keypairs, topics, hashes) | 0.1 |
| Corestore + Hypercore | `PearStore`, `PearCore` (append, get, replicate, watch) | 0.2 |
| Hyperbee | `PearBee` (get/put/del, range streams, watch) | 0.3 |
| Hyperdrive + localdrive/mirror | `PearDrive` (files, mirror-to-disk) | 0.3 |
| Autobase | `PearBase` (multi-writer) | 0.4 |
| blind-pairing | `PearPairing` (invites, device linking) | 0.4 |
| Lifecycle (suspend/idle/resume) | auto-wired to `AppLifecycleState`, overridable | 0.1 |

Everything surfaces as `Future`s and broadcast `Stream`s; binary data as `Uint8List`; keys as a `PearKey` value type with hex/z32 helpers.

## 5. Milestones

**M0 — Spike (1–2 wks).** Android-only echo worklet; prove Dart↔IPC round trip, measure latency/throughput; decide EventChannel vs FFI. Post intent on `holepunchto/bare-kit` discussions.

**M1 — v0.1 Core (3–4 wks).** iOS + Android parity. `flutter_pear_bare` stable: start/terminate/suspend/resume, binary IPC, hot-restart-safe worklet handling. `PearSwarm` join/leave/connections. Example: two-phone encrypted chat. CI building both platforms.

**M2 — v0.2 Persistence (3 wks).** Corestore/Hypercore, storage paths per platform, replication over swarm connections. Example: chat with history that syncs on reconnect.

**M3 — v0.3 Data structures (3–4 wks).** Hyperbee + Hyperdrive. Example: P2P file drop.

**M4 — v0.4 Multi-device (3 wks).** Autobase + blind pairing. Example: PearPass-style paired-device sync.

**M5 — v1.0 (2 wks).** API freeze, docs site, benchmarks, background-execution guide (Android foreground service / iOS limits), pub.dev score ≥ 130.

## 6. DevEx review — decisions that make or break adoption

**Install must be one line.** `flutter pub add flutter_pear` and it works. Native Bare Kit binaries and the pear-end bundle resolve via Gradle task + CocoaPods podspec (mirror `react-native-bare-kit`'s approach). *Zero* manual NDK/ABI/podfile edits. Verify with a fresh-machine CI job that creates a new Flutter app, adds the package, and builds both platforms.

**No JavaScript visible by default.** The #1 DevEx risk is "install plugin, now learn bare-pack." Prebundling the pear-end removes it. Custom worklets are a documented advanced path with a `dart run flutter_pear:pack` wrapper so devs never install Bare tooling manually.

**Errors must travel.** JS exceptions in the worklet serialize across RPC into typed Dart exceptions (`PearConnectionException`, `PearStorageException`…) with the JS stack attached. A silent worklet crash is the worst possible debugging experience — also emit a `worklet.onCrash` stream and log crashes loudly in debug mode.

**Hot reload/restart correctness.** Detect existing worklets on restart, reattach or cleanly kill. Ship this in v0.1; it's the first thing every dev hits.

**Lifecycle by default.** Auto suspend/resume wired to app lifecycle with sane linger; document loudly what iOS/Android actually allow in background so devs don't blame the library for OS kills.

**Time-to-first-success < 15 minutes.** README quick start = full chat in ~30 lines of Dart. Copy Pear's own docs pattern (their 15-minute type-along works). Provide `flutter create --template` style starter repo.

**API feel.** Streams for events, Futures for calls, `async`/`await` everywhere, no callbacks; `dispose()` conventions matching Flutter norms; strong docs on every public symbol (pub.dev score depends on it).

**Testing story for users.** Ship `flutter_pear_test` helpers: in-memory fake swarm/core so app devs can unit-test without radios or peers.

**Tooling & governance.** melos monorepo; semantic-release; CHANGELOG; issue templates ("include `flutter doctor` + worklet log"); pin the pear-end module versions and publish a compatibility table (plugin ↔ Bare Kit ↔ Hyper* versions); "unofficial, not affiliated with Holepunch" in README; MIT/Apache-2.0 license to match ecosystem.

**Docs structure (mirrors Pear's own, lowering concept-transfer cost):** Quick start → Concepts (worklet model, keys/topics, replication) → How-tos (chat, file sync, pairing) → API reference → Troubleshooting (NAT/relay behavior, background limits, common build errors).

## 7. Risks

| Risk | Mitigation |
|---|---|
| Bare Kit API churn (some modules pre-1.0) | Pin versions; compatibility table; track upstream releases in CI |
| Native prebuild distribution breaks builds | Fresh-install CI on macOS+Linux; cache/download fallback |
| Platform-channel throughput too low for Hyperdrive | Measure in M0; FFI fast path if needed |
| iOS background kills swarms, devs blame library | Prominent docs + lifecycle API from v0.1 |
| Solo-maintainer burnout | Small core (`flutter_pear_bare`) kept minimal; invite contributors per data-structure package |

## 8. Success criteria

Two fresh devices running the example chat from a clean clone in <15 min; pub.dev score ≥130; hot restart never requires app reinstall; issue tracker not dominated by build failures; at least one community app shipped on it.

If you want, I can now scaffold M0/M1: the melos monorepo, Kotlin + Swift worklet wrappers, the Dart `BareWorklet` + `PearSwarm` API, RPC schema, and the echo worklet — a runnable starting point matching this plan.