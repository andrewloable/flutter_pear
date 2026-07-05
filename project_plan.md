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
   ├─ Autobase (prebuilt merge recipes: last-writer-wins, ordered-log, CRDT-map),
   │  blind-pairing
   └─ suspend/resume lifecycle hooks
```

- The plugin ships a **prebuilt, versioned JS bundle** (the "pear-end") built with `bare-pack`, exposing every module through a stable RPC schema. Devs never write JS unless they opt into a custom worklet.
- Escape hatch: `BareWorklet.start(customBundle)` for advanced users.
- Autobase specifically ships **named prebuilt recipes** rather than a generic `apply`/`open` surface — `PearBase` selects a recipe by name. A generic custom-recipe path stays available only via the custom-worklet escape hatch above, not the default API.

## 3. Repo & packages

Monorepo `flutter_pear`, managed with melos:

| Package | Contents |
|---|---|
| `flutter_pear` | Umbrella: high-level Dart API + bundled pear-end |
| `flutter_pear_bare` | Low-level Bare Kit bindings (worklet lifecycle, raw IPC) |
| `flutter_pear_test` | In-memory fake swarm/worklet — a fast dev-loop double devs can unit-test against without radios or peers (schema conformance consumer; the real worklet stays the actual conformance authority, see §5) |
| `flutter_pear_example` | Chat demo app (QR-pairing, desktop CLI peer); file-drop demo planned |
| `tools/` | pear-end build scripts, prebuild fetcher |

## 4. API coverage map (Pear module → Dart)

Single v0.1 release (Android) — every row below ships together, no staged preview slices.

| Pear/JS | Dart class | Epic |
|---|---|---|
| Bare Kit worklet | `BareWorklet` | E1/E4 |
| RPC contract (framing, typed errors, session/version handshake, connection state) | `PearRpc`, `PearException` hierarchy | E2 |
| Hyperswarm + secret-stream | `PearSwarm`, `PearConnection` (Stream/Sink of bytes) | E2 |
| hypercore-crypto | `PearCrypto` (keypairs, hashes, `unsafeTopicFromString` — real apps use `PearPairing` invites instead of a shared string topic) | E2 |
| Corestore + Hypercore | `PearStore`, `PearCore` (append, get, replicate, watch) | E5 |
| Hyperbee | `PearBee` (get/put/del, range streams, watch) | E5 |
| Hyperdrive + localdrive/mirror | `PearDrive` (files, mirror-to-disk; bulk transport is file-path import/export, see §7) | E5 |
| Autobase | `PearBase` (multi-writer, prebuilt recipes: LWW / ordered-log / CRDT-map) | E5 |
| blind-pairing | `PearPairing` (invites, device linking) | E5 |
| Lifecycle (suspend/idle/resume, hot-restart reattach-or-kill) | auto-wired to `AppLifecycleState`, overridable | E6 |

Everything surfaces as `Future`s and broadcast `Stream`s; binary data as `Uint8List`; keys as a `PearKey` value type with hex/z32 helpers.

## 5. Epics (E1–E9)

Live status lives in bd (`bd list --status=open`, `bd ready`) — this table is the durable map from epic to scope, not a status snapshot that will drift again.

| Epic | Scope |
|---|---|
| **E1 — M1 gate** | Real Bare Kit worklet replacing the native echo; the go/no-go proof is a Hyperswarm round trip (DHT discovery + Noise handshake + reconnect) between two independent processes, not a one-device IPC smoke test. **Downgraded to emulator-based (developer decision, no physical Android hardware available in this dev environment)**: passed via emulator↔desktop-peer; emulator↔emulator is confirmed failing on a NAT/UDP-hole-punch artifact of two emulators sharing one host's virtualized network (documented in the README, not a flutter_pear bug). Physical two-device hardware validation remains valuable but is no longer a precondition for this gate — tracked separately in `flutter_pear-doi` if hardware becomes available. |
| **E2 — RPC contract spine** | Reliability: per-call timeout, typed-exception routing by `err.code`, 1-byte frame-type discriminator, session nonce + bundle-version attach handshake, native crash observation feeding `worklet.onCrash`, `PearSwarm` connection-state stream with honest bounded failure (X8). |
| **E3 — flutter_pear_test** | In-memory fake swarm/worklet as a fast dev-loop double, failure-injection hooks, CI running the full suite against it. |
| **E4 — Native distribution** | Production Gradle fetcher (checksum, ABI, bundle install), fetch UX (progress, retry, fallback), INTERNET permission, release-mode (R8/app-bundle) verification. |
| **E5 — Data-structure wrappers** | Corestore/Hypercore → Hyperbee → Hyperdrive → pairing → Autobase-last, in that dependency order; the platform-channel throughput benchmark (E5.1) that settled the bulk-transport question (§7); the codegen checkpoint (hand-write the first wrappers, only generate if the third's boilerplate proves mechanical — it didn't, no codegen). |
| **E6 — Lifecycle + hot-restart** | Real native suspend/resume, auto lifecycle via `AppLifecycleState` with linger, hot-restart reattach-or-kill via the attach handshake, background-execution reality docs, reconnect/delivery semantics. |
| **E7 — Example app DX** | Committed runners (no `flutter create` hydrate step), QR-pairing chat with camera-denial + manual-code fallback, desktop CLI peer for one-phone devs, doctor tool (connectivity/DHT/NAT diagnostics + `--report` support bundle), pairing-combo matrix, file-drop demo. |
| **E8 — Docs + error DX** | README truth pass + snippet-compile CI, error catalog (problem+cause+fix+anchor per code), `unsafeTopicFromString` rename, install-time troubleshooting page, docs IA (concepts + how-tos), dartdoc/pana sweep, this reconciliation. |
| **E9 — CI/CD + publishing** | Reproducible bundle (pinned deps, committed lockfile), license enforcement, compatibility/toolchain table enforced by CI, device/ABI/release matrix, TTHW budget gate, Noise-confidentiality proof, publish-on-tag mechanics, publish-day checklist. |

**iOS is v0.2**, its own milestone (CocoaPods podspec, Xcode wiring, background-mode entitlements) — not a gate on the v0.1 Android release. iOS aggressively suspends background sockets regardless of anything this plugin does; gating the single release on it would delay v0.1 for a platform whose background story is constrained either way.

**Physical-hardware validation is deliberately deferred to one final pass** (`flutter_pear-doi`), run only if/when real Android devices become available in the dev environment — it is no longer a precondition for any epic's completion (developer decision: acceptance criteria downgraded to emulator-based validation across the board, since no physical hardware is available here). E1's own gate closed on an emulator↔desktop-peer proof; epics E1–E6 are complete on that basis. Real-device legs for each wrapper remain a nice-to-have follow-up, not a release blocker.

## 6. DevEx review — decisions that make or break adoption

**Install must be one line.** `flutter pub add flutter_pear` and it works. Native Bare Kit binaries and the pear-end bundle resolve via a Gradle task (Android, done — E4) + CocoaPods podspec (iOS, v0.2). *Zero* manual NDK/ABI/podfile edits. Verify by hand, before release (this project has no CI): create a new Flutter app, add the package, and build it (Android; iOS once v0.2 lands).

**No JavaScript visible by default.** The #1 DevEx risk is "install plugin, now learn bare-pack." Prebundling the pear-end removes it. Custom worklets are a documented advanced path with a `dart run flutter_pear:pack` wrapper so devs never install Bare tooling manually.

**Errors must travel.** JS exceptions in the worklet serialize across RPC into typed Dart exceptions (`PearConnectionException`, `PearStorageException`…) with the JS stack attached, demoted to a details field behind the four-part catalog entry (problem/cause/fix/doc anchor — E8). Worklet crashes are observed **natively** (not over RPC — a dead worklet can't serialize its own crash) and surfaced on `worklet.onCrash`; RPC-level per-call timeout is the separate hang-catcher for dropped frames. A silent worklet crash is the worst possible debugging experience.

**Connection honesty is an API property, not just a doctor feature (X8).** `PearSwarm`'s connection-state stream (discovering/connecting/connected/reconnecting/failed) has a bounded connect timeout and a typed failure reason (e.g. `E_UDP_BLOCKED`) with a docs escape path — an unreachable network becomes an honest, bounded failure instead of an infinite spinner.

**Session integrity.** A session nonce + bundle-version handshake on worklet attach (E2) means late responses/events from a pre-hot-restart session can never be misattributed to the new one, and a bundle-version mismatch triggers a clean kill+restart instead of a silent stale reattach.

**Hot reload/restart correctness.** Detect existing worklets on restart, reattach or cleanly kill. Shipped in v0.1 (E6); it's the first thing every dev hits.

**Lifecycle by default.** Auto suspend/resume wired to app lifecycle with sane linger; document loudly what iOS/Android actually allow in background so devs don't blame the library for OS kills.

**Time-to-first-success: champion tier, under 5 minutes.** Committed target (not the earlier draft's 15-minute goal): clone → `melos bootstrap` → `flutter run` × 2 → QR scan → message on both screens, under 5 minutes. Enforced by a CI TTHW budget gate (fails over budget, E9.3) plus a quarterly `/devex-review` boomerang on the live package (CI can't feel device auth prompts or cold caches). One-phone devs reach the same moment via the desktop CLI peer (E7/X7).

**API feel.** Streams for events, Futures for calls, `async`/`await` everywhere, no callbacks; `dispose()` conventions matching Flutter norms; strong docs on every public symbol (pub.dev score depends on it).

**Testing story for users.** Ship `flutter_pear_test` helpers: in-memory fake swarm/core so app devs can unit-test without radios or peers.

**Tooling & governance.** melos monorepo; CHANGELOG; issue templates ("include `flutter doctor` + worklet log"); pin the pear-end module versions and publish a compatibility table (plugin ↔ Bare Kit ↔ Hyper* versions) enforced by CI (E9.5); "unofficial, not affiliated with Holepunch" in README; MIT/Apache-2.0 license to match ecosystem. Publishing itself is a tag-triggered workflow — tag → dry-run publish all three packages in order → manual approval gate → real publish (E9.7) — see §9 for why this replaced the earlier semantic-release idea.

**Starter template repo: post-v0.1, built only on observed friction** (`flutter_pear-uqs`). For v0.1 the committed example app + README quick start cover time-to-first-success; a `flutter create --template`-style starter only earns its keep if post-publish issues/discussions actually show new-project setup friction.

**Docs structure (mirrors Pear's own, lowering concept-transfer cost):** Quick start → Concepts (topics-vs-invites first, then worklet model, replication) → How-tos (chat, file sync, pairing) → API reference → Troubleshooting (install-time failure classes, NAT/relay behavior, background limits).

## 7. Risks

| Risk | Mitigation |
|---|---|
| Bare Kit API churn (some modules pre-1.0) | Pin versions; compatibility table enforced by CI (E9.5) |
| Native prebuild distribution breaks builds | Fresh-install CI; production Gradle fetcher with checksum + retry + manual fallback (E4 — done) |
| Platform-channel throughput too low for Hyperdrive | **Decided (E5.1):** benchmarked first; default is file-path import/export (worklet writes to disk, Dart reads the file) rather than in-channel chunking. An FFI fast path or a generic streaming protocol stays an escape hatch, only built if a future throughput regression demands it — not designed in speculatively. |
| iOS background kills swarms, devs blame library | Prominent docs + lifecycle API from v0.1; iOS itself is v0.2, so this applies once that milestone starts |
| Solo-maintainer burnout | Small core (`flutter_pear_bare`) kept minimal; invite contributors per data-structure package |

## 8. Success criteria

Clone → two-peer chat in **under 5 minutes** (champion tier, CI-timed + quarterly human audit — see §6); pub.dev score ≥130; hot restart never requires app reinstall; issue tracker not dominated by build failures; at least one community app shipped on it.

## 9. Decisions log (decide-or-drop items resolved during the E8.8 reconciliation, 2026-07-04)

These were carried as open questions from the original draft plan and the office-hours design review; resolving them here so they don't linger as ambiguous scope.

- **Semantic-release — DROPPED.** Superseded by E9.7's tag-triggered publish workflow (tag → dry-run all three packages in dependency order → manual approval gate → real publish). That mechanism already gives ordered, reviewable releases without an additional commit-message-driven versioning tool; adding one on top would be redundant process for a small monorepo.
- **"Track upstream releases in CI" — DROPPED as a dedicated automated job.** The compatibility/toolchain table (E9.5) already gives a CI-enforced, manually-bumped contract between the plugin, Bare Kit, and the Hyper* family; the bump procedure it documents is the intended way version drift gets noticed and handled. A separate renovate/dependabot-style bot for a two-surface pin (Bare Kit + pear-end JS deps) isn't worth the maintenance overhead right now — revisit only if the manual bump procedure demonstrably misses a break.
- **M0 "post intent on `holepunchto/bare-kit` discussions" — DROPPED.** This was meant to surface blockers *before* investing in the risky M1 spike. That spike (E1) is done and passed (worklet boots, joins, relays on Android/CI); the moment this action was meant to serve has passed. Nothing prevents posting about the project once it's further along, but it's no longer a plan item with its own acceptance criteria.
