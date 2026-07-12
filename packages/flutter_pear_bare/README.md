# flutter_pear_bare

Low-level [Bare Kit](https://github.com/holepunchto/bare-kit) worklet bindings for
[`flutter_pear`](https://pub.dev/packages/flutter_pear): worklet lifecycle
(`start` / `terminate` / `suspend` / `resume`) and raw binary IPC.

Most apps use `flutter_pear`, not this package directly.

> **Platforms:** Android (stable) · iOS (SIMULATOR-VALIDATED —
> see [iOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md))
> · macOS/Linux/Windows desktop (new in 0.3.0 — a subprocess-spawned `bare`
> runtime, not BareKit, since no BareKit build exists for desktop; see each
> platform's own notes linked from
> [Desktop dev setup](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/desktop-dev.md)).
> The worklet is the real Bare Kit worklet on mobile, and the real `bare`
> CLI runtime on desktop — it boots, joins Hyperswarm, and relays bytes over
> this package's binary IPC, not a native-echo stand-in — with lifecycle
> (start/terminate, auto suspend/resume, hot-restart reattach-or-kill)
> verified on a real Android emulator, the iOS Simulator, and real
> macOS/Linux/Windows hardware. Physical two-device mobile hardware
> validation remains a nice-to-have follow-up, not a release blocker (see
> the repository's `project_plan.md` for exact status).
