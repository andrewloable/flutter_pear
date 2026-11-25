// Drive transfers with no fixed deadline (KinNode gap G15): DRIVE_GET/DRIVE_PUT fail only when
// no bytes move for idleMs (TRANSFER_STALLED), and report DRIVE_PROGRESS for a `transfer` id.
// Helpers copied from connection-control.test.js.
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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-drive-transfer-test-'))
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

  // Every event this worklet sends, in order (for the progress assertions).
  const events = []
  writeListeners.add((buf) => {
    if (buf.length < 5 || buf[4] !== FrameType.JSON) return
    const len = buf.readUInt32BE(0)
    let msg
    try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
    if (msg.ev) events.push(msg)
  })

  return { call, onEvent, swarm, events }
}


const { execFileSync } = require('node:child_process')
const crypto = require('node:crypto')

const sha = (file) => crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex')
function localFile (bytes) {
  const file = path.join(tmpDir(), 'src.bin')
  fs.writeFileSync(file, crypto.randomBytes(bytes))
  return file
}
async function openDrive (w) {
  const res = await w.call(Method.DRIVE_OPEN, { name: 'transfer-test' })
  assert.equal(res.err, undefined)
  return res.ok.key
}
const progressOf = (w, transfer) => w.events.filter((e) => e.ev === EventName.DRIVE_PROGRESS && e.p.transfer === transfer).map((e) => e.p)

test('put reports progress for its transfer id, ending at bytes == total', async () => {
  const w = bootWorklet()
  const drive = await openDrive(w)
  const src = localFile(1048576)
  const res = await w.call(Method.DRIVE_PUT, { drive, path: '/one.bin', localSourcePath: src, transfer: 'put-1' })
  assert.equal(res.err, undefined)
  const p = progressOf(w, 'put-1')
  assert.ok(p.length >= 1, 'at least one progress event')
  assert.deepEqual(p[p.length - 1], { transfer: 'put-1', bytes: 1048576, total: 1048576 })
})

test('get reports progress ending at bytes == total, and the file is intact', async () => {
  const w = bootWorklet()
  const drive = await openDrive(w)
  const src = localFile(4194304)
  assert.equal((await w.call(Method.DRIVE_PUT, { drive, path: '/four.bin', localSourcePath: src })).err, undefined)
  const dst = path.join(tmpDir(), 'dst.bin')
  const res = await w.call(Method.DRIVE_GET, { drive, path: '/four.bin', destinationPath: dst, transfer: 'get-1' })
  assert.equal(res.err, undefined)
  const p = progressOf(w, 'get-1')
  assert.ok(p.length >= 1)
  assert.deepEqual(p[p.length - 1], { transfer: 'get-1', bytes: 4194304, total: 4194304 })
  assert.equal(sha(dst), sha(src))
})

test('without a transfer id, no progress events are sent', async () => {
  const w = bootWorklet()
  const drive = await openDrive(w)
  const src = localFile(65536)
  assert.equal((await w.call(Method.DRIVE_PUT, { drive, path: '/quiet.bin', localSourcePath: src })).err, undefined)
  const dst = path.join(tmpDir(), 'quiet.bin')
  assert.equal((await w.call(Method.DRIVE_GET, { drive, path: '/quiet.bin', destinationPath: dst })).err, undefined)
  assert.deepEqual(w.events.filter((e) => e.ev === EventName.DRIVE_PROGRESS), [])
})

// A source that stays open and never delivers a byte: a FIFO the test holds open for reading and
// writing (so neither open() blocks) but never writes to.
test('a put whose source moves no bytes fails with TRANSFER_STALLED after idleMs', async () => {
  const w = bootWorklet()
  const drive = await openDrive(w)
  const fifo = path.join(tmpDir(), 'stuck.fifo')
  execFileSync('mkfifo', [fifo])
  const holder = fs.openSync(fifo, 'r+')
  try {
    const started = Date.now()
    const res = await w.call(Method.DRIVE_PUT, { drive, path: '/stuck.bin', localSourcePath: fifo, idleMs: 1000 })
    const took = Date.now() - started
    assert.equal(res.err && res.err.code, 'TRANSFER_STALLED', JSON.stringify(res))
    assert.ok(took >= 900 && took < 5000, 'failed after about idleMs, took ' + took + ' ms')
  } finally {
    fs.closeSync(holder)
  }
})
