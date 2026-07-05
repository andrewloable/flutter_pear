// flutter_pear-df9.6 -- Noise confidentiality proof (capture-based, with
// negative control, authentication check, and wrong-peer rejection).
//
// RUNBOOK -- from packages/flutter_pear/pear-end/:
//   npm test                                          (whole pear-end suite)
//   node --test test/noise-confidentiality.test.js    (this file only)
// Node's `node --test` with no path argument recursively auto-discovers
// every *.test.js under test/ (see pairing-real-roundtrip.test.js's own
// header for why a directory-path argument doesn't work on this Node
// version) -- this file needs no package.json wiring beyond that.
//
// WHAT THIS PROVES, IN ONE PARAGRAPH: two real Hyperswarm peers (real
// hyperswarm/hyperdht/@hyperswarm/secret-stream libraries, real Ed25519
// keys, real X25519 Noise handshake -- only the DHT rendezvous is a local,
// offline testnet, never a fake) exchange a fresh, high-entropy marker over
// their normal encrypted channel; the marker is proven to reach the far
// side over the DECRYPTED application stream, is proven to NEVER appear in
// the raw ciphertext bytes actually traversing the wire below Noise, and a
// raw-TCP negative control proves the exact same capture technique WOULD
// have caught the marker had it been sent in the clear (so "not found"
// above is a real result, not a broken/silent capture). Both sides are
// asserted to see each other's REAL known public key and to derive an
// IDENTICAL handshake transcript hash (authenticated handshake, not just
// "some" encryption) -- that check is against the raw hyperswarm library
// objects directly; a SEPARATE test below re-proves the same authenticated-
// identity property through index.js's OWN RPC/event contract (a real
// bootWorklet(), listening for the real SWARM_CONNECTION event index.js
// itself emits), so a regression specifically inside index.js's own
// connection-handling/event-emission code -- as opposed to the hyperswarm
// library it wraps -- is also covered, not just inferred from the library
// working correctly. Finally, a wrong peer is proven unable to join the
// pairing session two different ways: a structurally fabricated invite is
// rejected immediately; a real-but-tampered invite is proven, by directly
// observing the inviter's own event stream, to NEVER even produce a
// PAIRING_CANDIDATE notification (not merely inferred from the wrong peer's
// own bounded timeout -- a positive control using the SAME inviter's real,
// unmodified invite proves this test's listener genuinely fires when a
// candidate really is confirmable, so the "never fires" result above is a
// real finding, not a broken/no-op listener). A third real peer sharing the
// same swarm topic is proven to get a cryptographically independent Noise
// session two ways: a different handshake transcript hash, AND -- the
// ticket's own literal requirement, tested directly rather than inferred
// from ciphertext/session opacity -- the third peer's own real, live
// decrypt object (keyed with ITS OWN real session key, from its own real
// Noise handshake with the shared peer) is handed the exact real ciphertext
// block captured off the legitimate pair's session and demonstrably FAILS
// to authenticate/decrypt it (a real `sodium_secretstream_xchacha20poly1305_pull`
// failure, thrown from the same native binding the legitimate session's own
// successful decrypt just went through moments earlier).
//
// DESIGN NOTE -- why this is capture-based over `.rawStream`, not tcpdump:
// literal packet capture (the ticket's original phrasing) needs
// root/raw-socket access this environment doesn't have and shouldn't be
// granted for a routine task. `@hyperswarm/secret-stream`'s NoiseSecretStream
// (confirmed by reading node_modules/@hyperswarm/secret-stream/index.js)
// publicly exposes `.rawStream` -- the real underlying duplex BELOW the
// Noise framing/encryption layer, fed by hyperdht's own
// `dht.createRawStream()` (a real UDX socket -- confirmed by reading
// node_modules/hyperdht/lib/connect.js and lib/server.js, both client-dial
// and server-accept paths). A Hyperswarm `conn` (from
// `swarm.on('connection', conn => ...)`) *is* a NoiseSecretStream instance
// (confirmed by reading node_modules/hyperswarm/index.js's own `_connect`/
// `emit('connection', ...)` call sites). Tapping `conn.rawStream` observes
// exactly the bytes that would traverse the physical wire -- an in-process
// but otherwise faithful capture point, no packet capture or root needed.
//
// CRITICAL GOTCHA (read before touching the capture code below): you MUST
// use `rawStream.prependListener('data', ...)`, never `.on('data', ...)`.
// NoiseSecretStream's own `_open()` attaches its OWN internal `_onrawdata`
// listener the moment the stream opens -- before any test code gets a
// reference to attach its own. `_onrawdata`/`_incoming` (see
// node_modules/@hyperswarm/secret-stream/index.js) decrypt via
// `subarray()` VIEWS into the SAME chunk Buffer passed to every 'data'
// listener, and Node/streamx invoke listeners in *registration order* --
// so a plain `.on('data', ...)` capture runs SECOND, after the internal
// listener has already decrypted the buffer in place, and would silently
// capture ALREADY-DECRYPTED plaintext while looking exactly like a correct
// ciphertext capture. Confirmed empirically while writing this file: a
// `.on('data', ...)` capture on the receiving side's `.rawStream` DID
// contain the marker (a false pass on the exact property this test exists
// to prove); switching to `prependListener` (which always runs first,
// regardless of attach order) made the capture show the real pre-decrypt
// ciphertext, and the marker correctly disappeared. This is exactly the
// "weak test that passes on accident" failure mode the ticket warns about,
// just one level deeper (buffer-mutation-order, not encoding) -- if you
// ever see this test start failing after a secret-stream dependency bump,
// check whether `_onrawdata`'s in-place-decrypt behavior changed before
// assuming the capture methodology broke.
//
// SECOND GOTCHA -- join staggering: this Hyperswarm version's own
// PeerDiscovery picks EITHER `dht.announce()` OR `dht.lookup()` for a given
// refresh cycle, never both (`const announcing = this.isServer` in
// node_modules/hyperswarm/lib/peer-discovery.js -- server status wins over
// client status even when a peer set both `server:true` AND `client:true`).
// If every peer on a topic joins in the SAME instant (as a naive test
// would), on this testnet's sub-millisecond local latency NONE of them ever
// observes another's freshly-landed announce during their own single
// announce-cum-lookup pass, and the only retry is the swarm's own
// 10-minute jittered refresh timer -- confirmed empirically: simultaneous
// joins never connected even after 15s of polling. `joinAndWait` below
// staggers each peer's join (fully flushed before the next one starts),
// which connects reliably (confirmed in 3/3 empirical runs) -- this mirrors
// how real peers almost never join in the exact same tick anyway.
'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const net = require('node:net')
const NodeModule = require('node:module')
const fs = require('node:fs')
const fsPromises = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const { EventEmitter } = require('node:events')

const crypto = require('hypercore-crypto')
const Hyperswarm = require('hyperswarm')
const createTestnet = require('hyperdht/testnet')
const { Method, FrameType, ErrorCode, EventName } = require('../schema')

const INDEX_PATH = require.resolve('../index.js')

// Every real Hyperswarm instance this file creates -- whether directly (the
// confidentiality/authentication/wrong-peer-session tests below) or
// indirectly (bootWorklet()'s own `new Hyperswarm()` inside index.js, for
// the pairing-flow wrong-peer tests) -- must talk to a local, offline DHT
// testnet, never the real internet bootstrap. `TestnetHyperswarm` covers
// direct construction; the require.cache swap below covers index.js's own
// internal construction (same two-part technique as
// pairing-real-roundtrip.test.js -- see its header for the general
// pattern). NOTE: `Hyperswarm` the *variable* above is bound to the REAL
// class at require-time, before the swap -- swapping require.cache only
// affects code that requires('hyperswarm') AFTER the swap (index.js, via
// bootWorklet's fresh require). This file's own direct tests must
// construct `TestnetHyperswarm`, never the plain `Hyperswarm` variable, or
// they silently try to hit the real public DHT.
let currentBootstrap = null
const swarmInstances = []
class TestnetHyperswarm extends Hyperswarm {
  constructor (opts = {}) {
    super({ ...opts, bootstrap: currentBootstrap })
    swarmInstances.push(this)
  }
}
require.cache[require.resolve('hyperswarm')].exports = TestnetHyperswarm

const BlindPairingReal = require('blind-pairing')
class FastBlindPairing extends BlindPairingReal {
  constructor (swarm, opts = {}) {
    super(swarm, { ...opts, poll: 300 })
  }
}
require.cache[require.resolve('blind-pairing')].exports = FastBlindPairing

test.after(() => Promise.all(swarmInstances.map((s) => s.destroy().catch(() => {}))))

// index.js requires 'bare-fs'/'bare-path' directly (Bare-runtime-only) --
// same stub as pairing-real-roundtrip.test.js/index.test.js's own identical
// comment. Only actually needed by the two PAIRING_* tests below (via
// bootWorklet), but harmless to install once for the whole file.
function stubBareRuntimeDepsForNode () {
  const fromDir = path.dirname(INDEX_PATH)
  const fsStub = { ...fs, ...fsPromises }
  for (const [specifier, stub] of [['bare-fs', fsStub], ['bare-path', path]]) {
    const resolved = require.resolve(specifier, { paths: [fromDir] })
    if (require.cache[resolved]) continue
    const fakeModule = new NodeModule(resolved, null)
    fakeModule.exports = stub
    fakeModule.loaded = true
    require.cache[resolved] = fakeModule
  }
}
stubBareRuntimeDepsForNode()

const tmpDirs = []
function tmpDir () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-noise-test-'))
  tmpDirs.push(dir)
  return dir
}
test.after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

// Copy of pairing-real-roundtrip.test.js's own bootWorklet (call/onEvent/
// onAnyEvent -- see that file's header for the general pattern), plus one
// addition: `swarm`, a direct reference to THIS worklet's own real internal
// Hyperswarm instance (index.js's own `const swarm = new Hyperswarm()`),
// recovered off the file-level `swarmInstances` array every TestnetHyperswarm
// construction pushes to (including index.js's own internal one, thanks to
// the require.cache swap above). This is used only for two purposes that
// have no RPC surface of their own: (1) reading the worklet's OWN real
// public key as an independent oracle to check what index.js's own
// SWARM_CONNECTION event reports, and (2) `swarm.flush()`, to stagger two
// worklets' joins against this local testnet exactly like `joinAndWait`
// does for direct TestnetHyperswarm tests (see this file's header's "SECOND
// GOTCHA") -- neither bypasses or substitutes for the RPC-driven behavior
// actually under test.
function bootWorklet () {
  const ipc = new EventEmitter()
  const writeListeners = new Set()
  ipc.write = (buf) => { for (const listener of writeListeners) listener(buf) }

  global.BareKit = { IPC: ipc }
  global.Bare = {
    argv: [tmpDir()],
    on: () => {},
    exit: (code) => { throw new Error('Bare.exit(' + code + ') called during test') }
  }

  const swarmsBefore = swarmInstances.length
  delete require.cache[INDEX_PATH]
  require(INDEX_PATH)
  const swarm = swarmInstances[swarmsBefore] // this worklet's own real internal Hyperswarm instance

  let nextId = 1
  function call (method, params) {
    const id = nextId++
    const response = new Promise((resolve) => {
      const onWrite = (buf) => {
        if (buf.length < 5 || buf[4] !== FrameType.JSON) return
        const len = buf.readUInt32BE(0)
        let msg
        try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
        if (msg.id !== id) return
        writeListeners.delete(onWrite)
        resolve(msg)
      }
      writeListeners.add(onWrite)
    })

    const body = Buffer.from(JSON.stringify({ id, m: method, p: params }))
    const frame = Buffer.concat([Buffer.from([FrameType.JSON]), body])
    const lengthPrefix = Buffer.alloc(4)
    lengthPrefix.writeUInt32BE(frame.length, 0)
    ipc.emit('data', Buffer.concat([lengthPrefix, frame]))

    return response
  }

  // Resolves on the next event matching `matcher`, or rejects after
  // `timeoutMs` if none arrives.
  function onEvent (matcher, timeoutMs = 20000) {
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        writeListeners.delete(onWrite)
        reject(new Error('timed out waiting for event'))
      }, timeoutMs)
      const onWrite = (buf) => {
        if (buf.length < 5 || buf[4] !== FrameType.JSON) return
        const len = buf.readUInt32BE(0)
        let msg
        try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
        if (!msg.ev || !matcher(msg)) return
        clearTimeout(timer)
        writeListeners.delete(onWrite)
        resolve(msg)
      }
      writeListeners.add(onWrite)
    })
  }

  // Subscribes to every future matching event, not just the next one.
  // Returns an unsubscribe function.
  function onAnyEvent (matcher, cb) {
    const onWrite = (buf) => {
      if (buf.length < 5 || buf[4] !== FrameType.JSON) return
      const len = buf.readUInt32BE(0)
      let msg
      try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
      if (!msg.ev || !matcher(msg)) return
      cb(msg)
    }
    writeListeners.add(onWrite)
    return () => writeListeners.delete(onWrite)
  }

  return { call, onEvent, onAnyEvent, swarm }
}

// Joins `topicHex` via the worklet's own real Method.SWARM_JOIN RPC, then
// waits for that worklet's own real internal swarm to settle its discovery
// round (see bootWorklet's own comment on `swarm` for why this reference is
// legitimate here) -- the RPC-driven analogue of this file's own
// `joinAndWait`, needed for the same reason (this file's header's "SECOND
// GOTCHA": simultaneous joins never converge on this local testnet).
async function joinWorkletAndWait (worklet, topicHex) {
  await worklet.call(Method.SWARM_JOIN, { topic: topicHex })
  await worklet.swarm.flush()
  await new Promise((resolve) => setTimeout(resolve, 200))
}

// THIRD GOTCHA -- topic tagging is one-directional under this staggered
// join: confirmed by reading node_modules/hyperswarm/lib/peer-discovery.js
// -- since BOTH sides join with `{server:true}`, BOTH always pick
// `dht.announce()` over `dht.lookup()` for their OWN query (`const
// announcing = this.isServer`), and a peer only gets tagged onto
// `info.topics` (which is what gates index.js's own SWARM_CONNECTION emission
// -- see its `swarm.on('connection', ...)`'s `announce`/`info.on('topic', ...)`)
// via THIS side's OWN discovery query encountering it (`_handlePeer` ->
// `peerInfo._topic()`). The peer who joins/announces FIRST and fully
// flushes before the second peer ever announces has, by the time the
// resulting connection lands (a purely passive inbound dial from the second
// peer), already-exhausted its own one-shot query with nothing to find --
// so ITS side's `info.topics` stays empty (never fires 'topic') until its
// own NEXT refresh cycle, which is minutes away. Confirmed empirically:
// with `joinWorkletAndWait` alone, the second joiner (the one whose own
// query is what actually discovers the other and connects out) gets
// SWARM_CONNECTION correctly, but the first joiner's side never does.
// Forcing one more `swarm.join(...).flushed()` pass -- AFTER both sides
// have already joined once -- gives the first joiner's side a fresh
// discovery round that now finds the (already-connected, already-announced)
// other peer, tagging the topic and firing the real SWARM_CONNECTION event
// through index.js's own code path (confirmed: 3/3 empirical runs).
async function forceTopicTag (worklet, topicHex) {
  await worklet.swarm.join(Buffer.from(topicHex, 'hex'), { server: true, client: true }).flushed()
}

function tick () {
  return new Promise((resolve) => setImmediate(resolve))
}

async function waitUntil (predicate, { timeoutMs = 15000, intervalMs = 100 } = {}) {
  const start = Date.now()
  while (!predicate()) {
    if (Date.now() - start > timeoutMs) {
      throw new Error(`waitUntil: condition never became true within ${timeoutMs}ms`)
    }
    await new Promise((resolve) => setTimeout(resolve, intervalMs))
  }
}

// See this file's header ("SECOND GOTCHA") for why joins must be staggered,
// not simultaneous, against this local testnet.
async function joinAndWait (swarm, topic) {
  const discovery = swarm.join(topic, { server: true, client: true })
  await discovery.flushed()
  await swarm.flush()
  await new Promise((resolve) => setTimeout(resolve, 200))
}

// Accumulates `data` events from `stream` until the concatenated bytes
// include `needle`, then resolves with everything accumulated so far.
// Used on BOTH the real decrypted app stream (sanity: delivery happened)
// and the raw pre-Noise wire stream (the actual confidentiality capture).
function accumulateUntilIncludes (stream, needle, { timeoutMs = 15000 } = {}) {
  return new Promise((resolve, reject) => {
    const chunks = []
    const timer = setTimeout(
      () => reject(new Error('timed out waiting for expected bytes on stream')),
      timeoutMs
    )
    stream.on('data', (chunk) => {
      chunks.push(Buffer.from(chunk))
      if (Buffer.concat(chunks).includes(needle)) {
        clearTimeout(timer)
        resolve(Buffer.concat(chunks))
      }
    })
  })
}

test('CONFIDENTIALITY + AUTHENTICATION: two real Hyperswarm/Noise peers on a local testnet -- the plaintext marker never appears on the raw wire, and both sides prove an authenticated handshake with the OTHER side\'s real key',
  async (t) => {
    const testnet = await createTestnet(3)
    currentBootstrap = testnet.bootstrap
    t.after(() => testnet.destroy().catch(() => {}))

    const swarmA = new TestnetHyperswarm()
    const swarmB = new TestnetHyperswarm()
    t.after(() => Promise.all([swarmA.destroy().catch(() => {}), swarmB.destroy().catch(() => {})]))

    const connAPromise = new Promise((resolve) => {
      swarmA.once('connection', (conn) => { conn.on('error', () => {}); resolve(conn) })
    })
    const connBPromise = new Promise((resolve) => {
      swarmB.once('connection', (conn) => { conn.on('error', () => {}); resolve(conn) })
    })

    const topic = crypto.randomBytes(32)
    await joinAndWait(swarmA, topic)
    await joinAndWait(swarmB, topic)

    const [connA, connB] = await Promise.all([connAPromise, connBPromise])

    // -- AUTHENTICATION -- not "some" key: THE specific, real key each
    // swarm generated for itself. A spoofed/relayed/unauthenticated
    // transport could still end up *connected* without this being true.
    assert.deepEqual(connA.remotePublicKey, swarmB.keyPair.publicKey, "A's remotePublicKey must be B's REAL public key")
    assert.deepEqual(connB.remotePublicKey, swarmA.keyPair.publicKey, "B's remotePublicKey must be A's REAL public key")
    assert.deepEqual(connA.publicKey, swarmA.keyPair.publicKey, "A's own publicKey must be A's REAL public key")
    assert.deepEqual(connB.publicKey, swarmB.keyPair.publicKey, "B's own publicKey must be B's REAL public key")
    // Noise's own authenticated-handshake proof: both sides independently
    // derive the transcript hash from the SAME DH exchange -- an
    // unauthenticated or substituted transport cannot produce equal values.
    assert.ok(Buffer.isBuffer(connA.handshakeHash) && connA.handshakeHash.length > 0, 'handshakeHash must be a real, non-empty value')
    assert.deepEqual(connA.handshakeHash, connB.handshakeHash, 'both sides must derive the IDENTICAL handshake transcript hash')

    // -- CONFIDENTIALITY -- tap B's RAW wire-level stream (see header's
    // "CRITICAL GOTCHA" for why `prependListener`, never `.on`, is required
    // here) -- exactly the ciphertext bytes a network eavesdropper
    // downstream of A would see arriving over the wire.
    const rawCaptured = []
    connB.rawStream.prependListener('data', (chunk) => rawCaptured.push(Buffer.from(chunk)))

    const marker = crypto.randomBytes(32).toString('hex') // fresh, high-entropy, never hardcoded
    const markerBuf = Buffer.from(marker)

    const decryptedReceived = accumulateUntilIncludes(connB, markerBuf)
    connA.write(markerBuf)
    await decryptedReceived // sanity: the marker DID actually get delivered over the normal decrypted channel

    // A couple of ticks so any already-in-flight raw chunk finishes landing
    // in rawCaptured too (belt and suspenders -- the marker's own raw bytes
    // must already have arrived before the decrypted layer could observe
    // it, but this guards against any trailing frame).
    await tick()
    await tick()

    const rawAll = Buffer.concat(rawCaptured)
    assert.ok(rawAll.length > 0, 'sanity: something was actually captured on the raw wire')
    assert.equal(rawAll.indexOf(markerBuf), -1, 'the plaintext marker must NEVER appear in the raw (post-Noise-encryption) wire bytes')
  })

test('AUTHENTICATION (through the worklet\'s own RPC/event contract, not the raw library): two real bootWorklet() instances join a real swarm topic, and index.js\'s own SWARM_CONNECTION event reports each side\'s ACTUAL real remote public key',
  async (t) => {
    const testnet = await createTestnet(3)
    currentBootstrap = testnet.bootstrap
    t.after(() => testnet.destroy().catch(() => {}))

    // The test above proves confidentiality + authentication against the
    // raw hyperswarm library objects directly (`swarmA.keyPair`,
    // `conn.remotePublicKey`, ...) -- it never calls bootWorklet(), so it
    // cannot catch a regression inside index.js's OWN connection-handling/
    // event-emission code (the `swarm.on('connection', ...)` handler and
    // its `send({ ev: EventName.SWARM_CONNECTION, ... })` around index.js's
    // line 136-157). This test closes exactly that gap: it drives the real
    // Method.SWARM_JOIN RPC on two real worklets and asserts the real
    // SWARM_CONNECTION event's `peer` field is each side's ACTUAL real
    // public key -- not inferred from the library working, observed through
    // index.js's own wire contract, the same technique the PAIRING_* tests
    // below already use for pairing.candidate.
    const workletA = bootWorklet()
    const workletB = bootWorklet()

    // Oracle only (see bootWorklet's own comment on `swarm`) -- no RPC
    // currently exposes a worklet's own public key, so this is the only way
    // to know, independently of the event under test, what the CORRECT
    // answer should be.
    const aRealKeyHex = workletA.swarm.keyPair.publicKey.toString('hex')
    const bRealKeyHex = workletB.swarm.keyPair.publicKey.toString('hex')
    assert.notEqual(aRealKeyHex, bRealKeyHex, 'sanity: two independently booted worklets must have DIFFERENT real keys')

    const topicHex = crypto.randomBytes(32).toString('hex')

    const aConnectionEvent = workletA.onEvent(
      (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topicHex
    )
    const bConnectionEvent = workletB.onEvent(
      (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topicHex
    )

    // Staggered, not simultaneous (this file's header's "SECOND GOTCHA").
    await joinWorkletAndWait(workletA, topicHex)
    await joinWorkletAndWait(workletB, topicHex)

    // See `forceTopicTag`'s own comment ("THIRD GOTCHA"): A joined/announced
    // FIRST and already exhausted its own one-shot discovery query before B
    // ever announced, so the resulting connection (B dialing A) is purely
    // passive on A's side and never gets topic-tagged on its own -- one more
    // discovery round for A, now that B is actually there to find, fixes
    // that and lets index.js's own SWARM_CONNECTION fire on A's side too.
    await forceTopicTag(workletA, topicHex)

    const [aEvent, bEvent] = await Promise.all([aConnectionEvent, bConnectionEvent])

    assert.equal(
      aEvent.p.peer,
      bRealKeyHex,
      'index.js\'s own SWARM_CONNECTION event on A\'s side must report B\'s REAL public key, not a spoofed/wrong/library-internal value'
    )
    assert.equal(
      bEvent.p.peer,
      aRealKeyHex,
      'index.js\'s own SWARM_CONNECTION event on B\'s side must report A\'s REAL public key'
    )
  })

test('NEGATIVE CONTROL: the SAME capture technique finds the marker on a raw, unencrypted net.Socket -- proves the harness genuinely observes wire bytes rather than silently capturing nothing',
  async (t) => {
    const marker = crypto.randomBytes(32).toString('hex')
    const markerBuf = Buffer.from(marker)

    const server = net.createServer()
    server.on('error', () => {})
    await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve))

    // `server.close()` alone waits for every existing connection to END
    // before its callback fires -- it does NOT forcibly close them. Without
    // explicitly destroying the accepted socket first, `server.close()`
    // would hang forever (confirmed empirically: this exact ordering bug
    // deadlocked this test's very first draft, since nothing else was ever
    // going to end the still-open connection). One combined `t.after` that
    // destroys both sockets BEFORE awaiting `server.close()` avoids relying
    // on hook-registration order to get this right.
    let serverSock = null
    const servedSocketPromise = new Promise((resolve) => {
      server.once('connection', (sock) => { sock.on('error', () => {}); serverSock = sock; resolve(sock) })
    })

    const client = net.connect({ host: '127.0.0.1', port: server.address().port })
    client.on('error', () => {})
    t.after(async () => {
      client.destroy()
      if (serverSock) serverSock.destroy()
      await new Promise((resolve) => server.close(resolve))
    })
    await new Promise((resolve, reject) => {
      client.once('connect', resolve)
      client.once('error', reject)
    })

    const serverSockReady = await servedSocketPromise
    const capturedPromise = accumulateUntilIncludes(serverSockReady, markerBuf)
    client.write(markerBuf)
    const capturedAll = await capturedPromise

    assert.ok(
      capturedAll.includes(markerBuf),
      'raw TCP capture must contain the plaintext marker byte-for-byte -- this is what proves test 1\'s "marker not found" result is a real finding, not a broken/no-op capture'
    )
  })

test('WRONG-PEER REJECTION (pairing invite): a structurally fabricated, non-decodable invite is rejected immediately with a real typed error -- not a silent success or a hang',
  async (t) => {
    const testnet = await createTestnet(3)
    currentBootstrap = testnet.bootstrap
    t.after(() => testnet.destroy().catch(() => {}))

    const inviter = bootWorklet()
    const wrongPeer = bootWorklet()

    const createRes = await inviter.call(Method.PAIRING_CREATE_INVITE, {})
    assert.ok(createRes.ok, 'createInvite ok: ' + JSON.stringify(createRes.err))
    const realInviteBytes = Buffer.from(createRes.ok.invite, 'base64')

    // Random bytes, with byte 0 forced away from 1 -- blind-pairing-core's
    // real encoder always writes version=1 (confirmed by reading
    // node_modules/blind-pairing-core/lib/messages.js's Invite.encode), so
    // this deterministically fails decode instead of gambling on random
    // bytes' 1/256 chance of accidentally starting with a valid version.
    const fabricated = crypto.randomBytes(realInviteBytes.length)
    fabricated[0] = 0x02

    const res = await wrongPeer.call(Method.PAIRING_ACCEPT_INVITE, {
      invite: fabricated.toString('base64'),
      timeoutMs: 5000
    })
    assert.ok(!res.ok, 'a fabricated invite must never let the wrong peer pair: ' + JSON.stringify(res.ok))
    assert.equal(
      res.err && res.err.code,
      ErrorCode.INVALID_INVITE,
      'must fail with the real, typed INVALID_INVITE error, not something else or nothing: ' + JSON.stringify(res.err)
    )
  })

test('WRONG-PEER REJECTION (pairing invite): a real, validly-encoded invite whose seed the wrong peer does not actually possess reaches the right rendezvous channel but never completes -- proven by DIRECTLY observing that no PAIRING_CANDIDATE notification ever fires for it (not merely inferred from the wrong peer\'s own bounded timeout), contrasted with a positive control on the SAME inviter/invite that DOES fire one and pairs',
  async (t) => {
    const testnet = await createTestnet(3)
    currentBootstrap = testnet.bootstrap
    t.after(() => testnet.destroy().catch(() => {}))

    const inviter = bootWorklet()
    const wrongPeer = bootWorklet()
    const rightPeer = bootWorklet()

    const createRes = await inviter.call(Method.PAIRING_CREATE_INVITE, {})
    assert.ok(createRes.ok, 'createInvite ok: ' + JSON.stringify(createRes.err))
    const { invite, inviteId } = createRes.ok
    const realInviteBytes = Buffer.from(invite, 'base64')

    // blind-pairing-core's own wire layout (confirmed by reading
    // node_modules/blind-pairing-core/lib/messages.js's Invite.encode):
    // byte 0 = version, byte 1 = flags, bytes [2,33] = seed (32 bytes),
    // bytes [34,65] = discoveryKey (32 bytes, present because index.js's
    // own PAIRING_CREATE_INVITE always passes one). Flipping a byte WITHIN
    // seed's range corrupts the seed-derived keypair blind-pairing-core's
    // own request.open()/confirm() crypto requires, while leaving
    // discoveryKey (the swarm-level rendezvous channel) untouched -- so,
    // unlike the fully-fabricated invite in the test above, this candidate
    // genuinely reaches the real inviter's `pairing.addMember(...)` over a
    // real swarm connection, and is rejected there by blind-pairing-core's
    // own signature/decrypt check instead of never finding the channel at
    // all. index.js's own comment above PAIRING_CREATE_INVITE's `onadd`
    // documents that this specific failure is caught internally and never
    // propagated to the inviter -- no PAIRING_CANDIDATE event fires. An
    // earlier version of this test only inferred that from the wrong peer's
    // own PAIRING_TIMEOUT, which (confirmed empirically: re-running this
    // exact harness with the byte-flip below removed entirely -- i.e. a
    // real, VALID, unmodified invite -- produced the identical
    // PAIRING_TIMEOUT result at the same ~5s timing) carries NO information
    // about whether the seed was actually rejected, since nothing in that
    // version of the harness ever confirmed any candidate, corrupted or
    // not. Fixed below by directly watching the inviter's own event stream
    // for PAIRING_CANDIDATE and asserting it never fires, then proving that
    // same listener genuinely CAN observe one when a real, unmodified
    // invite from the SAME inviter is used (the positive control at the
    // bottom of this test).
    const corruptedSeedInvite = Buffer.from(realInviteBytes)
    corruptedSeedInvite[10] ^= 0xff

    let candidateFiredForCorrupted = false
    const watchForCandidate = inviter.onEvent(
      (msg) => msg.ev === EventName.PAIRING_CANDIDATE && msg.p.inviteId === inviteId,
      5500
    ).then(
      () => { candidateFiredForCorrupted = true },
      () => {} // expected: no candidate ever notified within the window
    )

    const startedAt = Date.now()
    const res = await wrongPeer.call(Method.PAIRING_ACCEPT_INVITE, {
      invite: corruptedSeedInvite.toString('base64'),
      timeoutMs: 5000
    })
    const elapsedMs = Date.now() - startedAt
    await watchForCandidate

    assert.ok(!res.ok, 'a corrupted-seed invite must never let the wrong peer pair: ' + JSON.stringify(res.ok))
    assert.equal(
      res.err && res.err.code,
      ErrorCode.PAIRING_TIMEOUT,
      'must fail with the real, typed PAIRING_TIMEOUT error, not something else or nothing: ' + JSON.stringify(res.err)
    )
    assert.ok(elapsedMs < 8000, `must actually be BOUNDED by timeoutMs, not hang past it (took ${elapsedMs}ms)`)
    assert.equal(
      candidateFiredForCorrupted,
      false,
      'a corrupted-seed candidate must NEVER cause a PAIRING_CANDIDATE notification -- if this fires, blind-pairing-core\'s own seed/signature check silently stopped rejecting tampered invites, and the PAIRING_TIMEOUT above would then be masking a real regression instead of proving rejection'
    )

    // POSITIVE CONTROL -- proves the listener above genuinely works and
    // this "never fires" result is a real finding, not a broken/no-op
    // event subscription: the SAME inviter/invite, unmodified, given to a
    // well-behaved third peer, DOES produce a PAIRING_CANDIDATE and DOES
    // pair successfully once confirmed.
    const confirmKey = crypto.randomBytes(32)
    const candidateEventPromise = inviter.onEvent(
      (msg) => msg.ev === EventName.PAIRING_CANDIDATE && msg.p.inviteId === inviteId,
      5000
    )
    const rightAcceptPromise = rightPeer.call(Method.PAIRING_ACCEPT_INVITE, { invite, timeoutMs: 10000 })
    const candidateEvent = await candidateEventPromise
    await inviter.call(Method.PAIRING_CONFIRM_CANDIDATE, {
      inviteId,
      candidateId: candidateEvent.p.candidateId,
      key: confirmKey.toString('base64')
    })
    const rightAcceptRes = await rightAcceptPromise

    assert.ok(
      rightAcceptRes.ok,
      'positive control: the SAME inviter\'s real, unmodified invite must still pair successfully -- proves the PAIRING_CANDIDATE listener used above genuinely observes real candidate notifications: ' + JSON.stringify(rightAcceptRes.err)
    )
    assert.equal(
      rightAcceptRes.ok.key,
      confirmKey.toString('base64'),
      'positive control: the well-behaved peer must receive exactly the confirmed key'
    )
  })

test('WRONG-PEER REJECTION (Noise session scope): a third real peer sharing the same swarm topic, with its own real keypair, gets a cryptographically independent Noise session -- different handshake identity, AND its own real (but different) session key cannot decrypt ciphertext captured from the legitimate pair\'s session (a literal decrypt-with-wrong-key attempt, not inferred from ciphertext/session opacity)',
  async (t) => {
    const testnet = await createTestnet(3)
    currentBootstrap = testnet.bootstrap
    t.after(() => testnet.destroy().catch(() => {}))

    const swarmA = new TestnetHyperswarm()
    const swarmB = new TestnetHyperswarm()
    const swarmC = new TestnetHyperswarm() // the "wrong peer" -- its own real, independent keypair, never given any of A/B's secrets
    t.after(() => Promise.all([swarmA, swarmB, swarmC].map((s) => s.destroy().catch(() => {}))))

    const connsA = new Map()
    const connsB = new Map()
    const connsC = new Map()
    for (const [swarm, map] of [[swarmA, connsA], [swarmB, connsB], [swarmC, connsC]]) {
      swarm.on('connection', (conn, info) => {
        conn.on('error', () => {}) // teardown-time ECONNRESET is expected noise, not a test failure
        map.set(info.publicKey.toString('hex'), conn)
      })
    }

    const topic = crypto.randomBytes(32)
    await joinAndWait(swarmA, topic)
    await joinAndWait(swarmB, topic)
    await joinAndWait(swarmC, topic)

    const aHex = swarmA.keyPair.publicKey.toString('hex')
    const bHex = swarmB.keyPair.publicKey.toString('hex')
    const cHex = swarmC.keyPair.publicKey.toString('hex')
    await waitUntil(() => connsA.has(bHex) && connsA.has(cHex) && connsC.has(aHex) && connsB.has(aHex))

    const connAB = connsA.get(bHex) // A's connection to B
    const connBA = connsB.get(aHex) // B's connection to A -- the legitimate session's OTHER end
    const connAC = connsA.get(cHex) // A's connection to C
    const connCA = connsC.get(aHex) // C's OWN connection to A -- C's own real, independent session key material

    assert.notEqual(connAB, connAC, 'A must hold a genuinely SEPARATE connection/socket per peer')
    assert.ok(
      !connAB.handshakeHash.equals(connAC.handshakeHash),
      "A<->B and A<->C must be cryptographically distinct Noise sessions -- C's real keypair, connecting to the SAME peer A on the SAME topic, shares NO session identity with A<->B's session"
    )

    // LITERAL decrypt-with-wrong-key attempt, per the ticket's own explicit
    // requirement ("must be tested, not inferred from ciphertext opacity"):
    // wrap B's REAL `_decrypt.next` -- the actual low-level
    // sodium-secretstream `Pull` object B's real connection uses to decrypt
    // every message it receives from A -- to snapshot the untouched
    // ciphertext block BEFORE `next()` decrypts (and mutates) it in place
    // (same in-place-decrypt aliasing this file's header's own "CRITICAL
    // GOTCHA" documents: confirmed by reading
    // node_modules/@hyperswarm/secret-stream/index.js's `_incoming()`,
    // where the plaintext output buffer is a subarray VIEW into the SAME
    // memory as the ciphertext input). Matching the snapshot against the
    // plaintext `next()` actually produces picks out EXACTLY the marker's
    // own ciphertext block, immune to any other traffic (e.g. keepalives)
    // that might also cross the connection.
    const marker = crypto.randomBytes(32).toString('hex')
    const markerBuf = Buffer.from(marker)

    let markerCipher = null
    const realDecryptNext = connBA._decrypt.next.bind(connBA._decrypt)
    connBA._decrypt.next = (cipher, message) => {
      const cipherSnapshot = Buffer.from(cipher) // BEFORE next() decrypts cipher's bytes in place
      const plain = realDecryptNext(cipher, message)
      if (Buffer.from(plain).equals(markerBuf)) markerCipher = cipherSnapshot
      return plain
    }

    const decryptedReceived = accumulateUntilIncludes(connBA, markerBuf)
    connAB.write(markerBuf)
    await decryptedReceived // sanity: B's REAL session genuinely decrypted this exact ciphertext block correctly, under B's real (correct) key

    assert.ok(markerCipher, 'must have captured the marker\'s own real ciphertext block off B\'s real decrypt path')

    // Hand that EXACT real ciphertext -- which B's own real key just
    // decrypted successfully, above -- to C's OWN real, independent decrypt
    // object (`connCA._decrypt`, a real sodium-secretstream `Pull` instance
    // keyed with C's own real session rx key, from C's own real Noise
    // handshake with A -- never given any of A/B's secrets). Confirmed via
    // node_modules/sodium-secretstream and node_modules/sodium-native:
    // `crypto_secretstream_xchacha20poly1305_pull` throws ('pull failed')
    // the moment Poly1305 authentication fails, which a different session
    // key always causes here.
    let wrongKeyError = null
    let wrongKeyPlaintext = null
    try {
      wrongKeyPlaintext = connCA._decrypt.next(markerCipher)
    } catch (err) {
      wrongKeyError = err
    }

    assert.ok(
      wrongKeyError,
      'C must NOT be able to decrypt A<->B\'s real captured ciphertext using C\'s own real (but different) session key -- decrypt must throw, not silently produce output'
    )
    assert.match(
      String(wrongKeyError && wrongKeyError.message),
      /pull failed/i,
      'must fail via the real sodium-secretstream authentication check, not some unrelated error'
    )
    assert.equal(
      wrongKeyPlaintext,
      null,
      'no plaintext must ever have been produced from the wrong-key decrypt attempt'
    )
  })
