## 0.0.1

- `BareWorklet` low-level API: lifecycle (`start`/`terminate`/`suspend`/`resume`,
  hot-restart reattach-or-kill) and raw binary IPC to the real Bare Kit
  worklet on Android — boots, joins Hyperswarm, and relays bytes; verified on
  Android emulator/CI. The physical two-device hardware round trip is
  deferred to a later hardware-validation pass. iOS is a separate, not-yet-
  started v0.2 milestone.
