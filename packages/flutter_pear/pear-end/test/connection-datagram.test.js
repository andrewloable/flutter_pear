// Datagrams (flutter_pear 0.4.12): Method.CONNECTION_SEND sends one unreliable, unordered,
// encrypted datagram with conn.trySend; Hyperswarm's 'message' event comes back as
// EventName.CONNECTION_MESSAGE. Real worklets on a local DHT testnet, never the public DHT.
//
// A datagram sent in the first moments of a connection can be lost (nothing retries it), so
// every test waits for the connection to settle before it sends, and sends exactly once.
//
// RUNBOOK -- from packages/flutter_pear/pear-end/:
//   node --test test/connection-datagram.test.js
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
const { Method, FrameType, EventName, ErrorCode } = require('../schema')

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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-datagram-test-'))
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

  // Every event frame this worklet sends, in order.
  const events = []
  writeListeners.add((buf) => {
    if (buf.length < 5 || buf[4] !== FrameType.JSON) return
    try {
      const msg = JSON.parse(buf.subarray(5, 4 + buf.readUInt32BE(0)).toString())
      if (msg.ev) events.push(msg)
    } catch {}
  })

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

  return { call, onEvent, swarm, events }
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
const MAX_DATAGRAM = 1108
const SETTLE_MS = 1500

const settle = (ms = SETTLE_MS) => new Promise((resolve) => setTimeout(resolve, ms))
const b64 = (text) => Buffer.from(text).toString('base64')
const isMessage = (msg) => msg.ev === EventName.CONNECTION_MESSAGE && msg.p.topic === TOPIC
const isData = (msg) => msg.ev === EventName.CONNECTION_DATA && msg.p.topic === TOPIC
const kinds = (worklet, matcher) => worklet.events.filter(matcher)

// Two worklets connected on TOPIC (the staggered join the other suites use), settled.
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
  await settle()
  return { a, b, aSeesB: ac.p.peer, bSeesA: bc.p.peer }
}

test('send delivers a datagram', async (t) => {
  const { a, b, aSeesB, bSeesA } = await connectedPair(t)
  const arrived = b.onEvent(isMessage, 8000)

  const res = await a.call(Method.CONNECTION_SEND, { peer: aSeesB, data: 'aGVsbG8=' })
  assert.equal(res.err, undefined)
  assert.equal(res.ok, null)

  const msg = await arrived
  assert.equal(msg.p.topic, TOPIC)
  assert.equal(msg.p.peer, bSeesA)
  assert.equal(msg.p.data, 'aGVsbG8=')
})

test('the two paths stay separate', async (t) => {
  const { a, b, aSeesB } = await connectedPair(t)

  assert.equal((await a.call(Method.CONNECTION_SEND, { peer: aSeesB, data: b64('dgram') })).err, undefined)
  assert.equal((await a.call(Method.CONNECTION_WRITE, { peer: aSeesB, data: b64('stream') })).err, undefined)
  await settle()

  const messages = kinds(b, isMessage)
  const data = kinds(b, isData)
  assert.equal(messages.length, 1, 'exactly one connection.message')
  assert.equal(data.length, 1, 'exactly one connection.data')
  assert.equal(messages[0].p.data, b64('dgram'))
  assert.equal(data[0].p.data, b64('stream'))
})

test('unknown peer', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())
  const a = bootWorklet()

  const res = await a.call(Method.CONNECTION_SEND, { peer: 'ab'.repeat(32), data: 'aGVsbG8=' })
  assert.equal(res.err && res.err.code, ErrorCode.UNKNOWN_PEER)
})

test('size limit, outbound', async (t) => {
  const { a, b, aSeesB } = await connectedPair(t)
  const exact = Buffer.alloc(MAX_DATAGRAM, 7)
  const arrived = b.onEvent(isMessage, 8000)

  const ok = await a.call(Method.CONNECTION_SEND, { peer: aSeesB, data: exact.toString('base64') })
  assert.equal(ok.err, undefined)
  const msg = await arrived
  assert.equal(Buffer.from(msg.p.data, 'base64').equals(exact), true, '1108 bytes arrive intact')

  const before = kinds(b, isMessage).length
  const tooBig = await a.call(Method.CONNECTION_SEND, { peer: aSeesB, data: Buffer.alloc(MAX_DATAGRAM + 1, 7).toString('base64') })
  assert.equal(tooBig.err && tooBig.err.code, ErrorCode.DATAGRAM_TOO_LARGE)
  assert.equal(JSON.stringify(tooBig).includes('BwcH'), false, 'the error never carries the payload')
  await settle(500)
  assert.equal(kinds(b, isMessage).length, before, 'nothing was sent for 1109 bytes')
})

test('size limit, inbound', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())

  const w = bootWorklet()
  // A plain Hyperswarm peer, not a worklet: it can send a datagram of any size.
  const p = new Hyperswarm({ bootstrap: testnet.bootstrap })
  t.after(() => p.destroy().catch(() => {}))
  const pKey = p.keyPair.publicKey.toString('hex')
  const pConn = new Promise((resolve) => p.once('connection', resolve))
  const wSeesP = w.onEvent((msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === TOPIC && msg.p.peer === pKey, 20000)

  await joinWorkletAndWait(w, TOPIC)
  p.join(Buffer.from(TOPIC, 'hex'), { server: true, client: true })
  await p.flush()
  await new Promise((resolve) => setTimeout(resolve, 200))
  await forceTopicTag(w, TOPIC)
  const conn = await pConn
  conn.on('error', () => {})
  await wSeesP // a datagram that beats the topic tag is dropped by design
  await settle()

  conn.trySend(Buffer.alloc(MAX_DATAGRAM + 1, 1))
  conn.trySend(Buffer.from('small'))
  await settle()

  const messages = kinds(w, isMessage)
  assert.equal(messages.length, 1, 'only the small datagram is delivered')
  assert.equal(messages[0].p.data, 'c21hbGw=')
  assert.equal(messages[0].p.peer, pKey)
  assert.equal(kinds(w, (m) => m.ev === EventName.CONNECTION_CLOSE).length, 0, 'the connection stays open')
  assert.equal(w.swarm.connections.size, 1)
})
