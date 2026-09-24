## 0.4.4

The in-memory fake now answers `dht.status` like the real worklet does: an
in-memory hub is always reachable, so it always reports
`{online: true, firewalled: false}`. Version bump to stay in lockstep with
`flutter_pear` 0.4.4.

