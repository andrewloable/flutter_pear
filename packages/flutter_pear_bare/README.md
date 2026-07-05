# flutter_pear_bare

Low-level [Bare Kit](https://github.com/holepunchto/bare-kit) worklet bindings for
[`flutter_pear`](../flutter_pear): worklet lifecycle
(`start` / `terminate` / `suspend` / `resume`) and raw binary IPC.

Most apps use `flutter_pear`, not this package directly.

> Android-only for now (v0.1). iOS is its own v0.2 milestone (not started). The
> worklet is the real Bare Kit worklet — it boots, joins Hyperswarm, and relays
> bytes over this package's binary IPC, not a native-echo stand-in — with
> lifecycle (start/terminate, auto suspend/resume, hot-restart reattach-or-kill)
> verified on Android emulator/CI. The two-device hardware round trip is the
> one thing still deferred, to a final hardware-validation pass run once every
> other epic's automated suite is green (see the repository's `project_plan.md`
> for exact status).
