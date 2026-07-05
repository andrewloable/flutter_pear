#!/usr/bin/env node
'use strict'

// Runnable check for peer.js (E7.3, X7): a real two-process round trip over
// Hyperswarm/Protomux -- not a stub -- since the entire point of this file
// is proving two independent Node processes on the same topic actually
// interop with the same wire protocol pear-end's worklet speaks. Also
// covers the CI-usability contract: nonzero exit on connect timeout.
//
// Plain assert-based script, not `node --test`: real DHT bootstrap from
// inside node's test-runner child processes was observed hanging far
// longer than the identical spawn from a plain script or shell background
// job in this environment (undiagnosed, but consistently reproducible) --
// a plain script sidesteps whatever that interaction is.
//
// flutter_pear-doi review fix: every check below used to join the REAL,
// public, internet-wide DHT (peer.js's default) -- confirmed unreliable in
// practice, not just in theory: a from-a-clean-slate re-run of this exact
// file timed out on the very FIRST check (checkRoundTrip, pre-existing and
// unrelated to any --store work) in 3/3 consecutive attempts, and even an
// isolated, randomized-topic-only run of checkStoreRoundTrip alone passed
// only 2/5 times, both failure modes being genuine "receiver never printed
// connected to within the timeout" DHT/network flakiness, not a data-
// correctness bug. Fixed at the root, the same way
// pear-end/test/pairing-real-roundtrip.test.js already fixed the identical
// problem for blind-pairing: `main` below boots one private, local, fully
// offline hyperdht/testnet for the whole file and passes its bootstrap
// nodes to every spawned peer.js via `--bootstrap` (see that flag's own doc
// comment in peer.js). This removes the real DHT/network entirely from
// this file's critical path -- no internet round trips, no real-world
// packet loss/NAT/congestion, and no risk of colliding with any other
// concurrent run of this same file anywhere, since two different testnets
// can never rendezvous with each other even on an identical --topic string.
//
// review follow-up: the local testnet swap above has its own gotcha, and an
// earlier version of this file's checks hit it directly -- every check
// used to spawn its pair of peers back-to-back with no ordering between
// their swarm.join() calls, which is exactly the "simultaneous joins never
// converge on a small local testnet" failure
// pear-end/test/noise-confidentiality.test.js's own "SECOND GOTCHA" already
// documents and solves for the in-process case (`joinAndWait`, staggered,
// not simultaneous). Reproduced here empirically across separate processes
// too: two --bootstrap'd peer.js instances spawned together never printed
// "connected to" even after 15s of polling, while spawning the second only
// after the first's own join reports "joined swarm" (peer.js's own
// `discovery.flushed()` line) connects reliably. `spawnPeersStaggered`
// below is the process-boundary equivalent of `joinAndWait` and every check
// spawns its pair through it now.
//
// Run directly: `node tool/peer.check.js`.

const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { createRequire } = require('node:module')

const PEER_JS = path.join(__dirname, 'peer.js')

// Same pearEndRequire trick peer.js itself uses -- resolves 'hyperdht'
// through pear-end's OWN node_modules (a transitive dependency of the
// hyperswarm pear-end/peer.js already pin), not a second, independently
// installed copy that could drift to a wire-incompatible version.
const pearEndRequire = createRequire(
  path.join(__dirname, '..', '..', 'flutter_pear', 'pear-end', 'package.json')
)
const createTestnet = pearEndRequire('hyperdht/testnet')

function tmpDir (prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix))
}

// Set once by main() before any check runs -- a comma-separated
// `host:port,...` string ready for peer.js's own --bootstrap flag (already
// exactly hyperdht/testnet's `.bootstrap` array shape, just serialized for
// the command line). Every spawned peer -- including checkTimeoutExit's own
// direct spawn() call below, not just the spawnPeer() helper -- must be
// routed through this so NOTHING in this file ever touches the real DHT.
let bootstrapArg = null

function bootstrapArgs () {
  return bootstrapArg ? ['--bootstrap', bootstrapArg] : []
}

function spawnPeer (args) {
  const child = spawn('node', [PEER_JS, ...args, ...bootstrapArgs()], { stdio: ['pipe', 'pipe', 'pipe'] })
  let stdout = ''
  let stderr = ''
  child.stdout.on('data', (d) => { stdout += d })
  child.stderr.on('data', (d) => { stderr += d })
  return {
    child,
    send (line) { child.stdin.write(line + '\n') },
    stdout: () => stdout,
    waitFor (predicate, timeoutMs) {
      return new Promise((resolve, reject) => {
        const start = Date.now()
        const poll = setInterval(() => {
          if (predicate(stdout, stderr)) {
            clearInterval(poll)
            resolve()
          } else if (Date.now() - start > timeoutMs) {
            clearInterval(poll)
            reject(new Error(`timed out waiting; stdout=${stdout} stderr=${stderr}`))
          }
        }, 200)
      })
    },
    // See peer.js's own --bootstrap comment for the full why: on this local
    // testnet, a peer's join isn't safe to race against another peer's join
    // until this line (printed right after the join's own flushed()) shows
    // up in its stderr.
    waitJoined (timeoutMs = 20000) {
      return this.waitFor((_, err) => err.includes('joined swarm'), timeoutMs)
    }
  }
}

// Spawns two peers STAGGERED against this file's local testnet: `a`'s join
// is fully flushed (confirmed via its own "joined swarm" line) before `b`'s
// process is even started. Required, not just extra insurance -- two
// --bootstrap'd peer.js processes spawned back-to-back (the naive,
// non-staggered way every check below used to spawn its pair) were
// confirmed, empirically, to never connect against this local testnet, even
// after 15s of polling: Hyperswarm's own PeerDiscovery picks EITHER
// announce OR lookup per refresh cycle, never both, so two peers joining in
// the same instant never observe each other's freshly-landed announce
// during their own single pass (same root cause, same fix shape, as
// pear-end/test/noise-confidentiality.test.js's own "SECOND GOTCHA" /
// `joinAndWait`). Staggering (this function) connects reliably.
async function spawnPeersStaggered (argsA, argsB) {
  const a = spawnPeer(argsA)
  await a.waitJoined()
  const b = spawnPeer(argsB)
  return [a, b]
}

async function checkRoundTrip () {
  // First-connect latency over the real DHT varies a lot by network (a few
  // seconds on a fast LAN, up to ~60s seen on a constrained/sandboxed one)
  // -- generous bounds are the point: this proves CI usability, not speed.
  const [a, b] = await spawnPeersStaggered(
    ['--topic', 'peer-js-check-round-trip', '--timeout', '75'],
    ['--topic', 'peer-js-check-round-trip', '--timeout', '75']
  )
  try {
    await Promise.all([
      a.waitFor((_, err) => err.includes('connected to'), 70000),
      b.waitFor((_, err) => err.includes('connected to'), 70000)
    ])

    a.send('hello from A')
    b.send('hello from B')

    await a.waitFor((out) => out.includes('peer: hello from B'), 5000)
    await b.waitFor((out) => out.includes('peer: hello from A'), 5000)
    console.log('ok: two peers on the same --topic connected and exchanged messages both ways')
  } finally {
    a.child.kill('SIGKILL')
    b.child.kill('SIGKILL')
  }
}

// flutter_pear-d5w: real two-process round trip for --drive mode -- a
// genuine Hyperdrive replication over a real (local) Hyperswarm connection,
// not a stub. Proves the drive-key-announcement protocol (the same one
// file_drop_screen.dart speaks) and the core-then-blobs replication
// chaining actually interop between two independent processes, byte-exact.
async function checkDriveRoundTrip () {
  const sendDir = tmpDir('flutter-pear-peer-check-send-')
  const recvDir = tmpDir('flutter-pear-peer-check-recv-')
  const storageA = tmpDir('flutter-pear-peer-check-storeA-')
  const storageB = tmpDir('flutter-pear-peer-check-storeB-')
  const sourceFile = path.join(sendDir, 'payload.bin')
  const payload = crypto.randomBytes(5 * 1024 * 1024) // photo-sized, matches E7.7's own validation scale
  fs.writeFileSync(sourceFile, payload)

  const topic = 'peer-js-check-drive-round-trip'
  const [sender, receiver] = await spawnPeersStaggered(
    ['--topic', topic, '--drive', '--put', sourceFile, '--storage', storageA, '--timeout', '75'],
    ['--topic', topic, '--drive', '--mirror-to', recvDir, '--storage', storageB, '--timeout', '75']
  )
  try {
    await receiver.waitFor((_, err) => err.includes('mirrored into'), 70000)

    const receivedFile = path.join(recvDir, 'payload.bin')
    assert.ok(fs.existsSync(receivedFile), 'mirrored file must exist at the expected path')
    const receivedHash = crypto.createHash('sha256').update(fs.readFileSync(receivedFile)).digest('hex')
    const sentHash = crypto.createHash('sha256').update(payload).digest('hex')
    assert.equal(receivedHash, sentHash, 'mirrored file must be byte-identical to the one --put on the other side')
    console.log('ok: --drive mode replicated a 5MB file between two peers, byte-identical')
  } finally {
    sender.child.kill('SIGKILL')
    receiver.child.kill('SIGKILL')
    for (const dir of [sendDir, recvDir, storageA, storageB]) fs.rmSync(dir, { recursive: true, force: true })
  }
}

// flutter_pear-doi / flutter_pear-2vz.2: real two-process round trip for
// --store mode -- a genuine plain-Hypercore replication over a real (local)
// Hyperswarm connection, proving pear-end's Method.STORE_GET/CORE_APPEND/
// CORE_GET/CORE_REPLICATE wire behavior (store.get({name})/store.get(key),
// append, and wait-by-default get()) actually interops between two
// independent processes, byte-exact and in order -- this is the "desktop
// Hypercore-replicate counterpart" flutter_pear-2vz.2's own deferred
// hardware leg needed (append on A, replicate, read back on B).
//
// Unlike checkRoundTrip/checkDriveRoundTrip above, this topic still gets a
// random suffix rather than a fixed string -- originally worked around a
// REAL bug hit while writing this check (neither peer.js nor this file
// overrode Hyperswarm's default DHT, so a fixed --topic rendezvoused on the
// real, public, internet-wide DHT and could cross-wire with any other
// concurrent run of this same check anywhere). That root cause is now fixed
// file-wide -- see this file's header comment -- by routing every spawned
// peer through a private, local, offline hyperdht/testnet via --bootstrap,
// which makes even a fixed topic collision-safe (two different testnets can
// never rendezvous with each other). The random suffix is kept here anyway
// as cheap, harmless extra insurance against some future refactor
// accidentally sharing one testnet across multiple concurrent invocations
// of this file, not because it's load-bearing today.
async function checkStoreRoundTrip () {
  const storageA = tmpDir('flutter-pear-peer-check-storeA-')
  const storageB = tmpDir('flutter-pear-peer-check-storeB-')
  // Deliberately includes multi-byte UTF-8 (an em dash and an emoji) and a
  // duplicate-looking-but-distinct entry -- base64 round-tripping arbitrary
  // bytes through core-entry[i] output, not just plain ASCII, is the actual
  // point: a naive toString('utf8')/JSON-line encoding would have been
  // enough for ASCII but could silently mangle these.
  const entries = ['first entry', 'second entry — with an em dash', 'third: 🎉 non-ascii and repeat-looking', 'third: 🎉 non-ascii and repeat-looking']
  const topic = 'peer-js-check-store-round-trip-' + crypto.randomBytes(8).toString('hex')
  const appendArgs = entries.flatMap((value) => ['--append', value])
  const [sender, receiver] = await spawnPeersStaggered(
    ['--topic', topic, '--store', ...appendArgs, '--storage', storageA, '--timeout', '75'],
    ['--topic', topic, '--store', '--expect-count', String(entries.length), '--storage', storageB, '--timeout', '75']
  )
  try {
    await receiver.waitFor((_, err) => err.includes('read back all'), 70000)

    const stdout = receiver.stdout()
    const receivedEntries = entries.map((_, i) => {
      const match = stdout.match(new RegExp(`core-entry\\[${i}\\]: (\\S+)`))
      assert.ok(match, `expected a core-entry[${i}] line in receiver stdout, got: ${stdout}`)
      return Buffer.from(match[1], 'base64').toString('utf8')
    })
    assert.deepEqual(receivedEntries, entries, 'every appended Hypercore entry must round-trip byte-exact, in order')
    console.log('ok: --store mode replicated a plain Hypercore between two peers, byte-exact and in order')
  } finally {
    sender.child.kill('SIGKILL')
    receiver.child.kill('SIGKILL')
    for (const dir of [storageA, storageB]) fs.rmSync(dir, { recursive: true, force: true })
  }
}

// flutter_pear-doi / flutter_pear-2vz.3: real two-process round trip for
// --bee mode -- a genuine Hyperbee replication over a real (local) Hyperswarm
// connection, proving pear-end's Method.BEE_OPEN/BEE_PUT/BEE_WATCH/
// BEE_REPLICATE wire behavior actually interops between two independent
// processes AND that a peer's live bee.watch() genuinely fires as a
// consequence of real replication -- this is the "desktop Hyperbee
// counterpart" flutter_pear-2vz.3's own deferred hardware leg needed ("put
// on A, watch fires on B over replication").
//
// The critical ordering this check enforces (see peer.js's header comment
// for the full why): it waits for BOTH sides to report "learned peer's bee
// key" -- meaning B's watcher is already armed on A's (still-empty) bee --
// before sending the put. Sending the put any earlier (e.g. right after
// "connected to") would race B's watch-arming step, and if the put's bytes
// happened to replicate in before B called bee.watch(), the watcher's own
// baseline snapshot would already include it and it would NEVER fire --
// silently turning this into a check that always times out, not one that
// passes for the wrong reason.
//
// Random topic suffix kept for the same cheap-insurance reason as
// checkStoreRoundTrip's own comment above -- the real cause it originally
// worked around (a fixed --topic rendezvousing on the real, public,
// internet-wide DHT) is now fixed file-wide via the private, local,
// offline testnet every check is routed through (see this file's header
// comment).
async function checkBeeRoundTrip () {
  const storageA = tmpDir('flutter-pear-peer-check-beeA-')
  const storageB = tmpDir('flutter-pear-peer-check-beeB-')
  const topic = 'peer-js-check-bee-round-trip-' + crypto.randomBytes(8).toString('hex')
  const [a, b] = await spawnPeersStaggered(
    ['--topic', topic, '--bee', '--storage', storageA, '--timeout', '75'],
    ['--topic', topic, '--bee', '--storage', storageB, '--timeout', '75']
  )
  try {
    await Promise.all([
      a.waitFor((_, err) => err.includes('connected to'), 70000),
      b.waitFor((_, err) => err.includes('connected to'), 70000)
    ])
    await Promise.all([
      a.waitFor((_, err) => err.includes("learned peer's bee key"), 10000),
      b.waitFor((_, err) => err.includes("learned peer's bee key"), 10000)
    ])

    a.send('hello=from-A')

    await b.waitFor((out) => out.includes('bee: hello=from-A'), 10000)
    console.log("ok: put on A replicated to B and B's bee.watch() fired from real replication, with the correct key/value observable afterward")
  } finally {
    a.child.kill('SIGKILL')
    b.child.kill('SIGKILL')
    for (const dir of [storageA, storageB]) fs.rmSync(dir, { recursive: true, force: true })
  }
}

// flutter_pear-doi / flutter_pear-2vz.8: real two-process round trip for
// --base mode -- a genuine Autobase (lww recipe) two-writer convergence over
// a real (local) Hyperswarm connection, proving pear-end's own
// Method.BASE_OPEN/BASE_APPEND wire behavior AND the two-writer convergence
// property flutter_pear-doi's own notes call out by name: host and join
// each append a put() for a DIFFERENT key while mutually unaware of each
// other, replicate, and must both converge on ONE identical view containing
// BOTH keys -- not just a single append round trip (see peer.js's own
// header comment for the full handshake rationale and the real "Not
// writable" race this exercises).
//
// Random topic suffix kept for the same cheap-insurance reason as
// checkStoreRoundTrip's own comment above -- the real cause it originally
// worked around (a fixed --topic rendezvousing on the real, public,
// internet-wide DHT, and once, empirically, cross-wiring with an unrelated
// concurrent agent's run of this same file on that identical fixed topic
// string) is now fixed file-wide via the private, local, offline testnet
// every check is routed through (see this file's header comment).
async function checkBaseRoundTrip () {
  const storageHost = tmpDir('flutter-pear-peer-check-baseHost-')
  const storageJoin = tmpDir('flutter-pear-peer-check-baseJoin-')
  const topic = 'peer-js-check-base-round-trip-' + crypto.randomBytes(8).toString('hex')
  const [host, join] = await spawnPeersStaggered(
    [
      '--topic', topic, '--base', '--base-role', 'host',
      '--base-put', 'host-key=host-value', '--base-expect', 'join-key=join-value',
      '--storage', storageHost, '--timeout', '75'
    ],
    [
      '--topic', topic, '--base', '--base-role', 'join',
      '--base-put', 'join-key=join-value', '--base-expect', 'host-key=host-value',
      '--storage', storageJoin, '--timeout', '75'
    ]
  )
  try {
    await Promise.all([
      host.waitFor((out) => out.includes('base-converged:'), 70000),
      join.waitFor((out) => out.includes('base-converged:'), 70000)
    ])

    const hostResult = JSON.parse(host.stdout().match(/base-converged: (.+)/)[1])
    const joinResult = JSON.parse(join.stdout().match(/base-converged: (.+)/)[1])
    assert.deepEqual(hostResult, {
      own: { key: 'host-key', value: 'host-value' },
      peer: { key: 'join-key', value: 'join-value' }
    }, "host's own put and its converged view of join's put must both be exact")
    assert.deepEqual(joinResult, {
      own: { key: 'join-key', value: 'join-value' },
      peer: { key: 'host-key', value: 'host-value' }
    }, "join's own put and its converged view of host's put must both be exact")
    console.log('ok: --base mode -- two independent writers each put() a different key while mutually ' +
      'unaware, replicated, and converged on one identical view containing both')
  } finally {
    host.child.kill('SIGKILL')
    join.child.kill('SIGKILL')
    for (const dir of [storageHost, storageJoin]) fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function checkTimeoutExit () {
  const exitCode = await new Promise((resolve) => {
    const child = spawn('node', [
      PEER_JS, '--topic', 'peer-js-check-lonely-topic', '--timeout', '2', ...bootstrapArgs()
    ], { stdio: ['ignore', 'ignore', 'ignore'] })
    child.on('exit', (code) => resolve(code))
  })
  assert.equal(exitCode, 1, 'expected exit code 1 on connect timeout')
  console.log('ok: exits nonzero when no peer connects within --timeout')
}

async function main () {
  // One private, local, fully offline DHT for the whole file -- see this
  // file's header comment for why (removes the real public DHT, and all the
  // flakiness/collision risk that came with it, from every check below).
  // Size 3, matching pairing-real-roundtrip.test.js's own precedent for the
  // same createTestnet call.
  const testnet = await createTestnet(3)
  bootstrapArg = testnet.bootstrap.map(({ host, port }) => `${host}:${port}`).join(',')
  try {
    // Round trip first: an earlier ordering (timeout-check, then round-trip)
    // was observed to make the SECOND check's DHT bootstrap unreliable in
    // this environment, even with generous timeouts -- undiagnosed, but
    // consistently reproducible, so the cheap check runs last instead.
    await checkRoundTrip()
    await checkDriveRoundTrip()
    await checkStoreRoundTrip()
    await checkBeeRoundTrip()
    await checkBaseRoundTrip()
    await checkTimeoutExit()
  } finally {
    await testnet.destroy().catch(() => {})
  }
}

main().catch((err) => {
  console.error('FAILED:', err.message || err)
  process.exit(1)
})
