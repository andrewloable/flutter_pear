# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`flutter_pear` wraps the full [Pear](https://pears.com/) P2P stack (Bare runtime + Hyperswarm, Hypercore, Hyperbee, Hyperdrive, Autobase, Corestore, blind pairing) as a Dart-idiomatic Flutter plugin — serverless, E2E-encrypted P2P apps with no Kotlin/Swift/JS bridge code for the app dev.

**The authoritative spec is [project_plan.md](project_plan.md)** — vision, API coverage map, milestones, and DevEx decisions. Read it before any design work; keep it in sync when scope changes.

Unofficial, not affiliated with Holepunch.

## Git commits — manual only

**Never run `git commit` or `git push` automatically in this repo.** The developer commits and pushes by hand. This overrides the "Session Completion" mandatory push workflow in the Beads Issue Tracker section below — do all the other session-close steps (file issues, run quality gates, update issue status, hand off context) but stop short of `git commit`/`git push`. Leave changes staged or unstaged in the working tree for the developer to review and commit themselves. If explicitly asked to commit/push in a given message, that one-time ask is fine — the default is still no.

## Current status

Epics E1–E6 are closed: the Bare Kit worklet is real (not the old native echo) — it boots, joins Hyperswarm, and relays bytes, verified on Android emulator/CI; the RPC contract spine (typed errors, session nonce/version handshake, connection-state stream, native crash observation) is in; every data-structure wrapper (`PearStore`/`PearCore`, `PearBee`, `PearDrive`, `PearPairing`, `PearBase` with prebuilt Autobase recipes) is implemented and exhaustively tested against `flutter_pear_test`'s in-memory fake; lifecycle (auto suspend/resume, hot-restart reattach-or-kill) is real. The one thing left across E1–E6: the physical **two-device** hardware round trip and each wrapper's own real-device leg — all deliberately deferred to one final hardware-validation pass (`flutter_pear-doi`) run once every other epic's automated suite is green.

E7 (example app DX — committed runners, QR-pairing chat, desktop CLI peer, doctor tool), E8 (docs + error DX), and E9 (CI/CD + publishing) are in progress. Run `bd list --status=open` / `bd ready` for exact live status — this file is a snapshot, bd is the source of truth.

iOS is v0.2, its own milestone (podspec, Xcode/CocoaPods, background entitlements) — not started, not a gate on the v0.1 Android release.

## The one architectural principle

**All P2P logic stays in JavaScript inside a Bare worklet. Dart is a typed remote control.**

Do not reimplement any protocol (Hypercore, Autobase, etc.) in Dart. When adding a Pear capability, the work is: expose the JS module over the RPC schema in the pear-end bundle, then add the typed Dart wrapper.

```
Dart API (flutter_pear)              ← what app devs touch
   │  bare-rpc (request/response + event streams)
Platform channel / FFI (flutter_pear_bare)
   │
Bare Kit worklet — the prebuilt "pear-end" JS bundle (built with bare-pack)
   └─ Hyperswarm / Corestore / Hypercore / Hyperbee / Hyperdrive / Autobase / blind-pairing
```

## Intended repo layout (melos monorepo)

| Package | Contents |
|---|---|
| `flutter_pear` | Umbrella: high-level Dart API + the bundled pear-end |
| `flutter_pear_bare` | Low-level Bare Kit bindings — worklet lifecycle, raw binary IPC. Keep this **small**; it's the burnout-risk core |
| `flutter_pear_test` | In-memory fake swarm/core so app devs unit-test without radios or peers |
| `flutter_pear_example` | Chat + file-sync demos (the README quick start must actually run) |
| `tools/` | pear-end build scripts, RPC codegen, prebuild fetcher |

## Toolchain

| Tool | For | Notes |
|---|---|---|
| Flutter SDK ≥3.24 (Dart ≥3.5) | everything | bundles Dart |
| Melos ≥6 | monorepo | `dart pub global activate melos` |
| JDK 17 + Android SDK/NDK | build plugin + example | Android Studio or `sdkmanager`; v0.1 is Android-only |
| Node.js ≥18 + npm | `pear-end/` JS deps | already present in this env |
| bare-pack | rebuild the bundle | `npm i -g bare-pack`; only when `pear-end/` changes |
| bare-link | link `pear-end/`'s native addons (hyperswarm et al.) for Android | `npm i -g bare-link`; invoked by `flutter_pear_bare/android/build.gradle`'s `linkNativeAddons` task at build time, reading `pear-end/node_modules` (run `npm install` there first) |
| Xcode + CocoaPods | iOS | **v0.2** — not needed yet |

Bare Kit native binaries resolve automatically via the Gradle task on Android (already wired, E4). CocoaPods wiring for iOS lands with the v0.2 milestone. No manual NDK/ABI/Podfile steps for app devs on Android today.

## Commands

```bash
melos bootstrap                       # link packages + pub get across the monorepo
melos run analyze                     # analyze every package
melos run test --no-select            # test packages that have a test/ dir (--no-select: this melos version otherwise prompts interactively even non-interactively, e.g. in CI)
flutter test test/crypto_test.dart --plain-name topic   # single test / group (from a package dir)
dart run flutter_pear:pack            # rebuild the pear-end bundle (from packages/flutter_pear; wraps bare-pack, devs never touch it)
```

Per-package work: `cd packages/flutter_pear && flutter test`. The example needs its runner hydrated once: `cd packages/flutter_pear_example && flutter create --platforms=android .`

`assets/pear-end.bundle` (written by the `:pack` command above) is a **committed, versioned artifact** — like `THIRD_PARTY_LICENSES`, it's checked into git, not gitignored. Regenerate and commit it when `pear-end/` or the pinned Bare Kit version changes; a fresh checkout must never depend on running `:pack` before it can build.

The pear-end ships as a **prebuilt, versioned bundle** — rebuild it via the `:pack` wrapper only when JS modules change, and pin/bump versions in the compatibility table (plugin ↔ Bare Kit ↔ Hyper* versions).

## Non-negotiable conventions (these shape every decision)

- **API feel:** `Future`s for calls, broadcast `Stream`s for events, `async`/`await` throughout — no callbacks. Binary as `Uint8List`; keys as a `PearKey` value type with hex/z32 helpers. `dispose()` conventions matching Flutter norms. Doc every public symbol (pub.dev score target ≥130).
- **Errors must travel.** JS exceptions in the worklet serialize across RPC into typed Dart exceptions (`PearConnectionException`, `PearStorageException`, …) with the JS stack attached. Also emit a `worklet.onCrash` stream and log crashes loudly in debug. A silent worklet crash is the worst-case DevEx.
- **Hot reload/restart correctness.** On restart, detect an existing worklet and reattach or cleanly kill it — never require an app reinstall. This ships in v0.1; it's the first thing every dev hits.
- **Lifecycle by default.** Auto suspend/resume wired to `AppLifecycleState` with sane linger, overridable. Document loudly what iOS/Android actually allow in the background so the OS killing a swarm isn't blamed on the library.
- **One-line install.** `flutter pub add flutter_pear` and it builds — native Bare Kit binaries + pear-end resolve via Gradle task + CocoaPods podspec (mirror `react-native-bare-kit`). Zero manual NDK/ABI/Podfile edits; guard it with a fresh-machine CI job.
- **No JavaScript visible by default.** Prebundling the pear-end is what removes "now go learn bare-pack." Custom worklets (`BareWorklet.start(customBundle)`) are a documented advanced path only.

## Licensing (don't break this)

flutter_pear is **MIT**; every dependency it bundles is **MIT or Apache-2.0 — no copyleft**. The pear-end bundle redistributes Apache-2.0 JS, so the package must ship the Apache-2.0 text, bundled modules' `NOTICE` contents, and a `THIRD_PARTY_LICENSES` asset (generated by `dart run flutter_pear:pack` — regenerate when pear-end deps or the Bare Kit version change). Before adding any pear-end dependency, confirm MIT/Apache-2.0/BSD/ISC and **reject GPL/AGPL/LGPL/MPL/SSPL or unlicensed** code. Upstream lives in `holepunchto`; `tetherto` app repos (PearPass, `pear-apps-*`, `wdk-*`) are **not** dependencies. Full detail: [LICENSING.md](LICENSING.md).


<!-- BEGIN BEADS INTEGRATION v:1 profile:minimal hash:7510c1e2 -->
## Beads Issue Tracker

This project uses **bd (beads)** for issue tracking. Run `bd prime` to see full workflow context and commands.

### Quick Reference

```bash
bd ready              # Find available work
bd show <id>          # View issue details
bd update <id> --claim  # Claim work
bd close <id>         # Complete work
```

### Rules

- Use `bd` for ALL task tracking — do NOT use TodoWrite, TaskCreate, or markdown TODO lists
- Run `bd prime` for detailed command reference and session close protocol
- Use `bd remember` for persistent knowledge — do NOT use MEMORY.md files

**Architecture in one line:** issues live in a local Dolt DB; sync uses `refs/dolt/data` on your git remote; `.beads/issues.jsonl` is a passive export. See https://github.com/gastownhall/beads/blob/main/docs/SYNC_CONCEPTS.md for details and anti-patterns.

## Session Completion

**When ending a work session**, you MUST complete ALL steps below. Work is NOT complete until `git push` succeeds.

**MANDATORY WORKFLOW:**

1. **File issues for remaining work** - Create issues for anything that needs follow-up
2. **Run quality gates** (if code changed) - Tests, linters, builds
3. **Update issue status** - Close finished work, update in-progress items
4. **PUSH TO REMOTE** - This is MANDATORY:
   ```bash
   git pull --rebase
   git push
   git status  # MUST show "up to date with origin"
   ```
5. **Clean up** - Clear stashes, prune remote branches
6. **Verify** - All changes committed AND pushed
7. **Hand off** - Provide context for next session

**CRITICAL RULES:**
- Work is NOT complete until `git push` succeeds
- NEVER stop before pushing - that leaves work stranded locally
- NEVER say "ready to push when you are" - YOU must push
- If push fails, resolve and retry until it succeeds
<!-- END BEADS INTEGRATION -->
