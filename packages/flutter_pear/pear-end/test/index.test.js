// JS-level tests for pear-end's dynamic RPC dispatch (index.js's IPC.on
// ('data', ...) -> handle() pipeline) -- runs the REAL module against a
// stubbed IPC/Bare/BareKit boundary and a stubbed Hyperswarm.join/leave, so
// SWARM_JOIN/SWARM_LEAVE and the E5.2 storage handlers can be exercised
// without bare-pack, a device, or a real network (flutter_pear-pcg).
//
// Node's test runner runs top-level tests in one file sequentially (verified
// empirically -- see flutter_pear-pcg's closing notes), which this file
// relies on: every test mutates the shared `global.Bare`/`global.BareKit`
// boundary and index.js's own require-cache entry, so two tests running
// concurrently would corrupt each other's worklet instance.
//
// Run directly with Node's built-in test runner from the pear-end/
// directory: `node --test` (see autobase-recipes.test.js's header for why a
// directory path argument doesn't work on this Node version).
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
const Corestore = require('corestore')
const { Method, FrameType } = require('../schema')

const INDEX_PATH = require.resolve('../index.js')

// Every Hyperswarm index.js constructs (one per bootWorklet() call) is
// tracked here so test.after() can destroy them all -- discovered
// empirically that skipping this hangs `node --test` forever after the last
// test finishes (an undestroyed Hyperswarm keeps its DHT UDP socket bound,
// which keeps the event loop -- and therefore the whole process -- alive).
// Installed by swapping the cached 'hyperswarm' export for a tracking
// subclass BEFORE index.js ever requires it; join/leave stubs below still
// apply via the prototype chain since TrackedHyperswarm doesn't override them.
const swarmInstances = []
class TrackedHyperswarm extends Hyperswarm {
  constructor (...args) {
    super(...args)
    swarmInstances.push(this)
  }
}
require.cache[require.resolve('hyperswarm')].exports = TrackedHyperswarm

test.after(() => Promise.all(swarmInstances.map((s) => s.destroy().catch(() => {}))))

// index.js requires 'bare-fs'/'bare-path' directly (the file-path bulk seam,
// E4.4 LOCKED) -- both packages are Bare-runtime-only: their binding.js calls
// the Bare-native `require.addon()`, which doesn't exist under plain Node
// (confirmed empirically -- attempting to require either under `node --test`
// throws `require.addon is not a function` deep in bare-os). Real Corestore/
// Hyperbee/etc. don't hit this (proved by autobase-recipes.test.js already
// passing under plain Node), so the fix is scoped to just these two direct
// requires: pre-seed Node's require cache with Node-native equivalents
// (fs + fs/promises cover the four fs.* calls index.js makes; path.join is
// identical between bare-path and Node's path) so index.js's own
// require('bare-fs')/require('bare-path') resolve to these instead of ever
// loading the real Bare-only modules.
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

// Every tmpDir() this file creates is tracked here and removed by the
// top-level after() hook below, regardless of which tests passed or failed
// -- same convention as autobase-recipes.test.js.
const tmpDirs = []
function tmpDir () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-index-test-'))
  tmpDirs.push(dir)
  return dir
}
test.after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

// Boots a fresh instance of index.js's module-level state (a new `swarm`,
// `store`, `cores`/`bees` registries, ...) against a stubbed IPC pipe and a
// stubbed Bare/BareKit global boundary. Requests are sent through the EXACT
// wire format bare_worklet.dart's real IPC uses (4-byte big-endian length
// prefix + FrameType byte + JSON body) so this exercises the real
// framing/dispatch path, not a shortcut direct call into handle().
//
// ponytail: the previous boot's `store`/BlindPairing instances (unlike
// `swarm` above) are never explicitly closed -- index.js doesn't export them,
// and unlike Hyperswarm their Corestore-backed storage doesn't keep the
// event loop alive, so this is an accepted per-process resource trickle for
// the life of this test file, not something that blocks the process exiting.
function bootWorklet ({ argv = [tmpDir()] } = {}) {
  const ipc = new EventEmitter()
  const writeListeners = new Set()
  ipc.write = (buf) => { for (const listener of writeListeners) listener(buf) }

  global.BareKit = { IPC: ipc }
  global.Bare = {
    argv,
    on: () => {},
    exit: (code) => { throw new Error('Bare.exit(' + code + ') called during test') }
  }

  delete require.cache[INDEX_PATH]
  require(INDEX_PATH)

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

  return { call }
}

test('SWARM_JOIN/SWARM_LEAVE: dynamic join/leave against a stubbed Hyperswarm', async (t) => {
  const joinCalls = []
  const leaveCalls = []
  const originalJoin = Hyperswarm.prototype.join
  const originalLeave = Hyperswarm.prototype.leave
  Hyperswarm.prototype.join = function (topic) {
    joinCalls.push(topic)
    return { flushed: async () => {} }
  }
  Hyperswarm.prototype.leave = async function (topic) {
    leaveCalls.push(topic)
  }
  t.after(() => {
    Hyperswarm.prototype.join = originalJoin
    Hyperswarm.prototype.leave = originalLeave
  })

  const worklet = bootWorklet()
  const topicHex = 'aa'.repeat(32)

  const joinRes = await worklet.call(Method.SWARM_JOIN, { topic: topicHex })
  assert.equal(joinRes.ok.joined, topicHex)
  assert.equal(joinCalls.length, 1, 'swarm.join called once for a new topic')
  assert.equal(joinCalls[0].toString('hex'), topicHex, 'joined with the exact topic buffer')

  // Idempotent re-join (E4.4 LOCKED): joining the SAME topic again is a
  // no-op ack, not a second swarm.join() call.
  const rejoinRes = await worklet.call(Method.SWARM_JOIN, { topic: topicHex })
  assert.equal(rejoinRes.ok.joined, topicHex)
  assert.equal(joinCalls.length, 1, 're-joining an already-joined topic must not call swarm.join() again')

  const leaveRes = await worklet.call(Method.SWARM_LEAVE, { topic: topicHex })
  assert.equal(leaveRes.ok.left, topicHex)
  assert.equal(leaveCalls.length, 1, 'swarm.leave called once')
  assert.equal(leaveCalls[0].toString('hex'), topicHex, 'left with the exact topic buffer')

  // Leaving an already-left topic is a no-op ack, not a second swarm.leave().
  const releaveRes = await worklet.call(Method.SWARM_LEAVE, { topic: topicHex })
  assert.equal(releaveRes.ok.left, topicHex)
  assert.equal(leaveCalls.length, 1, 're-leaving an already-left topic must not call swarm.leave() again')

  // Leave-then-rejoin: a topic left and then joined again is a genuinely new
  // membership, so it must call swarm.join() again, not stay a no-op.
  const rejoinAfterLeave = await worklet.call(Method.SWARM_JOIN, { topic: topicHex })
  assert.equal(rejoinAfterLeave.ok.joined, topicHex)
  assert.equal(joinCalls.length, 2, 'joining again after leaving calls swarm.join() a second time')
})

test('Bare.argv[0] missing: index.js throws a clear, named error instead of a generic TypeError (flutter_pear-pcg)', () => {
  global.BareKit = { IPC: new EventEmitter() }
  global.Bare = { argv: [], on: () => {}, exit: () => {} }
  delete require.cache[INDEX_PATH]

  assert.throws(
    () => require(INDEX_PATH),
    (err) => /Bare\.argv\[0\]/.test(err.message) && /storage directory/.test(err.message),
    'must throw a clear, named error naming Bare.argv[0], not a bare path.join TypeError'
  )
})

test('STORE_GET/BEE_OPEN: a redundant reopen of an already-open name closes the fresh session instead of leaking it (flutter_pear-0md)', async (t) => {
  const sessions = []
  const originalGet = Corestore.prototype.get
  Corestore.prototype.get = function (...args) {
    const core = originalGet.apply(this, args)
    sessions.push(core)
    return core
  }
  t.after(() => { Corestore.prototype.get = originalGet })

  const worklet = bootWorklet()

  const first = await worklet.call(Method.STORE_GET, { name: 'same-core-name' })
  const second = await worklet.call(Method.STORE_GET, { name: 'same-core-name' })
  assert.equal(second.ok.key, first.ok.key, 'both opens resolve to the same underlying core')

  // store.get() always returns a FRESH session per call regardless of
  // whether the key is already tracked -- confirm two separate sessions
  // were actually fetched, so this test can't pass without exercising the
  // fix (as opposed to store.get() itself happening to return the same
  // object, which would make the assertions below vacuous).
  assert.equal(sessions.length, 2)
  assert.notEqual(sessions[0], sessions[1])
  assert.equal(sessions[0].closed, false, 'the registered session stays open')
  assert.equal(sessions[1].closed, true, 'the redundant reopen\'s fresh session must be closed, not leaked')

  const beeFirst = await worklet.call(Method.BEE_OPEN, { name: 'same-bee-name' })
  const beeSecond = await worklet.call(Method.BEE_OPEN, { name: 'same-bee-name' })
  assert.equal(beeSecond.ok.key, beeFirst.ok.key, 'both bee opens resolve to the same underlying bee')
  assert.equal(sessions.length, 4, 'bee.open also fetches one core session per call')
  assert.equal(sessions[2].closed, false, 'the session wrapped into the registered Hyperbee stays open')
  assert.equal(sessions[3].closed, true, 'bee.open\'s redundant reopen must close its fresh session too')
})
