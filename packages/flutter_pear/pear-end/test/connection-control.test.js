// Connection control (flutter_pear 0.4.11): Method.CONNECTION_DESTROY ends one connection
// through the normal close path; Method.PEER_REFUSE closes it and keeps Hyperswarm from
// dialing or accepting the peer until accepted again. Two real worklets on a local DHT
// testnet, never the public DHT.
//
// RUNBOOK -- from packages/flutter_pear/pear-end/:
//   node --test test/connection-control.test.js
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
const { Method, FrameType, EventName, SwarmState } = require('../schema')

const INDEX_PATH = require.resolve('../index.js')

// Same testnet-swap technique as noise-confidentiality.test.js's own
// TestnetHyperswarm -- see that file's header for the full rationale (never
// hit the real public DHT from a test).
let currentBootstrap = null
const swarmInstances = []
class TestnetHyperswarm extends Hyperswarm {
  constructor (opts = {}) {
    super({ ...opts, bootstrap: currentBootstrap })
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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-conn-control-test-'))
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

test('connection.destroy closes the connection on both sides', async (t) => {
  const { a, b, aSeesB, bSeesA } = await connectedPair(t)
  const aClosed = a.onEvent(isClose(aSeesB))
  const bClosed = b.onEvent(isClose(bSeesA))

  const res = await a.call(Method.CONNECTION_DESTROY, { peer: aSeesB })
  assert.equal(res.err, undefined)
  assert.equal(res.ok, null)
  await aClosed
  await bClosed
})

test('connection.destroy for an unknown peer is a no-op', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())
  const a = bootWorklet()
  const events = []
  const watch = a.onEvent((msg) => { events.push(msg); return false }, 500).catch(() => {})

  const res = await a.call(Method.CONNECTION_DESTROY, { peer: 'ab'.repeat(32) })
  assert.equal(res.err, undefined)
  assert.equal(res.ok, null)
  await watch
  assert.deepEqual(events.filter((e) => e.ev === EventName.CONNECTION_CLOSE), [])
})

test('a refused peer is disconnected and does not come back', async (t) => {
  const { a, b, aSeesB, bSeesA } = await connectedPair(t)
  const aClosed = a.onEvent(isClose(aSeesB))
  const bClosed = b.onEvent(isClose(bSeesA))

  const res = await a.call(Method.PEER_REFUSE, { peer: aSeesB, refused: true })
  assert.equal(res.err, undefined)
  assert.equal(res.ok, null)
  await aClosed
  await bClosed

  // B keeps dialing; A must neither accept nor dial.
  const reconnected = []
  a.onEvent((msg) => { if (isConnection(aSeesB)(msg)) reconnected.push(msg); return false }, 6000).catch(() => {})
  await a.swarm.flush()
  await b.swarm.flush()
  await a.call(Method.SWARM_JOIN, { topic: TOPIC })
  await forceTopicTag(a, TOPIC)
  await forceTopicTag(b, TOPIC)
  await settle(5000)
  assert.deepEqual(reconnected, [], 'no swarm.connection for the refused peer')
  assert.equal(a.swarm.connections.size, 0, "A's swarm holds no connection")
})

test('accepting a refused peer lets it reconnect', async (t) => {
  const { a, b, aSeesB } = await connectedPair(t)
  await a.call(Method.PEER_REFUSE, { peer: aSeesB, refused: true })
  await settle(1500)

  const back = a.onEvent(isConnection(aSeesB), 20000)
  const res = await a.call(Method.PEER_REFUSE, { peer: aSeesB, refused: false })
  assert.equal(res.err, undefined)
  await a.swarm.flush()
  await b.swarm.flush()
  await forceTopicTag(a, TOPIC)
  await forceTopicTag(b, TOPIC)
  await back
})

// Hyperswarm's own ban only covers a peer it already has a record for. A peer refused
// BEFORE it ever connected reaches A only through the firewall option, with B as the dialer.
test('a peer refused in advance cannot connect (the firewall path)', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())
  const a = bootWorklet()
  const b = bootWorklet()
  const bKey = (await b.call(Method.SWARM_PUBLIC_KEY)).ok.publicKey

  assert.equal((await a.call(Method.PEER_REFUSE, { peer: bKey, refused: true })).err, undefined)
  const seen = []
  a.onEvent((msg) => { if (msg.ev === EventName.SWARM_CONNECTION) seen.push(msg); return false }, 8000).catch(() => {})
  await joinWorkletAndWait(a, TOPIC)
  await joinWorkletAndWait(b, TOPIC) // B finds A and dials in
  await forceTopicTag(b, TOPIC)
  await settle(5000)

  assert.deepEqual(seen, [], 'no swarm.connection on A')
  assert.equal(a.swarm.connections.size, 0, "A's swarm holds no connection")
})
