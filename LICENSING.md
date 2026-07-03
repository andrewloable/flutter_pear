# Licensing

## flutter_pear's own code

**MIT** © 2026 Andrew Loable — see [LICENSE](LICENSE). Every published package
(`flutter_pear`, `flutter_pear_bare`, …) must carry its own copy of this
`LICENSE` file (pub.dev requires it; a missing one costs score points).

## What we bundle, and under what license

flutter_pear redistributes the Pear stack two ways:

- the **pear-end** JavaScript bundle (Hyper\* modules, built with bare-pack), and
- prebuilt **Bare Kit** native binaries.

Everything in that graph is **permissive — MIT or Apache-2.0. There is no
copyleft (no GPL / AGPL / LGPL / MPL / SSPL) anywhere.** Upstream lives in the
`holepunchto` GitHub org (not `tetherto` — that org is apps/wallet/AI, none of
which we depend on).

| MIT | Apache-2.0 |
|---|---|
| hypercore, hyperbee, hyperswarm, hyperdht, protomux, hypercore-crypto, corestore¹, sodium-native | bare, bare-kit, hyperdrive, autobase, compact-encoding, blind-pairing, localdrive, mirror-drive, hyperblobs, hyperschema, hyperdispatch, b4a |

¹ corestore ships no `LICENSE` file, but its `package.json` declares MIT.
secret-stream is pulled in transitively via hyperswarm. The build-time collector
(below) is the source of truth — it captures whatever the resolved tree actually
contains.

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
