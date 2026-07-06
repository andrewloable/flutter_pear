# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`flutter_pear` wraps the full [Pear](https://pears.com/) P2P stack (Bare runtime + Hyperswarm, Hypercore, Hyperbee, Hyperdrive, Autobase, Corestore, blind pairing) as a Dart-idiomatic Flutter plugin — serverless, E2E-encrypted P2P apps with no Kotlin/Swift/JS bridge code for the app dev.

**The authoritative spec is [project_plan.md](project_plan.md)** — vision, API coverage map, milestones, and DevEx decisions. Read it before any design work; keep it in sync when scope changes.

Unofficial, not affiliated with Holepunch.

## Git commits — manual only

**Never run `git commit` or `git push` automatically in this repo.** The developer commits and pushes by hand. This overrides the "Session Completion" mandatory push workflow in the Beads Issue Tracker section below — do all the other session-close steps (file issues, run quality gates, update issue status, hand off context) but stop short of `git commit`/`git push`. Leave changes staged or unstaged in the working tree for the developer to review and commit themselves. If explicitly asked to commit/push in a given message, that one-time ask is fine — the default is still no.

## Current status

Epics E1–E8 are closed: the Bare Kit worklet is real (not the old native echo) — it boots, joins Hyperswarm, and relays bytes, verified on a real Android emulator; the RPC contract spine (typed errors, session nonce/version handshake, connection-state stream, native crash observation) is in; every data-structure wrapper (`PearStore`/`PearCore`, `PearBee`, `PearDrive`, `PearPairing`, `PearBase` with prebuilt Autobase recipes) is implemented and exhaustively tested against `flutter_pear_test`'s in-memory fake; lifecycle (auto suspend/resume, hot-restart reattach-or-kill) is real. The example app DX (E7) and docs/error DX (E8) are done. The deferred hardware-validation pass (`flutter_pear-doi`) is also closed, on an emulator-based-validation basis (developer decision: acceptance criteria downgraded to emulator instead of physical hardware, since none is available in this dev environment) — the physical **two-device** hardware round trip remains a nice-to-have follow-up, not a release blocker.

E9 (CI/CD + publishing) is open but nearly done: `flutter_pear`, `flutter_pear_bare`, and `flutter_pear_test` are all published on pub.dev at v0.0.1. **This repo does not use GitHub Actions/CI** (deliberate decision, developer instruction — removed after real infra problems; see `COMPATIBILITY.md`'s header) — every quality gate (`melos run analyze`/`test`, `check_compatibility.dart`, pana, license enforcement) is run by hand before release, not automatically. What's left on E9: the publish-day checklist's remaining steps (GitHub Discussions/issue templates, final post-publish rendering/smoke confirmation). Run `bd list --status=open` / `bd ready` for exact live status — this file is a snapshot, bd is the source of truth.

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
| bare-link | link `pear-end/`'s native addons (hyperswarm et al.) for Android | `npm i -g bare-link`; invoked by `dart run flutter_pear:pack`'s `linkNativeAddons` (packages/flutter_pear/bin/pack.dart) at **pack time** (maintainer, inside this repo), not at a consumer's build time — reads `pear-end/node_modules` (run `npm install` there first) and commits the resulting `.so` files into `flutter_pear_bare/android/src/main/jniLibs/<abi>/`; only needed when `pear-end/`'s dependencies change |
| Xcode + CocoaPods | iOS | **v0.2** — not needed yet |

Bare Kit's own binaries resolve automatically via a Gradle fetch task on Android (already wired, E4). pear-end's linked native addons are a committed, versioned artifact (like `assets/pear-end.bundle`) regenerated by `:pack`, not resolved at a consumer's build time (flutter_pear-k2y). CocoaPods wiring for iOS lands with the v0.2 milestone. No manual NDK/ABI/Podfile steps for app devs on Android today.

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

`:pack` also writes `flutter_pear_bare/android/src/main/jniLibs/<abi>/*.so` — pear-end's linked native addons (hyperswarm's transitive sodium-native, udx-native, etc.), committed for the same reason (flutter_pear-k2y): resolving them at a *consumer's* build time instead required locating pear-end's own `node_modules` via a path relative to the consuming app's `android/` directory, which only ever worked for the in-monorepo example app — any real external consumer's APK silently shipped with every native addon missing, crashing on `Pear.start()`. Regenerate and commit these `.so` files whenever pear-end's dependencies change, same as the bundle.

The pear-end ships as a **prebuilt, versioned bundle** — rebuild it via the `:pack` wrapper only when JS modules change, and pin/bump versions in the compatibility table (plugin ↔ Bare Kit ↔ Hyper* versions).

## Non-negotiable conventions (these shape every decision)

- **API feel:** `Future`s for calls, broadcast `Stream`s for events, `async`/`await` throughout — no callbacks. Binary as `Uint8List`; keys as a `PearKey` value type with hex/z32 helpers. `dispose()` conventions matching Flutter norms. Doc every public symbol (pub.dev score target ≥130).
- **Errors must travel.** JS exceptions in the worklet serialize across RPC into typed Dart exceptions (`PearConnectionException`, `PearStorageException`, …) with the JS stack attached. Also emit a `worklet.onCrash` stream and log crashes loudly in debug. A silent worklet crash is the worst-case DevEx.
- **Hot reload/restart correctness.** On restart, detect an existing worklet and reattach or cleanly kill it — never require an app reinstall. This ships in v0.1; it's the first thing every dev hits.
- **Lifecycle by default.** Auto suspend/resume wired to `AppLifecycleState` with sane linger, overridable. Document loudly what iOS/Android actually allow in the background so the OS killing a swarm isn't blamed on the library.
- **One-line install.** `flutter pub add flutter_pear` and it builds — native Bare Kit binaries + pear-end resolve via Gradle task + CocoaPods podspec (mirror `react-native-bare-kit`). Zero manual NDK/ABI/Podfile edits; guard it by hand before each release (`packages/flutter_pear/tool/fresh_machine_check.sh` — this repo has no CI).
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

## Skill routing

When the user's request matches an available skill, invoke it via the Skill tool. When in doubt, invoke the skill.

Key routing rules:
- Product ideas/brainstorming → invoke /office-hours
- Strategy/scope → invoke /plan-ceo-review
- Architecture → invoke /plan-eng-review
- Design system/plan review → invoke /design-consultation or /plan-design-review
- Full review pipeline → invoke /autoplan
- Bugs/errors → invoke /investigate
- QA/testing site behavior → invoke /qa or /qa-only
- Code review/diff check → invoke /review
- Visual polish → invoke /design-review
- Ship/deploy/PR → invoke /ship or /land-and-deploy
- Save progress → invoke /context-save
- Resume context → invoke /context-restore
- Author a backlog-ready spec/issue → invoke /spec
