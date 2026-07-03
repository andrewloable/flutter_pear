# flutter_pear_bare

Low-level [Bare Kit](https://github.com/holepunchto/bare-kit) worklet bindings for
[`flutter_pear`](../flutter_pear): worklet lifecycle
(`start` / `terminate` / `suspend` / `resume`) and raw binary IPC.

Most apps use `flutter_pear`, not this package directly.

> Android-only for now (M0). iOS lands in M1. The worklet is currently a native
> echo that proves the Dart↔IPC round trip; the real Bare Kit worklet swaps in
> behind the same channels.
