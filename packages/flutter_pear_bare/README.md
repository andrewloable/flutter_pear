# flutter_pear_bare

Low-level [Bare Kit](https://github.com/holepunchto/bare-kit) worklet bindings for
[`flutter_pear`](https://pub.dev/packages/flutter_pear): worklet lifecycle
(`start` / `terminate` / `suspend` / `resume`) and raw binary IPC.

Most apps use `flutter_pear`, not this package directly.

> **Platforms:** Android (stable) · iOS (new in 0.2.0, SIMULATOR-VALIDATED —
> see [iOS platform notes](https://github.com/andrewloable/flutter_pear/blob/main/packages/flutter_pear/doc/ios.md)).
> The worklet is the real Bare Kit worklet — it boots, joins Hyperswarm, and
> relays bytes over this package's binary IPC, not a native-echo stand-in —
> with lifecycle (start/terminate, auto suspend/resume, hot-restart
> reattach-or-kill) verified on a real Android emulator and the iOS
> Simulator. Physical two-device hardware validation on both platforms
> remains a nice-to-have follow-up, not a release blocker (see the
> repository's `project_plan.md` for exact status).
