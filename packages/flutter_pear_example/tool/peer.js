#!/usr/bin/env node
'use strict'

// E7.3 (X7): the desktop half of the "one-phone dev" story -- a second peer
// for flutter_pear's example chat that runs on the developer's laptop
// instead of a second phone, and doubles as a scriptable CI peer.
//
// Deliberately plain Node, not a Bare worklet: there is no Flutter/platform
// channel to bridge to here, so none of pear-end's BareKit.IPC glue
// applies -- this talks Hyperswarm/Protomux directly, the same libraries
// pear-end/index.js wraps for the mobile worklet. Modules resolve through
// pear-end's OWN node_modules (see pearEndRequire below) rather than a
// second copy, so this peer is always running the exact same pinned
// versions the phone side does -- a second, independently `npm install`-ed
// copy could silently drift to a wire-incompatible minor version.
//
// Topic mode only (`--topic <name>`) -- an invite-based mode
// (`--invite`/`--create-invite`, joining via a PearPairing invite instead
// of a shared string) was attempted and pulled before shipping: it
// consistently failed blind-pairing's own MemberRequest.open() decrypt/
// signature check ("Failed to open invite with provided key") even after
// fixing two real bugs along the way (passing resourceKey instead of
// createInvite's returned publicKey to request.open(); passing undefined
// instead of an explicit Buffer.alloc(0) for userData) -- reproduced even
// in a same-process, no-network unit repro, so this isn't network flakiness.
// Tracked as flutter_pear-<TBD> for follow-up; the phone side doesn't have
// an invite-creation UI yet either (that's E7.2), so nothing regresses by
// shipping topic mode alone now.
//
// --bootstrap <host:port,...> (internal/advanced, undocumented in the usage
// string on purpose): overrides Hyperswarm's default REAL, public DHT
// bootstrap nodes. A human running this to pair two real devices always
// wants the real DHT, so this is never needed interactively -- it exists so
// tool/peer.check.js's automated round-trip checks can point every spawned
// peer at a private, local, fully offline hyperdht/testnet instead (same
// technique pear-end/test/pairing-real-roundtrip.test.js already uses),
// which is what actually fixes the flakiness a fixed --topic string had on
// the real DHT: two peers on a shared local testnet can ONLY ever discover
// each other through that testnet's own bootstrap nodes, so even a fixed
// topic can no longer rendezvous with an unrelated concurrent run anywhere
// else, AND there is no real-network latency/packet-loss/NAT path left to
// be flaky in the first place.
//
// A local testnet this small (a handful of nodes, sub-millisecond latency)
// has its own gotcha, already documented and solved once in this repo at
// pear-end/test/noise-confidentiality.test.js ("SECOND GOTCHA"): if two
// peers join the SAME topic in the same instant, Hyperswarm's own
// PeerDiscovery picks EITHER announce OR lookup per refresh cycle (never
// both), so neither one observes the other's freshly-landed announce during
// its own single pass -- confirmed here too, empirically: two --bootstrap'd
// peer.js processes spawned back-to-back never connected, even after 15s of
// polling, while staggering one peer's join fully flushed before the next
// starts connects reliably. That's why the join below awaits its own
// `.flushed()` and prints a distinct, detectable line once it completes --
// tool/peer.check.js's checks wait for that line from the FIRST spawned
// peer before spawning the second, the same stagger-then-connect shape
// `joinAndWait` uses in the test file above.
//
// --drive mode (flutter_pear-d5w): acts as a file-drop peer instead of a
// chat peer -- opens/creates a Hyperdrive, exchanges its key with whoever
// connects over the SAME 'pear-connection-data' Protomux channel chat mode
// uses (confirmed via index.js: Method.CONNECTION_WRITE/CONNECTION_DATA and
// file_drop_screen.dart's drive-key announcement both ultimately go through
// the one per-connection message on that channel -- there's no separate
// wire protocol to match, just a different payload), replicates both
// directions (chained core-then-blobs replication onto the same stream,
// matching index.js's own replicateOverPeer), and can --put a local file
// into its drive or --mirror-to a directory once it learns a peer's drive
// key. Exists because tool/peer.js's chat mode has no Hyperdrive support of
// its own, and there was previously no way to validate E7.7's file-drop
// phone<->desktop leg without two physical phones.
//
// --store mode (flutter_pear-doi, the E5.2/2vz.2 desktop leg): the plain
// Hypercore analog of --drive, and the simplest of the three data-structure
// wrappers -- a single core, no blobs/second-core chaining. Opens a local
// writer core via store.get({ name: 'local' }) (matching index.js's
// Method.STORE_GET exactly), optionally appends `--append` values to it,
// announces its own public key over the same 'pear-connection-data' channel
// the other modes use, and once it learns a peer's key opens a read-only
// session for it via store.get(<32-byte key>) -- again matching
// Method.STORE_GET's key-vs-name branch exactly, not a from-scratch guess at
// the API shape. `--expect-count <n>` reads back n entries with core.get(i)
// (which waits for the block to replicate in, by default -- the same
// wait-by-default semantics index.js's own Method.CORE_GET relies on, no
// manual length-polling needed) and prints each as a `core-entry[i]: <b64>`
// line so tool/peer.check.js can assert byte-exact, in-order content.
//
// --bee mode (flutter_pear-doi, the E5.3/2vz.3 desktop leg): opens/creates a
// Hyperbee on a fresh Hypercore with the EXACT same construction index.js's
// Method.BEE_OPEN uses (`new Hyperbee(core, { keyEncoding: 'binary',
// valueEncoding: 'binary' })`) -- a mismatched encoding on either side would
// silently miscompare every key/value (different bytes for "the same"
// logical string) rather than throw, so this can't be approximated. Same
// key-announcement handshake as --drive/--store, and the same single-
// replicate() chaining as --store (a Hyperbee is just a B-tree encoded onto
// one Hypercore, nothing extra to chain). Once a peer's key is learned, this
// wraps it in a READ-ONLY Hyperbee view (store.get(peerKey) can't be a
// writer here -- this process never held that core's secret key) and sets
// up bee.watch() on it, matching index.js's own Method.BEE_WATCH handler
// (consumes the Watcher's async-iterator in a detached loop).
//
// Puts arrive over stdin as `key=value` lines (like chat mode's raw lines),
// NOT as a --store-style preloaded `--append` CLI list, and this is a
// deliberate, load-bearing difference, not stylistic: Hyperbee's Watcher
// takes its baseline snapshot the moment it starts (`_open()` sets
// `this.current = this.bee.snapshot()`) and only ever fires on a FUTURE
// version bump after that point. A --store-style put preloaded before the
// swarm connection even exists would very likely already be included in
// that baseline snapshot by the time this side finishes replicating in and
// calls watch() -- the watcher would then sit forever waiting for a change
// that already happened, and the whole point of this harness (proving a
// watch fires FROM real replication) would silently never be exercised.
// Driving the put from a live stdin line lets tool/peer.check.js wait for
// both sides to report "learned peer's bee key" (watch already armed)
// before sending it, so the fire is provably caused by an append that
// happens AFTER the watcher's baseline, not one absorbed into it.
//
// On every watch fire, re-reads the peer's bee through its ordinary
// createReadStream() path (the same path .get()/range reads use), not the
// Watcher's own internal diff snapshots -- proves the new value is genuinely
// durable and queryable post-replication, matching flutter_pear-2vz.3's own
// deferred VALIDATION wording ("...observable afterward via .get()"), and
// prints each entry as `bee: <key>=<value>` for tool/peer.check.js to match
// on, the same convention chat mode's `peer: <message>` lines use.
//
// --base mode (flutter_pear-doi / E5.7-E5.8 / flutter_pear-2vz.8): drives a
// real Autobase (the "lww" recipe from autobase-recipes.js -- the SAME file
// index.js's Method.BASE_OPEN/BASE_APPEND load, not a reimplementation) over
// a real two-process Hyperswarm connection, and specifically validates the
// TWO-WRITER CONVERGENCE property flutter_pear-doi's own notes call out by
// name: peer A and peer B each append a put() for a DIFFERENT key while
// mutually unaware of each other, then replicate, and both must converge to
// one identical view containing BOTH keys -- not just a single append
// round trip (already covered, in-process, by autobase-recipes.test.js).
//
// Unlike --drive's two independently-creatable-then-merged drives, an
// Autobase's second writer can't be constructed independently and merged in
// later: index.js's own BASE_OPEN passes a reopen's `key` straight to `new
// Autobase(store, key, opts)` as the BOOTSTRAP key, which must be known
// BEFORE construction. So this is a real two-step handshake, not a
// symmetric announce-immediately swap like --drive/--store/--bee's single
// key exchange: --base-role host creates a fresh Autobase (bootstrap null)
// and announces its own local writer key first; --base-role join waits to
// receive that key before it can even construct its own Autobase instance,
// then announces ITS OWN local writer key back so the host can `addWriter`
// it.
//
// A real, empirically-confirmed race this handshake has to survive: a
// freshly-joined Autobase is NOT immediately writable the instant it's
// constructed against the host's bootstrap key -- base.append() reliably
// throws "Not writable" (confirmed against autobase's own source:
// `this.localWriter` stays null) until the host's addWriter op has actually
// replicated back and been causally applied on this replica. A same-machine,
// no-retry repro reproduced this on the very first attempt, every time --
// appendWhenWritable below retries past it. What this does NOT need,
// despite what autobase-recipes.test.js's own manual `base.append(null)`
// "force ack" step might suggest is required: becoming writable in practice
// never waited on Autobase's default 10s background ack timer in any run of
// this repro -- it only needed the addWriter op itself to round-trip, which
// happens as fast as ordinary replication (well under a second on
// localhost). That test's manual ack exists because IT disables the ack
// timer entirely (`ackInterval: 0`) for speed; this harness deliberately
// uses index.js's own PRODUCTION Autobase options (no ackInterval/
// ackThreshold override) so it proves the real default-ack behavior
// interops, not a sped-up test double of it.

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const crypto = require('node:crypto')
const readline = require('node:readline')
const { pipeline } = require('node:stream/promises')
const { createRequire } = require('node:module')

const pearEndRequire = createRequire(
  path.join(__dirname, '..', '..', 'flutter_pear', 'pear-end', 'package.json')
)
const Hyperswarm = pearEndRequire('hyperswarm')
const Protomux = pearEndRequire('protomux')
const c = pearEndRequire('compact-encoding')
const Corestore = pearEndRequire('corestore')
const Hyperdrive = pearEndRequire('hyperdrive')
const Localdrive = pearEndRequire('localdrive')
const Hyperbee = pearEndRequire('hyperbee')
const Autobase = pearEndRequire('autobase')
// './autobase-recipes', not a node_modules package -- resolves relative to
// pear-end's OWN package.json directory (same createRequire trick as every
// other pearEndRequire call above), so --base drives the EXACT same recipe
// file index.js's Method.BASE_OPEN/BASE_APPEND load, not a second copy.
const { RECIPES, validateAddWriter } = pearEndRequire('./autobase-recipes')

// Matches PearCrypto.unsafeTopicFromString exactly (SHA-256 of the UTF-8
// string) so `--topic <name>` lands in the same room as the phone demo's
// "Shared room name" field.
function topicFromString (name) {
  return crypto.createHash('sha256').update(name, 'utf8').digest()
}

// Shared by --bootstrap below: `host:port,host:port,...` -> [{host, port}],
// the exact shape Hyperswarm/hyperdht's own `bootstrap` constructor option
// expects (and exactly what a hyperdht/testnet's `.bootstrap` array already
// is -- see tool/peer.check.js, the only caller of --bootstrap today). Split
// on the LAST colon, not the first, so a bracketed/raw IPv6 host wouldn't
// get mangled (not exercised today -- testnets bind 127.0.0.1 -- but cheap
// to get right).
function parseBootstrapFlag (raw) {
  return raw.split(',').map((pair) => {
    const idx = pair.lastIndexOf(':')
    if (idx === -1) throw new Error(`--bootstrap entries must be host:port, got: ${pair}`)
    const port = Number(pair.slice(idx + 1))
    if (!Number.isInteger(port) || port <= 0) {
      throw new Error(`--bootstrap port must be a positive integer, got: ${pair}`)
    }
    return { host: pair.slice(0, idx), port }
  })
}

function parseArgs (argv) {
  const args = { timeoutMs: 30000 }
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--topic':
        args.topic = argv[++i]
        break
      case '--timeout': {
        const seconds = Number(argv[++i])
        // A malformed/missing value must fail loudly here, not become NaN
        // -- setTimeout(fn, NaN) fires almost immediately, which would
        // otherwise surface as a spurious "no peer connected" instead of a
        // usage error.
        if (!Number.isFinite(seconds) || seconds <= 0) {
          throw new Error(`--timeout must be a positive number of seconds, got: ${argv[i]}`)
        }
        args.timeoutMs = seconds * 1000
        break
      }
      case '--drive':
        args.drive = true
        break
      case '--put':
        args.put = argv[++i]
        break
      case '--mirror-to':
        args.mirrorTo = argv[++i]
        break
      case '--storage':
        args.storage = argv[++i]
        break
      case '--store':
        args.store = true
        break
      case '--bee':
        args.bee = true
        break
      case '--append':
        // Repeatable -- one push per occurrence, so `--append a --append b`
        // appends two separate blocks in the order given, matching how a
        // real caller would append entries one at a time rather than
        // batching them into a single array argument.
        args.appends = args.appends || []
        args.appends.push(argv[++i])
        break
      case '--expect-count': {
        const n = Number(argv[++i])
        // Same "fail loudly, don't let a bad value silently become NaN"
        // rationale as --timeout above: a NaN/negative expect-count would
        // make the read-back loop below either run zero iterations (silent
        // false pass) or index negatively, not fail with a clear message.
        if (!Number.isInteger(n) || n < 0) {
          throw new Error(`--expect-count must be a non-negative integer, got: ${argv[i]}`)
        }
        args.expectCount = n
        break
      }
      case '--base':
        args.base = true
        break
      case '--base-role':
        args.baseRole = argv[++i]
        break
      case '--base-put':
        args.basePut = parseKeyValueFlag('--base-put', argv[++i])
        break
      case '--base-expect':
        args.baseExpect = parseKeyValueFlag('--base-expect', argv[++i])
        break
      case '--bootstrap':
        // Internal/advanced flag, deliberately absent from the usage string
        // below: overrides Hyperswarm's default REAL, public, internet-wide
        // DHT bootstrap nodes with an explicit list. Exists solely so
        // tool/peer.check.js can isolate its automated round-trip checks
        // onto a private, local, fully offline hyperdht/testnet (the same
        // technique pear-end/test/pairing-real-roundtrip.test.js already
        // uses for the same reason) instead of every check racing every
        // other real user/CI job anywhere for the same fixed --topic on the
        // actual internet DHT -- a REAL, empirically-confirmed source of
        // flakiness (intermittent connect timeouts and, once, a topic
        // collision with an unrelated concurrent run) that a human pairing
        // two real devices never wants opted into by default.
        args.bootstrap = argv[++i]
        break
      default:
        throw new Error(`unknown argument: ${argv[i]}`)
    }
  }
  if (!args.topic) {
    throw new Error('usage: peer.js --topic <name> [--timeout <seconds>] ' +
      '[--drive [--put <file>] [--mirror-to <dir>] [--storage <dir>]] ' +
      '[--store [--append <value>]... [--expect-count <n>] [--storage <dir>]] ' +
      '[--bee [--storage <dir>]] ' +
      '[--base --base-role <host|join> --base-put <key>=<value> --base-expect <key>=<value> [--storage <dir>]]')
  }
  const modeCount = [args.drive, args.store, args.bee, args.base].filter(Boolean).length
  if (modeCount > 1) {
    throw new Error('--drive, --store, --bee, and --base are mutually exclusive')
  }
  if ((args.put || args.mirrorTo) && !args.drive) {
    throw new Error('--put/--mirror-to only apply with --drive')
  }
  if (args.storage && !args.drive && !args.store && !args.bee && !args.base) {
    throw new Error('--storage only applies with --drive, --store, --bee, or --base')
  }
  if ((args.appends || args.expectCount !== undefined) && !args.store) {
    throw new Error('--append/--expect-count only apply with --store')
  }
  if ((args.baseRole !== undefined || args.basePut !== undefined || args.baseExpect !== undefined) && !args.base) {
    throw new Error('--base-role/--base-put/--base-expect only apply with --base')
  }
  if (args.base && (!args.baseRole || !args.basePut || !args.baseExpect)) {
    throw new Error('--base requires --base-role <host|join>, --base-put <key>=<value>, and --base-expect <key>=<value>')
  }
  if (args.base && args.baseRole !== 'host' && args.baseRole !== 'join') {
    throw new Error(`--base-role must be "host" or "join", got: ${args.baseRole}`)
  }
  return args
}

// Shared by --base-put/--base-expect -- both take the same "<key>=<value>"
// shape, plain UTF-8 on the CLI (the recipe's own wire format is base64, see
// runBase, but forcing a caller to pre-encode base64 by hand would just
// invite silently-wrong-because-unencoded values in a hand-typed check
// invocation).
function parseKeyValueFlag (flagName, raw) {
  const eq = raw == null ? -1 : raw.indexOf('=')
  if (eq === -1) throw new Error(`${flagName} must be in the form <key>=<value>, got: ${raw}`)
  return { key: raw.slice(0, eq), value: raw.slice(eq + 1) }
}

async function main () {
  const args = parseArgs(process.argv.slice(2))
  const swarm = new Hyperswarm(args.bootstrap ? { bootstrap: parseBootstrapFlag(args.bootstrap) } : {})
  // destroy() rejecting must never hang the process -- this tool's entire
  // point is a reliable exit code (CI usability), so both destroy() sites
  // below force the intended exit regardless of how destroy() itself
  // settles.
  process.on('SIGINT', () => {
    swarm.destroy().catch(() => {}).then(() => process.exit(0))
  })

  const topic = topicFromString(args.topic)
  if (args.drive) await runDrive(args, swarm, topic)
  else if (args.store) await runStore(args, swarm, topic)
  else if (args.bee) await runBee(args, swarm, topic)
  else if (args.base) await runBase(args, swarm, topic)
  else runChat(args, swarm, topic)

  // Await the join's own flushed() (one full announce/lookup round) instead
  // of firing it and moving on -- see the --bootstrap comment above for why
  // this specific ordering (and the distinct log line right after) is what
  // lets tool/peer.check.js stagger two peers' joins reliably against a
  // local testnet. Real-DHT interactive use is unaffected beyond a harmless
  // extra beat before these lines print -- flushed() resolves long before
  // any actual peer connection would form anyway.
  const discovery = swarm.join(topic, { server: true, client: true })
  console.error(`topic: ${topic.toString('hex')}`)
  await discovery.flushed()
  console.error('joined swarm (announce/lookup flushed)')
}

// Original chat mode -- unchanged.
function runChat (args, swarm, topic) {
  let connected = false
  // A single readline interface + a rebindable "current" message channel,
  // not one interface per connection -- stdin is one stream regardless of
  // how many times a peer reconnects, and re-creating the interface on
  // every reconnect would stack duplicate 'line' listeners (each firing on
  // every future line) plus an eventual MaxListenersExceededWarning.
  let currentMessage = null
  readline.createInterface({ input: process.stdin }).on('line', (line) => {
    currentMessage?.send(Buffer.from(line, 'utf8'))
  })
  const connectTimer = setTimeout(() => {
    if (connected) return
    console.error(`no peer connected within ${args.timeoutMs}ms`)
    process.exitCode = 1
    swarm.destroy().catch(() => {}).then(() => process.exit(1))
  }, args.timeoutMs)

  // Raw app data must go through a Protomux channel, not conn.write()/
  // conn.on('data') directly -- pear-end wraps every connection in
  // Protomux too (for blind-pairing's own use of the same stream), and a
  // second independent raw listener would see bytes Protomux's framing
  // doesn't recognize and destroy the connection (see index.js's own
  // comment on this for the full story). Same protocol name and encoding
  // as pear-end's Method.CONNECTION_DATA/CONNECTION_WRITE handling, so this
  // peer and a phone's PearConnection.write/.data interoperate.
  swarm.on('connection', (conn, info) => {
    connected = true
    clearTimeout(connectTimer)
    console.error(`connected to ${info.publicKey.toString('hex').slice(0, 8)}…`)

    const mux = Protomux.from(conn)
    const channel = mux.createChannel({ protocol: 'pear-connection-data' })
    const message = channel.addMessage({
      encoding: c.buffer,
      onmessage (data) {
        console.log(`peer: ${data.toString('utf8')}`)
      }
    })
    channel.open()
    currentMessage = message

    conn.on('close', () => {
      if (currentMessage === message) currentMessage = null
      console.error('peer disconnected')
    })
  })

  console.error('waiting for a peer... (type a line + Enter to send once connected; Ctrl-C to quit)')
}

// --drive mode (flutter_pear-d5w).
async function runDrive (args, swarm, topic) {
  const storageDir = args.storage || fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-pear-peer-drive-'))
  const store = new Corestore(storageDir)
  const drive = new Hyperdrive(store)
  await drive.ready()
  console.error(`drive key: ${drive.key.toString('hex')}`)

  if (args.put) {
    const name = path.basename(args.put)
    // Streamed via createWriteStream, not put(name, buffer) -- matches
    // PearDrive.put's own local-file-path/never-in-memory contract
    // (BENCHMARK.md's locked bulk-transfer decision), so a --put of a
    // large file behaves the same way on this side as it does on the
    // phone's.
    await pipeline(fs.createReadStream(args.put), drive.createWriteStream('/' + name))
    console.error(`put /${name} (${fs.statSync(args.put).size} bytes) into the drive`)
  }

  let done = false
  const finish = (code) => {
    if (done) return
    done = true
    clearTimeout(connectTimer)
    swarm.destroy().catch(() => {}).then(() => process.exit(code))
  }

  let connected = false
  const connectTimer = setTimeout(() => {
    if (connected) return
    console.error(`no peer connected within ${args.timeoutMs}ms`)
    finish(1)
  }, args.timeoutMs)

  swarm.on('connection', (conn, info) => {
    onConnection(conn, info).catch((err) => console.error('connection handling failed:', err.message))
  })

  async function onConnection (conn, info) {
    connected = true
    clearTimeout(connectTimer)
    console.error(`connected to ${info.publicKey.toString('hex').slice(0, 8)}…`)

    // Chained exactly like index.js's replicateOverPeer: each core's
    // replicate() is passed the PREVIOUS call's returned stream as `base`,
    // not `conn` again -- multiple cores multiplexing onto one connection
    // via Protomux depends on this chain, not on each call getting its own
    // independent stream. AWAITED fully (not drive.getBlobs().then(...) left
    // to resolve whenever) before the channel below can possibly receive the
    // peer's key -- otherwise onPeerDriveKey could chain the peer's drive
    // onto a `base` that doesn't yet include our own blobs replication, a
    // real, empirically-hit race (intermittent "mirrored into" timeout in
    // tool/peer.check.js's drive round-trip check).
    let base = drive.core.replicate(conn)
    const blobs = await drive.getBlobs()
    base = blobs.core.replicate(base)

    const mux = Protomux.from(conn)
    const channel = mux.createChannel({ protocol: 'pear-connection-data' })
    const message = channel.addMessage({
      encoding: c.buffer,
      onmessage: (data) => {
        onPeerDriveKey(data).catch((err) => console.error('peer drive-key handling failed:', err.message))
      }
    })
    channel.open()
    message.send(Buffer.from(drive.key.toString('hex'), 'utf8'))

    async function onPeerDriveKey (data) {
      const peerKeyHex = data.toString('utf8')
      const peerKey = Buffer.from(peerKeyHex, 'hex')
      if (peerKey.length !== 32) {
        console.error(`bad drive-key announcement from peer (expected 32 bytes, got ${peerKey.length}): ${peerKeyHex}`)
        return
      }
      console.error(`learned peer's drive key: ${peerKeyHex.slice(0, 8)}…`)
      const peerDrive = new Hyperdrive(store, peerKey)
      await peerDrive.ready()
      base = peerDrive.core.replicate(base)
      const peerBlobs = await peerDrive.getBlobs()
      base = peerBlobs.core.replicate(base)

      if (args.mirrorTo) {
        fs.mkdirSync(args.mirrorTo, { recursive: true })
        const localDrive = new Localdrive(args.mirrorTo)
        // mirror-drive (the Pear ecosystem's own tool for this) streams
        // and diffs -- only changed files actually copy, same as
        // PearDrive.mirrorToDisk on the phone side.
        const mirror = peerDrive.mirror(localDrive)
        await mirror.done()
        console.error(
          `mirrored into ${args.mirrorTo}: ${mirror.count.add} added, ` +
          `${mirror.count.change} changed, ${mirror.count.remove} removed`
        )
        finish(0)
      }
    }

    conn.on('close', () => console.error('peer disconnected'))
  }

  console.error(`drive mode -- storage: ${storageDir}`)
  if (!args.put && !args.mirrorTo) {
    console.error('neither --put nor --mirror-to given -- will connect and replicate, then wait for Ctrl-C')
  } else if (!args.mirrorTo) {
    console.error('no --mirror-to given -- will stay running so a peer can pull the --put file; Ctrl-C to quit')
  }
}

// --store mode (flutter_pear-doi / E5.2 / flutter_pear-2vz.2): a plain
// Hypercore replication peer -- the desktop counterpart index.js's
// Method.STORE_GET/CORE_APPEND/CORE_GET/CORE_REPLICATE handlers were always
// missing (--drive covers Hyperdrive, chat covers raw connection data, but
// nothing exercised a bare Hypercore against the real pear-end code until
// now). Deliberately the simplest of the data-structure modes: one core, no
// blobs/second-core chaining, so runStore's shape below is a trimmed-down
// runDrive with a single replicate() call instead of two.
async function runStore (args, swarm, topic) {
  const storageDir = args.storage || fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-pear-peer-store-'))
  const store = new Corestore(storageDir)
  // store.get({ name: 'local' }) is exactly index.js's own STORE_GET
  // branch for a name-keyed get -- deriving/creating this process's own
  // writable core, not a fresh independently-keyed core that happens to
  // share a variable name.
  const core = store.get({ name: 'local' })
  await core.ready()
  console.error(`store key: ${core.key.toString('hex')}`)

  for (const value of args.appends || []) {
    await core.append(Buffer.from(value, 'utf8'))
  }
  if (args.appends?.length) {
    console.error(`appended ${args.appends.length} ${args.appends.length === 1 ? 'entry' : 'entries'} (length now ${core.length})`)
  }

  let done = false
  const finish = (code) => {
    if (done) return
    done = true
    clearTimeout(connectTimer)
    swarm.destroy().catch(() => {}).then(() => process.exit(code))
  }

  let connected = false
  const connectTimer = setTimeout(() => {
    if (connected) return
    console.error(`no peer connected within ${args.timeoutMs}ms`)
    finish(1)
  }, args.timeoutMs)

  swarm.on('connection', (conn, info) => {
    onConnection(conn, info).catch((err) => console.error('connection handling failed:', err.message))
  })

  async function onConnection (conn, info) {
    connected = true
    clearTimeout(connectTimer)
    console.error(`connected to ${info.publicKey.toString('hex').slice(0, 8)}…`)

    // Single replicate() call, unlike --drive's core-then-blobs chain --
    // a plain Hypercore has nothing else to chain onto the same connection,
    // so `conn` itself is the base every subsequent replicate() (just the
    // peer's core, once learned) chains onto. Matches index.js's own
    // replicateOverPeer: passing `conn` twice, instead of chaining through
    // the first call's returned stream, would open two independent
    // protocol streams over one socket and corrupt both.
    let base = core.replicate(conn)

    const mux = Protomux.from(conn)
    const channel = mux.createChannel({ protocol: 'pear-connection-data' })
    const message = channel.addMessage({
      encoding: c.buffer,
      onmessage: (data) => {
        onPeerStoreKey(data).catch((err) => console.error('peer store-key handling failed:', err.message))
      }
    })
    channel.open()
    message.send(Buffer.from(core.key.toString('hex'), 'utf8'))

    async function onPeerStoreKey (data) {
      const peerKeyHex = data.toString('utf8')
      const peerKey = Buffer.from(peerKeyHex, 'hex')
      if (peerKey.length !== 32) {
        console.error(`bad store-key announcement from peer (expected 32 bytes, got ${peerKey.length}): ${peerKeyHex}`)
        return
      }
      console.error(`learned peer's store key: ${peerKeyHex.slice(0, 8)}…`)
      // store.get(<Buffer>) is exactly index.js's own STORE_GET branch for
      // a key-keyed get -- a read-only session onto the PEER's core, not a
      // second local writer. Same store instance as `core` above (this
      // process's own corestore), just a different session within it.
      const peerCore = store.get(peerKey)
      await peerCore.ready()
      base = peerCore.replicate(base)

      if (args.expectCount !== undefined) {
        // core.get(i) waits for block i to arrive by default -- the same
        // wait-by-default semantics index.js's own Method.CORE_GET relies
        // on (`await core.get(p.index)`, no options) -- so no manual
        // peerCore.length polling is needed here; this loop is exactly how
        // a real reader (phone or desktop) consumes a core that's still
        // replicating in.
        const entries = []
        for (let i = 0; i < args.expectCount; i++) {
          const block = await peerCore.get(i)
          entries.push(block.toString('base64'))
        }
        for (const [i, entry] of entries.entries()) {
          console.log(`core-entry[${i}]: ${entry}`)
        }
        console.error(`read back all ${args.expectCount} entries from peer's store`)
        finish(0)
      }
    }

    conn.on('close', () => console.error('peer disconnected'))
  }

  console.error(`store mode -- storage: ${storageDir}`)
  if (args.expectCount === undefined) {
    console.error('no --expect-count given -- will connect and replicate, then wait for Ctrl-C')
  }
}

// --bee mode (flutter_pear-doi / E5.3 / flutter_pear-2vz.3): a Hyperbee
// replication + watch peer -- the desktop counterpart index.js's
// Method.BEE_OPEN/BEE_PUT/BEE_WATCH/BEE_REPLICATE handlers were missing.
// See this file's header comment for why puts are driven from live stdin
// lines rather than a --store-style preloaded CLI list (a preloaded put
// risks landing inside the Watcher's own baseline snapshot and never firing
// at all).
async function runBee (args, swarm, topic) {
  const storageDir = args.storage || fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-pear-peer-bee-'))
  const store = new Corestore(storageDir)
  const core = store.get({ name: 'bee' })
  await core.ready()
  // keyEncoding/valueEncoding: 'binary' -- exactly index.js's own
  // Method.BEE_OPEN construction (`new Hyperbee(core, { keyEncoding:
  // 'binary', valueEncoding: 'binary' })`). Both sides MUST agree on this or
  // every key/value comparison silently miscompares instead of throwing.
  const bee = new Hyperbee(core, { keyEncoding: 'binary', valueEncoding: 'binary' })
  await bee.ready()
  console.error(`bee key: ${bee.core.key.toString('hex')}`)

  // Same single readline interface / no-per-connection-recreation rationale
  // as runChat's own comment above -- stdin is one stream regardless of how
  // many times a peer reconnects. Puts always go into THIS side's OWN bee
  // (the one this process holds the writer key for); there is no
  // "--bee-put" CLI flag on purpose, see this file's header comment.
  readline.createInterface({ input: process.stdin }).on('line', (line) => {
    const eq = line.indexOf('=')
    if (eq === -1) {
      console.error(`ignoring malformed line (expected key=value): ${line}`)
      return
    }
    const key = line.slice(0, eq)
    const value = line.slice(eq + 1)
    bee.put(Buffer.from(key, 'utf8'), Buffer.from(value, 'utf8'))
      .then(() => console.error(`put ${key}=${value} into own bee`))
      .catch((err) => console.error(`put failed: ${err.message}`))
  })

  // No --expect-count/--mirror-to-style "done" condition here -- a live KV
  // watch has no natural completion point, so (like chat mode) this just
  // runs until Ctrl-C/timeout; tool/peer.check.js kills both processes once
  // its own assertion is satisfied.
  let connected = false
  const connectTimer = setTimeout(() => {
    if (connected) return
    console.error(`no peer connected within ${args.timeoutMs}ms`)
    process.exitCode = 1
    swarm.destroy().catch(() => {}).then(() => process.exit(1))
  }, args.timeoutMs)

  swarm.on('connection', (conn, info) => {
    onConnection(conn, info).catch((err) => console.error('connection handling failed:', err.message))
  })

  async function onConnection (conn, info) {
    connected = true
    clearTimeout(connectTimer)
    console.error(`connected to ${info.publicKey.toString('hex').slice(0, 8)}…`)

    // Single replicate() call, same rationale as --store's own comment --
    // a Hyperbee has nothing beyond its one backing core to chain.
    let base = bee.core.replicate(conn)

    const mux = Protomux.from(conn)
    const channel = mux.createChannel({ protocol: 'pear-connection-data' })
    const message = channel.addMessage({
      encoding: c.buffer,
      onmessage: (data) => {
        onPeerBeeKey(data).catch((err) => console.error('peer bee-key handling failed:', err.message))
      }
    })
    channel.open()
    message.send(Buffer.from(bee.core.key.toString('hex'), 'utf8'))

    async function onPeerBeeKey (data) {
      const peerKeyHex = data.toString('utf8')
      const peerKey = Buffer.from(peerKeyHex, 'hex')
      if (peerKey.length !== 32) {
        console.error(`bad bee-key announcement from peer (expected 32 bytes, got ${peerKey.length}): ${peerKeyHex}`)
        return
      }
      console.error(`learned peer's bee key: ${peerKeyHex.slice(0, 8)}…`)
      // store.get(<Buffer>) -- a read-only session onto the PEER's core,
      // same STORE_GET key-branch reasoning as --store's own comment above.
      const peerCore = store.get(peerKey)
      await peerCore.ready()
      base = peerCore.replicate(base)
      const peerBee = new Hyperbee(peerCore, { keyEncoding: 'binary', valueEncoding: 'binary' })
      await peerBee.ready()

      // Mirrors index.js's own Method.BEE_WATCH handler: consumes the
      // Watcher's async-iterator in a detached loop, full range (no bounds)
      // -- this tool's whole point is proving REPLICATION drives a real
      // watch fire, not exercising range-bound edge cases (already covered
      // by bee_test.dart's fake-driven tests). Set up immediately on
      // learning the peer's key -- see this file's header comment for why
      // the timing here (watch armed before any future put) is load-bearing.
      const watcher = peerBee.watch()
      ;(async () => {
        try {
          for await (const _ of watcher) { // eslint-disable-line no-unused-vars
            // Re-read through the bee's ordinary range-read path (the same
            // path .get() uses under the hood), not the watcher's own
            // internal diff snapshots -- proves the changed value is
            // genuinely durable and queryable post-replication, matching
            // flutter_pear-2vz.3's own deferred VALIDATION wording
            // ("...observable afterward via .get()").
            for await (const entry of peerBee.createReadStream()) {
              console.log(`bee: ${entry.key.toString('utf8')}=${entry.value.toString('utf8')}`)
            }
          }
        } catch (err) {
          console.error('bee watch loop ended:', err.message)
        }
      })()
    }

    conn.on('close', () => console.error('peer disconnected'))
  }

  console.error(`bee mode -- storage: ${storageDir}`)
  console.error('waiting for a peer... (type key=value + Enter to put into your own bee once connected; Ctrl-C to quit)')
}

// --base mode (flutter_pear-doi / E5.7-E5.8 / flutter_pear-2vz.8). See this
// file's header comment for the full handshake rationale and the real
// "Not writable" race this has to survive.
async function runBase (args, swarm, topic) {
  const storageDir = args.storage || fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-pear-peer-base-'))
  const store = new Corestore(storageDir)
  const recipe = RECIPES.lww
  // Exactly index.js's own BASE_OPEN options -- see this file's header
  // comment for why there is deliberately no ackInterval/ackThreshold
  // override here, unlike autobase-recipes.test.js's fast-test config.
  const baseOpts = { open: recipe.open, apply: recipe.apply, valueEncoding: 'json' }

  // Host constructs its base up front (bootstrap null); join can't construct
  // its own until it learns the host's key over the wire (see below), so
  // `base` starts null there and this outer scope's onHandshake fills it in.
  let base = null
  if (args.baseRole === 'host') {
    base = new Autobase(store, null, baseOpts)
    await base.ready()
    console.error(`base key: ${base.local.key.toString('hex')}`)
  }

  let done = false
  const finish = (code) => {
    if (done) return
    done = true
    clearTimeout(connectTimer)
    swarm.destroy().catch(() => {}).then(() => process.exit(code))
  }

  let connected = false
  const connectTimer = setTimeout(() => {
    if (connected) return
    console.error(`no peer connected within ${args.timeoutMs}ms`)
    finish(1)
  }, args.timeoutMs)

  swarm.on('connection', (conn, info) => {
    onConnection(conn, info).catch((err) => {
      console.error('connection handling failed:', err.message)
      finish(1)
    })
  })

  async function onConnection (conn, info) {
    connected = true
    clearTimeout(connectTimer)
    console.error(`connected to ${info.publicKey.toString('hex').slice(0, 8)}…`)

    // Host's base already exists -- chain its replicate() onto the
    // connection right away, same single-call-per-structure pattern as
    // --store/--bee (base.replicate() delegates to Corestore.replicate(),
    // which auto-discovers any core later created from this SAME store --
    // including the join side's own writer core, added after addWriter
    // lands -- so no core-then-blobs-style chaining is needed here).
    if (args.baseRole === 'host') base.replicate(conn)

    // Same 'pear-connection-data' channel name --drive/--store/--bee's own
    // key-announcement handshakes use, generalized here to a short two-step
    // exchange (see this file's header comment for why --base's handshake is
    // two steps, not a single symmetric key swap).
    const mux = Protomux.from(conn)
    const channel = mux.createChannel({ protocol: 'pear-connection-data' })
    const message = channel.addMessage({
      encoding: c.buffer,
      onmessage: (data) => {
        onHandshake(data).catch((err) => {
          console.error('base handshake failed:', err.message)
          finish(1)
        })
      }
    })
    channel.open()
    if (args.baseRole === 'host') {
      message.send(Buffer.from(base.local.key.toString('hex'), 'utf8'))
    }

    async function onHandshake (data) {
      if (args.baseRole === 'join') {
        // The host's bootstrap key -- MUST be known before construction
        // (see this file's header comment for why this differs from
        // --drive's independently-creatable-then-merged replicas).
        const hostKeyHex = data.toString('utf8')
        base = new Autobase(store, Buffer.from(hostKeyHex, 'hex'), baseOpts)
        await base.ready()
        console.error(`joined base, own writer key: ${base.local.key.toString('hex')}`)
        base.replicate(conn)
        message.send(Buffer.from(base.local.key.toString('hex'), 'utf8'))
      } else {
        // The joiner's own writer key, sent back once IT constructed its
        // base against ours -- admit it. validateAddWriter mirrors
        // index.js's own BASE_APPEND dispatch order (addWriter/removeWriter
        // checked before the recipe's own put/del op shape).
        const joinerKeyHex = data.toString('utf8')
        console.error(`admitting joiner as writer: ${joinerKeyHex.slice(0, 8)}…`)
        const addWriterOp = { addWriter: joinerKeyHex }
        validateAddWriter(addWriterOp)
        await base.append(addWriterOp)
      }
      await appendOwnPutAndAwaitConvergence()
    }

    async function appendOwnPutAndAwaitConvergence () {
      const ownOp = {
        type: 'put',
        key: Buffer.from(args.basePut.key, 'utf8').toString('base64'),
        value: Buffer.from(args.basePut.value, 'utf8').toString('base64')
      }
      recipe.validate(ownOp)
      // See this file's header comment: on the join side this reliably
      // fails at least once with "Not writable" before the addWriter op
      // above round-trips back -- appendWhenWritable retries past that.
      await appendWhenWritable(base, ownOp, args.timeoutMs)
      console.error(`appended own put: ${args.basePut.key}=${args.basePut.value}`)

      const peerKeyB64 = Buffer.from(args.baseExpect.key, 'utf8').toString('base64')
      const observedB64 = await waitForConverged(base, recipe, peerKeyB64, args.timeoutMs)
      const observed = Buffer.from(observedB64, 'base64').toString('utf8')
      if (observed !== args.baseExpect.value) {
        throw new Error(
          `converged value for "${args.baseExpect.key}" was "${observed}", expected "${args.baseExpect.value}"`
        )
      }
      // A single, greppable marker line (mirrors chat's "peer: " / bee's
      // "bee: " convention) tool/peer.check.js asserts on -- proves THIS
      // side's own put landed AND the peer's put converged into the SAME
      // view, i.e. the two-writer convergence property, not just that a
      // connection happened.
      console.log(`base-converged: ${JSON.stringify({
        own: args.basePut,
        peer: { key: args.baseExpect.key, value: observed }
      })}`)
      finish(0)
    }

    conn.on('close', () => console.error('peer disconnected'))
  }

  console.error(`base mode (${args.baseRole}) -- storage: ${storageDir}`)
}

// See runBase's own header comment (in this file's top doc comment) for why
// this retry is load-bearing, not defensive paranoia: a freshly-added
// writer's base.append() reliably throws "Not writable" until the addWriter
// op admitting it has replicated back and been applied on this replica.
async function appendWhenWritable (base, op, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    try {
      await base.append(op)
      return
    } catch (err) {
      if (!/not writable/i.test(err.message)) throw err
      if (Date.now() > deadline) throw new Error('timed out waiting to become a writable member of the base')
      await new Promise((resolve) => setTimeout(resolve, 200))
    }
  }
}

// Polls recipe.get() (the same read path PearBase.get/E5.8 uses) until the
// peer's key shows up in OUR OWN view -- real proof of replication +
// linearization, not just that our own append landed locally.
async function waitForConverged (base, recipe, keyB64, timeoutMs) {
  const deadline = Date.now() + timeoutMs
  for (;;) {
    const result = await recipe.get(base.view, keyB64)
    if (result.exists) return result.value
    if (Date.now() > deadline) throw new Error("timed out waiting for the peer's key to converge into our own view")
    await new Promise((resolve) => setTimeout(resolve, 200))
  }
}

main().catch((err) => {
  console.error(err.message || err)
  process.exit(1)
})
