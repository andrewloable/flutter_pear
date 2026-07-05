// flutter_pear-doi hardware finding -- a real Dart hot restart destroys the
// Dart isolate (and the PearSwarm object with it) while this worklet, and
// its already-connected peers, survive untouched (E6.3's reattach
// guarantee). Before this fix, a fresh PearSwarm's Method.SWARM_JOIN for a
// topic pear-end already considers joined was a silent no-op ack: the
// one-time swarm.on('connection', ...) handler that emits
// SWARM_CONNECTION/sendState(CONNECTED) already fired for the OLD, now-gone
// session and never fires again for a connection that's already
// established, so the new PearSwarm sat on its optimistic default
// `discovering` state until PearSwarmDefaults.joinTimeout gave up on a
// connection that was never actually lost. Found on a REAL Android
// emulator running a real hot restart against a real desktop peer (see
// flutter_pear-doi's closing notes); this test reproduces the same root
// cause -- a second Method.SWARM_JOIN call for an already-connected topic --
// against two REAL worklets on a real (local, offline) DHT testnet, not a
// stub, so a regression in the real swarm.on('connection', ...) wiring this
// fix touches would be caught here too.
//
// RUNBOOK -- from packages/flutter_pear/pear-end/:
//   npm test                                    (whole pear-end suite)
//   node --test test/rejoin-replay.test.js      (this file only)
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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-rejoin-test-'))
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

test('SWARM_JOIN replay: rejoining an already-connected topic re-emits SWARM_CONNECTION + CONNECTED (flutter_pear-doi hot-restart finding)', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())

  const a = bootWorklet()
  const b = bootWorklet()
  const topicHex = 'bb'.repeat(32)

  const aConnected = a.onEvent((msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topicHex)

  await joinWorkletAndWait(a, topicHex)
  await joinWorkletAndWait(b, topicHex)
  await forceTopicTag(a, topicHex)

  const firstConnection = await aConnected
  const peerHex = firstConnection.p.peer
  assert.equal(typeof peerHex, 'string')
  assert.equal(peerHex.length, 64, 'a real 32-byte hex public key')

  // Simulate a Dart hot restart on A's side: the Dart isolate (and its
  // PearSwarm) is gone, but this worklet process -- and its live connection
  // to B -- never stopped. A fresh PearSwarm calls SWARM_JOIN again for the
  // SAME topic.
  const replayedConnection = a.onEvent((msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topicHex)
  const replayedState = a.onEvent((msg) =>
    msg.ev === EventName.SWARM_LIFECYCLE && msg.p.topic === topicHex && msg.p.state === SwarmState.CONNECTED)

  const rejoinRes = await a.call(Method.SWARM_JOIN, { topic: topicHex })
  assert.equal(rejoinRes.ok.joined, topicHex)

  const replayed = await replayedConnection
  assert.equal(replayed.p.peer, peerHex, 'replay reports the SAME already-connected peer, not a fabricated one')
  await replayedState // rejects (failing the test) if CONNECTED is never (re-)sent
})

test('SWARM_JOIN replay: rejoining a never-connected topic still gets a fresh DISCOVERING, not silence', async (t) => {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy())

  const a = bootWorklet()
  const topicHex = 'cc'.repeat(32)

  await a.call(Method.SWARM_JOIN, { topic: topicHex })

  const secondDiscovering = a.onEvent((msg) =>
    msg.ev === EventName.SWARM_LIFECYCLE && msg.p.topic === topicHex && msg.p.state === SwarmState.DISCOVERING)
  await a.call(Method.SWARM_JOIN, { topic: topicHex })
  await secondDiscovering // rejects (failing the test) if no replay is sent for the still-unconnected case
})
