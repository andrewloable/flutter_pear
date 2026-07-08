# Licensing

## flutter_pear's own code

**MIT** © 2026 Andrew Loable — see [LICENSE](LICENSE). Every published package
(`flutter_pear`, `flutter_pear_bare`, …) must carry its own copy of this
`LICENSE` file (pub.dev requires it; a missing one costs score points).

## What we bundle, and under what license

flutter_pear redistributes the Pear stack three ways:

- the **pear-end** JavaScript bundle (Hyper\* modules, built with bare-pack),
- prebuilt **Bare Kit** native binaries (Android, via Gradle fetch; iOS, via
  a maintainer-repacked release asset — see below), and
- prebuilt **native addon** binaries (`sodium-native`, `udx-native`, etc.) —
  Android `.so` files under `flutter_pear_bare/android/.../jniLibs/`, iOS
  `.xcframework` bundles under `flutter_pear_bare/ios/addons/`, the same
  underlying addon set on both platforms.

**iOS-specific redistribution note:** upstream `holepunchto/bare-kit`
(**Apache-2.0**, per the license table below) ships one multi-platform
`prebuilds.zip` per release; SwiftPM's `binaryTarget` mechanism needs a
single, ready-made xcframework zip rather than a build-time extraction step,
so this repo's maintainer extracts `BareKit.xcframework` from that upstream
zip, re-zips it standalone, and republishes it as a GitHub release asset on
this repo (`andrewloable/flutter_pear`) — checksum-pinned in
`flutter_pear_bare/barekit-pin.json`. This is a repackaging, not a
relicensing: the redistributed binary is still Apache-2.0 (Bare Kit's own
license), unmodified except for its zip container, and the Apache-2.0 §4
obligations below apply to it exactly as they do to the pear-end bundle.

Everything in that graph is **permissive — MIT or Apache-2.0. There is no
copyleft (no GPL / AGPL / LGPL / MPL / SSPL) anywhere.** Upstream lives in the
`holepunchto` GitHub org (not `tetherto` — that org is apps/wallet/AI, none of
which we depend on).

| MIT | Apache-2.0 |
|---|---|
| hypercore, hyperbee, hyperswarm, hyperdht, protomux, hypercore-crypto, corestore¹, sodium-native, streamx, dht-rpc, kademlia-routing-table | bare, bare-kit, hyperdrive, autobase, compact-encoding, blind-pairing, blind-pairing-core, localdrive, mirror-drive, hyperblobs, hyperschema, hyperdispatch, b4a, hypercore-storage, rocksdb-native² |

¹ corestore ships no `LICENSE` file, but its `package.json` declares MIT.
secret-stream is pulled in transitively via hyperswarm. The build-time collector
(below) is the source of truth — it captures whatever the resolved tree actually
contains.

² rocksdb-native (Autobase/Hypercore's storage engine, E5.7) fetches external
C++ source at build time via CMake (`holepunchto/librocksdb`,
`holepunchto/libjstl`) — outside `node_modules`, so the JS-based
`THIRD_PARTY_LICENSES` collector can't see it. Both are confirmed **Apache-2.0**
on GitHub. This matters specifically because upstream Facebook RocksDB is
dual-licensed **Apache-2.0 / GPLv2** — the `holepunchto` fork/mirror fetched
here is the Apache-2.0 branch, not GPLv2, so the permissive guarantee holds,
but call this out explicitly since it's the one native addon in this tree
pulling in an external build-time dependency rather than a plain npm package.

> GitHub may label some upstream repos `NOASSERTION` — that's a **markdown-formatted
> Apache-2.0** the SPDX matcher can't byte-match, not a custom license.

## Is MIT + Apache-2.0 OK? Yes.

- An MIT project may bundle Apache-2.0 modules. They are **not relicensed** — each
  module keeps its own license; only flutter_pear's own source is MIT.
- No viral/copyleft obligations attach.
- Apache-2.0's one notable incompatibility is with **GPLv2** — irrelevant here,
  and a reason never to add a GPL dependency.

## Obligations when we redistribute (Apache-2.0 §4)

Because the shipped bundle contains Apache-2.0 code, the package must include:

1. A copy of the **Apache License 2.0** text.
2. The **NOTICE** file contents of every bundled Apache-2.0 module that ships one.
3. Preserved **copyright, patent, trademark, and attribution** notices from the source.
4. A **statement of changes** for any upstream module whose source we modify.

MIT modules require only their copyright + permission notice be preserved.

## How this repo satisfies it

- **`LICENSE`** — flutter_pear's MIT license (our code), per package.
- **`NOTICE`** — aggregated attributions for bundled Apache-2.0 modules.
- **`THIRD_PARTY_LICENSES`** — a generated asset listing every bundled module and
  its full license text. `dart run flutter_pear:pack` collects
  `pear-end/node_modules/*/{LICENSE,NOTICE}` into it; **regenerate whenever the
  pear-end dependency set or Bare Kit version changes.**
- **Compatibility table** (project plan §6) pins plugin ↔ Bare Kit ↔ Hyper\*
  versions alongside their licenses.

## Rule for adding a dependency

Before adding any module to `pear-end` (or a native binary), confirm its license
is **MIT / Apache-2.0 / BSD / ISC / 0BSD**. **Reject GPL / AGPL / LGPL / MPL /
SSPL or unlicensed ("all rights reserved") code** — it breaks the permissive
guarantee this package depends on. Never pull in `tetherto` **application** repos
(PearPass, `pear-apps-*`, `wdk-*`) — they're products, not our building blocks.

## Affiliation

Unofficial. Not affiliated with Holepunch or Tether.
