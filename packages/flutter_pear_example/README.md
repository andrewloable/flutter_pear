# flutter_pear_example

M0 demo: type text, watch it echo back through the worklet — proving the
Dart↔IPC round trip (Android only for now).

## Run

Platform runner folders aren't checked in. Hydrate them once, then run:

```bash
cd packages/flutter_pear_example
flutter create --platforms=android .   # generates android/ runner
flutter run                            # on a connected Android device
```

The M0 native side echoes IPC frames; the Bare Kit worklet + PearSwarm chat demo
land in M1.
