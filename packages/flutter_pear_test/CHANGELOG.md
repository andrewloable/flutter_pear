## 0.4.6

No code or behaviour change to this package. Version bump to stay in
lockstep with `flutter_pear` and `flutter_pear_bare` 0.4.6. Their changes are an
opt-in persistent swarm identity inside `pear-end`, desktop bundles moving
into `flutter_pear_bare`, and a Windows `terminate()` hang fix. None of them
touches the in-memory fake.

## 0.4.5

The in-memory hub honours `join(announce:, acceptUnannounced:)`: two worklets
connect only if at least one announces and each side can attribute the
connection (by the other's announcement, or by accepting unannounced), as with
real Hyperswarm + pear-end. Where pear-end would leave a dial-only peer holding
a silent connection, the fake makes none.

## 0.4.4

The in-memory fake now answers `dht.status` like the real worklet does: an
in-memory hub is always reachable, so it always reports
`{online: true, firewalled: false}`. Version bump to stay in lockstep with
`flutter_pear` 0.4.4.

