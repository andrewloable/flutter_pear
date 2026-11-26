// Reconnect data (KinNode gap G16): a later connection to a peer this worklet was connected to
// before must carry data both ways, or be closed so Hyperswarm makes one that does. Two real
// worklets on a local DHT testnet, never the public DHT. Helpers copied from
// connection-control.test.js.
//
// RUNBOOK -- from packages/flutter_pear/pear-end/:
//   node --test test/reconnect-data.test.js
'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const NodeModule = require('node:module')
const fs = require('node:fs')
const fsPromises = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const { EventEmitter } = require('node:events')

const Hyperswarm = require('hyperswarm')
const createTestnet = require('hyperdht/testnet')
const hypercoreCrypto = require('hypercore-crypto')
const { Method, FrameType, EventName, SwarmState } = require('../schema')

const INDEX_PATH = require.resolve('../index.js')

// Same testnet-swap technique as noise-confidentiality.test.js's own
// TestnetHyperswarm -- see that file's header for the full rationale (never
// hit the real public DHT from a test).
let currentBootstrap = null
const swarmInstances = []
// Key pairs for the next worklets booted, in order (empty: each makes its own), so a test can fix
// which side wins Hyperswarm's duplicate tie-break.
const nextKeyPairs = []
class TestnetHyperswarm extends Hyperswarm {
  constructor (opts = {}) {
    super({ ...opts, bootstrap: currentBootstrap, ...(nextKeyPairs.length ? { keyPair: nextKeyPairs.shift() } : {}) })
    swarmInstances.push(this)
  }
}
require.cache[require.resolve('hyperswarm')].exports = TestnetHyperswarm

test.after(() => Promise.all(swarmInstances.map((s) => s.destroy().catch(() => {}))))

// Same Bare-runtime-only-dep stub as index.test.js/noise-confidentiality.test.js.
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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-reconnect-data-test-'))
  tmpDirs.push(dir)
  return dir
}
test.after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

// Trimmed copy of noise-confidentiality.test.js's own bootWorklet -- same
// real IPC wire framing, plus exposing this worklet's own real internal
// Hyperswarm instance (needed for joinWorkletAndWait/forceTopicTag's
// staggered-join workaround below).
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
  const swarm = swarmInstances[swarmsBefore]

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
  // `timeoutMs` if none arrives -- a fresh call always waits for a NEW
  // event from the moment it's invoked, never a past one, which is exactly
  // what's needed to prove the SECOND SWARM_JOIN call below produces a
  // genuinely fresh replay, not just observing the original connection's
  // event.
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

  return { call, onEvent, swarm }
}

// Identical staggered-join workaround as noise-confidentiality.test.js's own
// joinWorkletAndWait/forceTopicTag -- see that file's "SECOND GOTCHA"/"THIRD
// GOTCHA" comments for the full empirical rationale (simultaneous joins on
// this local testnet never converge; the first joiner's side needs one more
// discovery pass after the second joiner has already connected).
async function joinWorkletAndWait (worklet, topicHex) {
  await worklet.call(Method.SWARM_JOIN, { topic: topicHex })
  await worklet.swarm.flush()
  await new Promise((resolve) => setTimeout(resolve, 200))
}

async function forceTopicTag (worklet, topicHex) {
  await worklet.swarm.join(Buffer.from(topicHex, 'hex'), { server: true, client: true }).flushed()
}


const TOPIC = 'ee'.repeat(32)

// Two worklets connected on TOPIC (the staggered join the other suites use), with A as the
// side under test. Returns once both sides have reported the connection.
async function connectedPair (t) {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())

  const a = bootWorklet()
  const b = bootWorklet()
  const isConn = (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === TOPIC
  const aConn = a.onEvent(isConn)
  const bConn = b.onEvent(isConn)
  await joinWorkletAndWait(a, TOPIC)
  await joinWorkletAndWait(b, TOPIC)
  await forceTopicTag(a, TOPIC)
  const [ac, bc] = await Promise.all([aConn, bConn])
  return { a, b, aSeesB: ac.p.peer, bSeesA: bc.p.peer }
}

const isClose = (peer) => (msg) => msg.ev === EventName.CONNECTION_CLOSE && msg.p.topic === TOPIC && msg.p.peer === peer
const isConnection = (peer) => (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === TOPIC && msg.p.peer === peer
const settle = (ms = 1500) => new Promise((resolve) => setTimeout(resolve, ms))


const b64 = (s) => Buffer.from(s).toString('base64')
const topicOf = (n) => (n.toString(16).padStart(2, '0')).repeat(32)

// One round: both join `topic` (A first, then B, staggered), wait for the connection on both
// sides, write one message each way, then optionally end the connection and leave the topic.
async function round (a, b, topic, label, opts) {
  const isConnT = (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topic
  const aConn = a.onEvent(isConnT, 20000).catch(() => null)
  const bConn = b.onEvent(isConnT, 20000).catch(() => null)
  await a.call(Method.SWARM_JOIN, { topic, acceptUnannounced: opts.acceptUnannounced })
  await a.swarm.flush()
  await settle(200)
  await b.call(Method.SWARM_JOIN, { topic, acceptUnannounced: opts.acceptUnannounced })
  await b.swarm.flush()
  const [ac, bc] = await Promise.all([aConn, bConn])
  const r = { label, aConnected: !!ac, bConnected: !!bc, raw: { a: a.raw.a, b: a.raw.b, aClose: a.raw.aClose, bClose: a.raw.bClose } }
  const peerState = (w) => {
    const out = []
    for (const info of w.swarm.peers.values()) out.push({ banned: info.banned, attempts: info.attempts, queued: info.queued, explicit: info.explicit, waiting: info.waiting, topics: info.topics.length, client: info.client, reconnecting: info.reconnecting })
    return out
  }
  if (!(ac && bc)) {
    const inf = a.raw.aLastInfo
    r.aLastConnClient = inf ? inf.client : null
    r.aLastConnTopics = inf ? inf.topics.map((x) => x.toString('hex').slice(0, 4)) : null
    r.joinedNow = topic.slice(0, 4)
    r.aSwarmConns = a.swarm.connections.size
    r.bSwarmConns = b.swarm.connections.size
    r.aPeers = peerState(a)
    r.bPeers = peerState(b)
    r.aDialing = a.swarm.connecting
    r.bDialing = b.swarm.connecting
  }
  if (ac && bc) {
    const toB = b.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === topic, 5000).catch(() => null)
    const toA = a.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === topic, 5000).catch(() => null)
    const wa = await a.call(Method.CONNECTION_WRITE, { peer: ac.p.peer, data: b64('a-' + label) })
    const wb = await b.call(Method.CONNECTION_WRITE, { peer: bc.p.peer, data: b64('b-' + label) })
    const [gotB, gotA] = await Promise.all([toB, toA])
    r.writeErrA = wa.err ? wa.err.code : null
    r.writeErrB = wb.err ? wb.err.code : null
    r.aToB = !!gotB && Buffer.from(gotB.p.data, 'base64').toString() === 'a-' + label
    r.bToA = !!gotA && Buffer.from(gotA.p.data, 'base64').toString() === 'b-' + label
    r.aConns = a.swarm.connections.size
    r.bConns = b.swarm.connections.size
    if (opts.leaveFirst) {
      await a.call(Method.SWARM_LEAVE, { topic })
      await b.call(Method.SWARM_LEAVE, { topic })
    }
    if (opts.destroy) await a.call(Method.CONNECTION_DESTROY, { peer: ac.p.peer })
    if (opts.destroyBoth) await b.call(Method.CONNECTION_DESTROY, { peer: bc.p.peer })
  }
  await settle(opts.pauseMs ?? 500)
  if (!opts.leaveFirst || !(ac && bc)) {
    await a.call(Method.SWARM_LEAVE, { topic })
    await b.call(Method.SWARM_LEAVE, { topic })
  }
  await settle(500)
  return r
}

async function runRounds (t, opts) {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())
  const a = bootWorklet()
  const b = bootWorklet()
  const raw = { a: 0, b: 0, aClose: 0, bClose: 0 }
  a.swarm.on('connection', (c, info) => { raw.a++; raw.aLastClient = info.client; raw.aLastInfo = info; c.on('close', () => raw.aClose++) })
  b.swarm.on('connection', (c) => { raw.b++; c.on('close', () => raw.bClose++) })
  a.raw = raw
  const results = []
  for (let n = 0; n < opts.rounds; n++) results.push(await round(a, b, topicOf(opts.base + n), String(n), opts))
  for (const r of results) t.diagnostic(JSON.stringify(r))
  return results
}

// KinNode measured on devices (flutter_pear 0.4.11): after a first connection between two
// devices ends, a later one on a new topic is reported to Dart but carries no data.
test('every round of connect, write, destroy, leave carries data both ways', async (t) => {
  const results = await runRounds(t, { rounds: 4, base: 1, acceptUnannounced: true, destroy: true })
  for (const r of results) {
    assert.ok(r.aConnected && r.bConnected, 'round ' + r.label + ' connected: ' + JSON.stringify(r))
    assert.ok(r.aToB && r.bToA, 'round ' + r.label + ' carried data: ' + JSON.stringify(r))
  }
})

test('variant: both sides destroy', async (t) => {
  const results = await runRounds(t, { rounds: 4, base: 0x20, acceptUnannounced: true, destroy: true, destroyBoth: true })
  for (const r of results) assert.ok(r.aToB && r.bToA, 'round ' + r.label + ': ' + JSON.stringify(r))
})

test('variant: both leave first, then both destroy', async (t) => {
  const results = await runRounds(t, { rounds: 4, base: 0x40, acceptUnannounced: true, destroy: true, destroyBoth: true, leaveFirst: true })
  for (const r of results) assert.ok(r.aToB && r.bToA, 'round ' + r.label + ': ' + JSON.stringify(r))
})

test('variant: both destroy, then stay joined 5 s before leaving', async (t) => {
  const results = await runRounds(t, { rounds: 4, base: 0x60, acceptUnannounced: true, destroy: true, destroyBoth: true, pauseMs: 5000 })
  for (const r of results) assert.ok(r.aToB && r.bToA, 'round ' + r.label + ': ' + JSON.stringify(r))
})

test('soak: both destroy, 8 rounds', async (t) => {
  const results = await runRounds(t, { rounds: 8, base: 0x80, acceptUnannounced: true, destroy: true, destroyBoth: true })
  for (const r of results) assert.ok(r.aToB && r.bToA, 'round ' + r.label + ': ' + JSON.stringify(r))
})

// The deterministic form of the bug: an inbound connection that carries no joined topic (here A
// simply left the topic it arrived on) must be given to a topic A joins next with
// acceptUnannounced, exactly as a new inbound connection would be. Before the fix A never
// reported it, while the dialer (B) kept treating it as connected.
test('joining an acceptUnannounced topic tags an open inbound connection that has no joined topic', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())
  const a = bootWorklet()
  const b = bootWorklet()
  const t0 = topicOf(0xa0)
  const t1 = topicOf(0xa1)
  const isConnOn = (topic) => (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topic
  const aConn = a.onEvent(isConnOn(t0))
  const bConn = b.onEvent(isConnOn(t0))
  // A joins first, so B dials A and the connection is inbound on A.
  await a.call(Method.SWARM_JOIN, { topic: t0, acceptUnannounced: true })
  await a.swarm.flush()
  await settle(200)
  await b.call(Method.SWARM_JOIN, { topic: t0, acceptUnannounced: true })
  await b.swarm.flush()
  const [ac] = await Promise.all([aConn, bConn])

  await a.call(Method.SWARM_LEAVE, { topic: t0 })
  await settle(300)
  const tagged = a.onEvent(isConnOn(t1), 3000).catch(() => null)
  await a.call(Method.SWARM_JOIN, { topic: t1, acceptUnannounced: true })
  const ev = await tagged
  assert.ok(ev, 'A reported the open inbound connection on the topic it joined')
  assert.equal(ev.p.peer, ac.p.peer)

  // And it carries data on that topic.
  const got = a.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === t1, 5000).catch(() => null)
  const bPeer = (await bConn).p.peer
  await b.call(Method.CONNECTION_WRITE, { peer: bPeer, data: b64('after-retag') })
  const d = await got
  assert.ok(d, 'data from B reached A on the new topic')
  assert.equal(Buffer.from(d.p.data, 'base64').toString(), 'after-retag')
})

const liveTo = (w, key) => [...w.swarm.connections].filter((c) => !c.destroyed && c.remotePublicKey.equals(key)).length

// DUP-1: after an earlier connection is closed, both sides join the next topic at the same moment,
// so both dial and Hyperswarm resolves the duplicate. Each side must end with ONE live connection
// to the other, and it must carry data both ways.
test('a simultaneous redial after a close leaves one live connection with data both ways', async (t) => {
  const { a, b, aSeesB } = await connectedPair(t)
  const aKey = a.swarm.keyPair.publicKey
  const bKey = b.swarm.keyPair.publicKey
  await a.call(Method.CONNECTION_DESTROY, { peer: aSeesB })
  await a.call(Method.SWARM_LEAVE, { topic: TOPIC })
  await b.call(Method.SWARM_LEAVE, { topic: TOPIC })
  await settle(500)
  const failures = []
  const dialCounts = []
  const dials = (w) => w.swarm.stats.connects.client.attempted
  for (let n = 0; n < 10; n++) {
    const topic = topicOf(0xc0 + n)
    const isConnT = (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topic
    const aConn = a.onEvent(isConnT, 20000).catch(() => null)
    const bConn = b.onEvent(isConnT, 20000).catch(() => null)
    await Promise.all([
      a.call(Method.SWARM_JOIN, { topic, acceptUnannounced: true }),
      b.call(Method.SWARM_JOIN, { topic, acceptUnannounced: true })
    ])
    await Promise.all([a.swarm.flush(), b.swarm.flush()])
    // Both are announced now; both lookups run at the same moment, so each finds the other and
    // both dial at once (simultaneous joins alone never find each other on this local testnet).
    const dialsBefore = dials(a) + dials(b)
    await Promise.all([a, b].map((w) => w.swarm.status(Buffer.from(topic, 'hex')).refresh()))
    const [ac, bc] = await Promise.all([aConn, bConn])
    dialCounts.push(dials(a) + dials(b) - dialsBefore)
    let ok = !!(ac && bc)
    if (ok) {
      await settle(300) // let a duplicate, if any, be resolved before counting
      const toB = b.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === topic, 10000).catch(() => null)
      const toA = a.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === topic, 10000).catch(() => null)
      await a.call(Method.CONNECTION_WRITE, { peer: ac.p.peer, data: b64('a' + n) })
      await b.call(Method.CONNECTION_WRITE, { peer: bc.p.peer, data: b64('b' + n) })
      const [gotB, gotA] = await Promise.all([toB, toA])
      ok = !!gotB && !!gotA && liveTo(a, bKey) === 1 && liveTo(b, aKey) === 1
      if (!ok) failures.push({ n, gotB: !!gotB, gotA: !!gotA, aLive: liveTo(a, bKey), bLive: liveTo(b, aKey) })
      await a.call(Method.CONNECTION_DESTROY, { peer: ac.p.peer })
    } else {
      const view = (w) => [...w.swarm.connections].map((c) => {
        const info = w.swarm.peers.get(c.remotePublicKey.toString('hex'))
        return { client: c.isInitiator, destroyed: c.destroyed, read: c.rawBytesRead, topics: info ? info.topics.map((x) => x.toString('hex').slice(0, 2)) : null }
      })
      failures.push({ n, aConnected: !!ac, bConnected: !!bc, a: view(a), b: view(b), aDialing: a.swarm.connecting, bDialing: b.swarm.connecting })
    }
    await a.call(Method.SWARM_LEAVE, { topic })
    await b.call(Method.SWARM_LEAVE, { topic })
    await settle(500)
  }
  t.diagnostic('dials per round: ' + JSON.stringify(dialCounts))
  t.diagnostic('failed rounds: ' + failures.length + '/10 ' + JSON.stringify(failures))
  assert.deepEqual(failures, [])
})

// The device form of G16: a surfaced connection whose other half is gone without a reset reaching
// this side (a duplicate the peer destroyed, its reset lost on the way). Simulated by B's DHT
// server swallowing A's next dial: B keeps the stream open but silent (no keepalive, never read),
// so A's connection opens and is reported, yet nothing ever comes back on it. A must close it and
// make a new connection that carries data, instead of holding it until UDX gives up.
test('a connection whose peer never speaks is closed and replaced', async (t) => {
  // A gets the greater key: then A's Hyperswarm keeps its silent connection over B's later dial
  // (its tie-break), as on the devices, instead of replacing it.
  const pairs = [hypercoreCrypto.keyPair(), hypercoreCrypto.keyPair()]
  pairs.sort((x, y) => Buffer.compare(y.publicKey, x.publicKey))
  nextKeyPairs.push(...pairs)
  const { a, b, aSeesB } = await connectedPair(t)
  assert.ok(Buffer.compare(a.swarm.keyPair.publicKey, b.swarm.keyPair.publicKey) > 0)
  await a.call(Method.CONNECTION_DESTROY, { peer: aSeesB })
  await a.call(Method.SWARM_LEAVE, { topic: TOPIC })
  await b.call(Method.SWARM_LEAVE, { topic: TOPIC })
  await settle(500)
  // Hyperswarm may have redialed before the leave; with no topic joined it no longer does, so end
  // any such connection and start from none.
  const aKey = a.swarm.keyPair.publicKey
  const bKey = b.swarm.keyPair.publicKey
  for (const c of [...a.swarm.connections]) c.destroy()
  for (let i = 0; liveTo(a, bKey) + liveTo(b, aKey) > 0; i++) {
    assert.ok(i < 100, 'leftover connections closed')
    await settle(50)
  }

  const swallowed = []
  const [handle] = b.swarm.server.listeners('connection')
  b.swarm.server.removeAllListeners('connection')
  b.swarm.server.on('connection', (conn) => {
    if (swallowed.length > 0) return handle(conn)
    conn.setKeepAlive(0)
    conn.on('error', () => {})
    swallowed.push(conn)
  })
  t.after(() => { for (const c of swallowed) c.destroy() })

  const topic = topicOf(0xd0)
  const isConnT = (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topic
  const first = a.onEvent(isConnT, 20000)
  await b.call(Method.SWARM_JOIN, { topic, acceptUnannounced: true })
  await b.swarm.flush()
  await settle(200)
  await a.call(Method.SWARM_JOIN, { topic, server: false }) // A only dials, so its dial is the one B swallows
  await a.swarm.flush()
  const dead = await first
  // A's side opens before B's DHT server sees the first packet of the stream.
  for (let i = 0; swallowed.length === 0; i++) {
    assert.ok(i < 100, 'B swallowed A\'s dial')
    await settle(50)
  }

  const closed = a.onEvent((m) => m.ev === EventName.CONNECTION_CLOSE && m.p.topic === topic && m.p.peer === dead.p.peer, 20000)
  const again = closed.then(() => a.onEvent(isConnT, 30000))
  const c = await closed
  assert.equal(c.p.stats.error, 'PEER_SILENT')
  const next = await again
  const toB = b.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === topic, 10000)
  await a.call(Method.CONNECTION_WRITE, { peer: next.p.peer, data: b64('after-silent') })
  assert.equal(Buffer.from((await toB).p.data, 'base64').toString(), 'after-silent')
})

// Joins `topic` without announcing it, so no lookup can find this side: only acceptUnannounced
// tagging can attach a connection to it.
const joinUnannounced = (w, topic) => w.call(Method.SWARM_JOIN, { topic, acceptUnannounced: true, server: false })
const dataBothWays = async (a, b, topic, aPeer, bPeer) => {
  const toB = b.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === topic, 5000).catch(() => null)
  const toA = a.onEvent((m) => m.ev === EventName.CONNECTION_DATA && m.p.topic === topic, 5000).catch(() => null)
  await a.call(Method.CONNECTION_WRITE, { peer: aPeer, data: b64('to-b') })
  await b.call(Method.CONNECTION_WRITE, { peer: bPeer, data: b64('to-a') })
  const [gotB, gotA] = await Promise.all([toB, toA])
  return !!gotB && !!gotA
}

// The dialer's side of a leftover connection: B dialed A on TOPIC, both left TOPIC and the
// connection stayed open. Joining the next topic must attach it on B (outbound) as on A (inbound).
test('joining an acceptUnannounced topic tags an open outbound connection that has no joined topic', async (t) => {
  const { a, b } = await connectedPair(t) // A joined first, so B dialed
  await a.call(Method.SWARM_LEAVE, { topic: TOPIC })
  await b.call(Method.SWARM_LEAVE, { topic: TOPIC })
  await settle(300)
  assert.equal(liveTo(b, a.swarm.keyPair.publicKey), 1, 'the connection outlived the topic')
  assert.ok([...b.swarm.connections][0].isInitiator, 'B dialed it')
  const t1 = topicOf(0xe0)
  const isConnT = (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === t1
  const aConn = a.onEvent(isConnT, 5000).catch(() => null)
  const bConn = b.onEvent(isConnT, 5000).catch(() => null)
  await joinUnannounced(a, t1)
  await joinUnannounced(b, t1)
  const [ac, bc] = await Promise.all([aConn, bConn])
  assert.ok(ac, 'A (inbound) reported it')
  assert.ok(bc, 'B (outbound) reported it')
  assert.ok(await dataBothWays(a, b, t1, ac.p.peer, bc.p.peer), 'it carries data both ways')
})

// Hyperswarm's retry timer redials a peer about 1 s after a connection closes and does not check
// again whether the topic is still joined, so the redial can land after both sides left the topic
// and joined the next one. Such an outbound connection must be tagged as it lands.
test('a redial that lands after the next join is tagged on both sides', async (t) => {
  const { a, b, aSeesB } = await connectedPair(t) // A joined first, so B dialed and B redials
  let bRedialAt = 0
  b.swarm.on('connection', (c, info) => { if (info.client) bRedialAt = Date.now() })
  await a.call(Method.CONNECTION_DESTROY, { peer: aSeesB })
  await a.call(Method.SWARM_LEAVE, { topic: TOPIC })
  await b.call(Method.SWARM_LEAVE, { topic: TOPIC })
  const t1 = topicOf(0xe1)
  const isConnT = (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === t1
  const aConn = a.onEvent(isConnT, 20000).catch(() => null)
  const bConn = b.onEvent(isConnT, 20000).catch(() => null)
  await joinUnannounced(a, t1)
  await joinUnannounced(b, t1)
  const joinedAt = Date.now()
  const [ac, bc] = await Promise.all([aConn, bConn])
  assert.ok(bRedialAt > joinedAt, 'the redial landed after the join (else this test proves nothing)')
  assert.ok(ac, 'A (inbound) reported it')
  assert.ok(bc, 'B (outbound) reported it')
  assert.ok(await dataBothWays(a, b, t1, ac.p.peer, bc.p.peer), 'it carries data both ways')
})

// The swarm also carries connections for topics Dart never joined (blind-pairing joins its own on
// the same Hyperswarm). Such a connection is not a leftover and must not become a Dart topic's peer.
test('a connection on a topic joined by something else on the swarm is not re-tagged', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())
  const a = bootWorklet()
  const b = bootWorklet()
  const other = Buffer.from(topicOf(0xf0), 'hex') // joined straight on Hyperswarm, as blind-pairing does
  await a.swarm.join(other, { server: true, client: true }).flushed()
  await b.swarm.join(other, { server: true, client: true }).flushed()
  for (let i = 0; liveTo(a, b.swarm.keyPair.publicKey) === 0 || liveTo(b, a.swarm.keyPair.publicKey) === 0; i++) {
    assert.ok(i < 200, 'connected on the other topic')
    await settle(50)
  }
  // One more lookup each, so both sides' peer records carry the other topic (the first joiner's
  // lookup ran before the second announced).
  await a.swarm.join(other, { server: true, client: true }).flushed()
  await b.swarm.join(other, { server: true, client: true }).flushed()
  const carries = (w, peer) => w.swarm.peers.get(peer.swarm.keyPair.publicKey.toString('hex')).topics.some((x) => x.equals(other))
  assert.ok(carries(a, b) && carries(b, a), 'both peer records carry the other topic')
  const t1 = topicOf(0xf1)
  const isConnT = (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === t1
  const aConn = a.onEvent(isConnT, 3000).catch(() => null)
  const bConn = b.onEvent(isConnT, 3000).catch(() => null)
  await joinUnannounced(a, t1)
  await joinUnannounced(b, t1)
  const [ac, bc] = await Promise.all([aConn, bConn])
  assert.equal(ac, null, 'A did not report it on the Dart topic')
  assert.equal(bc, null, 'B did not report it on the Dart topic')
})

// Hyperswarm keeps one PeerInfo per peer across its connections. A closed connection's topic
// listener left on it fires first for the next one, marks the peer connected and releases the OLD
// connection's held data, and the live connection's own listener then returns early, so its held
// messages are never delivered.
test('a closed connection leaves no topic listener on the peer record', async (t) => {
  const { a, b } = await connectedPair(t) // B dialed: its record of A is kept and reused for redials
  const aKey = a.swarm.keyPair.publicKey
  const record = () => b.swarm.peers.get(aKey.toString('hex'))
  const first = record().listenerCount('topic')
  for (let n = 0; n < 2; n++) { // two: Hyperswarm's redial backoff reaches 15 s on the third
    const before = record()
    for (const c of [...a.swarm.connections]) c.destroy()
    for (let i = 0; i === 0 || liveTo(b, aKey) === 0; i++) {
      assert.ok(i < 300, 'Hyperswarm redialed')
      await settle(50)
    }
    assert.equal(record(), before, 'the same peer record was reused')
  }
  assert.equal(record().listenerCount('topic'), first)
})
