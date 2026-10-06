// The owner relay (Method.RELAY_SET, flutter_pear 0.4.9).
//
// Two randomizing NATs cannot hole-punch at all: hyperdht aborts with
// HOLEPUNCH_DOUBLE_RANDOMIZED_NATS. Found by BladeWatch (BladeWatch-a7mu), whose
// car sits behind carrier CGNAT on its SIM, so a phone on mobile data never
// reached it. The owner runs a blind relay keyed by a 12-digit relay key; these
// pin that pear-end derives the SAME key pairs as the reference relay (BladeWatch
// relay/relay.js -- the vector below is copied from its test), applies them where
// hyperdht uses them, leaves WHEN to relay to Hyperswarm, and that a relay
// refusing non-members really does carry a connection between two members.
//
// RUNBOOK -- from packages/flutter_pear/pear-end/:
//   node --test test/relay-key.test.js
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
const DHT = require('hyperdht')
const createTestnet = require('hyperdht/testnet')
const { Server: BlindRelayServer } = require('blind-relay')
const sodium = require('sodium-universal')
const { Method, FrameType, ErrorCode } = require('../schema')

const INDEX_PATH = require.resolve('../index.js')

// From BladeWatch relay/test/relay.test.js. If these ever differ, cars and
// companions dial a relay that does not exist, or one that refuses them.
const VECTOR = {
  key: '4821-0937-5562',
  server: '7d040c713b507b86738ce0968f56e879d1d40407976148ae1877fd2f16cfedd5',
  member: '9c84075c7e07e8ad1b227343c967ae2e49b9d30502d1ecdcfc5552baff394606'
}

// Never touch the public DHT from a test -- the same testnet swap the other suites use.
let currentBootstrap = null
const swarmInstances = []
class TestnetHyperswarm extends Hyperswarm {
  constructor (opts = {}) {
    super({ ...opts, bootstrap: currentBootstrap })
    swarmInstances.push(this)
  }
}
require.cache[require.resolve('hyperswarm')].exports = TestnetHyperswarm

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
const cleanup = []
let testnet
test.before(async () => {
  testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
})
test.after(async () => {
  for (const fn of cleanup.reverse()) await fn().catch(() => {})
  await Promise.all(swarmInstances.map((s) => s.destroy().catch(() => {})))
  await testnet.destroy()
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

// A fresh index.js generation, driven through the real IPC framing (see
// index.test.js's bootWorklet). Returns its swarm and an RPC call helper.
function bootWorklet () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-relay-key-test-'))
  tmpDirs.push(dir)
  const ipc = new EventEmitter()
  const writeListeners = new Set()
  ipc.write = (buf) => { for (const listener of writeListeners) listener(buf) }
  global.BareKit = { IPC: ipc }
  global.Bare = {
    argv: [dir],
    on: () => {},
    exit: (code) => { throw new Error('Bare.exit(' + code + ') called during test') }
  }
  const before = swarmInstances.length
  delete require.cache[INDEX_PATH]
  require(INDEX_PATH)
  const swarm = swarmInstances[before]

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
    const frame = Buffer.concat([Buffer.from([FrameType.JSON]), Buffer.from(JSON.stringify({ id, m: method, p: params }))])
    const lengthPrefix = Buffer.alloc(4)
    lengthPrefix.writeUInt32BE(frame.length, 0)
    ipc.emit('data', Buffer.concat([lengthPrefix, frame]))
    return response
  }
  return { swarm, call }
}

// Hyperswarm reads the NAT type from its DHT when it decides; pin it per case.
function setRandomized (swarm, randomized) {
  Object.defineProperty(swarm.dht, 'randomized', { get: () => randomized, configurable: true })
}

test('relay.set derives the reference key pairs and applies them where hyperdht uses them', async () => {
  const { swarm, call } = bootWorklet()
  const identity = swarm.keyPair.publicKey.toString('hex')

  const res = await call(Method.RELAY_SET, { key: VECTOR.key })
  assert.equal(res.err, undefined)
  assert.equal(res.ok.relayPublicKey, VECTOR.server)
  assert.equal(swarm.dht.defaultKeyPair.publicKey.toString('hex'), VECTOR.member)
  assert.equal(swarm.keyPair.publicKey.toString('hex'), identity, 'the swarm identity never changes')
  assert.equal(JSON.stringify(res).includes('4821'), false, 'the reply never carries the key')
})

test('the relay is used only behind a randomizing NAT, or when forced', async () => {
  const { swarm, call } = bootWorklet()
  await call(Method.RELAY_SET, { key: '482109375562' })

  setRandomized(swarm, false)
  assert.equal(swarm.relayThrough(false, swarm), null, 'a punchable NAT stays direct')
  assert.equal(swarm.relayThrough(true, swarm).toString('hex'), VECTOR.server, 'forced after a failed punch')
  setRandomized(swarm, true)
  assert.equal(swarm.relayThrough(undefined, swarm).toString('hex'), VECTOR.server, 'carrier CGNAT relays')
})

test('relay.set null turns the relay off and restores the original DHT key pair', async () => {
  const { swarm, call } = bootWorklet()
  const original = swarm.dht.defaultKeyPair
  assert.equal(swarm.relayThrough, null, 'off by default')

  await call(Method.RELAY_SET, { key: VECTOR.key })
  const res = await call(Method.RELAY_SET, { key: null })
  assert.deepEqual(res.ok, {})
  assert.equal(swarm.dht.defaultKeyPair, original)
  assert.equal(swarm.relayThrough, null)

  await call(Method.RELAY_SET, { key: VECTOR.key })
  await call(Method.RELAY_SET, {})
  assert.equal(swarm.dht.defaultKeyPair, original, 'a missing key means off too')
})

test('a malformed key is refused and changes nothing', async () => {
  const { swarm, call } = bootWorklet()
  await call(Method.RELAY_SET, { key: VECTOR.key })
  const applied = swarm.dht.defaultKeyPair
  const policy = swarm.relayThrough

  for (const bad of ['', '482109', '4821093755621', '4821-0937-556x', '٤821-0937-5562', 482109375562]) {
    const res = await call(Method.RELAY_SET, { key: bad })
    assert.equal(res.err && res.err.code, ErrorCode.INVALID_RELAY_KEY, JSON.stringify(bad))
    assert.equal(swarm.dht.defaultKeyPair, applied, 'state unchanged after ' + JSON.stringify(bad))
    assert.equal(swarm.relayThrough, policy)
  }
})

// The vector's SERVER key pair, recomputed here with libsodium directly rather
// than through pear-end, so the relay below listens where the spec says it must.
function referenceServerKeyPair () {
  const salt = Buffer.alloc(16)
  sodium.crypto_generichash(salt, Buffer.from('flutter_pear relay v1 salt'))
  const root = Buffer.alloc(32)
  sodium.crypto_pwhash(root, Buffer.from('482109375562'), salt, 2, 64 * 1024 * 1024,
    sodium.crypto_pwhash_ALG_ARGON2ID13)
  const seed = Buffer.alloc(32)
  sodium.crypto_generichash(seed, Buffer.concat([Buffer.from('flutter_pear relay v1 server'), root]))
  const keyPair = DHT.keyPair(seed)
  assert.equal(keyPair.publicKey.toString('hex'), VECTOR.server)
  return keyPair
}

// The reference relay's behaviour (BladeWatch relay/relay.js createRelay): a blind
// relay listening under the server key pair that accepts only the member key.
async function startRelay () {
  const dht = new DHT({ bootstrap: testnet.bootstrap })
  const relay = new BlindRelayServer({ createStream: (opts) => dht.createRawStream({ ...opts, framed: true }) })
  const member = Buffer.from(VECTOR.member, 'hex')
  const server = dht.createServer(
    { firewall: (remotePublicKey) => !remotePublicKey.equals(member) },
    // As in the reference relay: a member that vanishes resets its stream, which
    // must not throw. Unhandled, it would crash the relay process.
    (socket) => {
      socket.on('error', () => {})
      relay.accept(socket, { id: socket.remotePublicKey }).on('error', () => {})
    }
  )
  // Live sessions first: relay.close() waits forever for a session still carrying a pair.
  cleanup.push(async () => {
    for (const session of relay.sessions) session.destroy()
    await relay.close()
    await dht.destroy()
  })
  await server.listen(referenceServerKeyPair())
  return relay
}

// A server on worklet A's DHT that can only be reached through the relay A's
// policy names (hole punching and local shortcuts off), dialed from worklet B's
// DHT. Both relay connections are opened by hyperdht with each DHT's
// defaultKeyPair -- exactly what relay.set replaced.
async function relayedEcho (a, b) {
  const server = a.swarm.dht.createServer(
    { holepunch: false, shareLocalAddress: false, relayThrough: () => a.swarm.relayThrough(true, a.swarm) },
    (socket) => socket.on('error', () => {}).on('data', (data) => socket.write(data))
  )
  cleanup.push(() => server.close())
  await server.listen(DHT.keyPair())
  const socket = b.swarm.dht.connect(server.publicKey, { localConnection: false, fastOpen: false })
  return new Promise((resolve) => {
    socket.once('open', () => socket.write(Buffer.from('ping')))
    socket.once('data', (data) => { socket.destroy(); resolve(data.toString()) })
    socket.once('error', (err) => resolve('error ' + (err.code || err.message)))
  })
}

test('two worklets that applied the relay key connect through the owner relay', async () => {
  const relay = await startRelay()
  const a = bootWorklet()
  const b = bootWorklet()
  await a.call(Method.RELAY_SET, { key: VECTOR.key })
  await b.call(Method.RELAY_SET, { key: VECTOR.key })

  assert.equal(await relayedEcho(a, b), 'ping')
  assert.equal(relay.stats.pairings.matched, 1)
})

test('a worklet without the relay key is refused by the owner relay', async () => {
  const relay = await startRelay()
  const a = bootWorklet()
  const b = bootWorklet()
  await a.call(Method.RELAY_SET, { key: VECTOR.key })

  assert.match(await relayedEcho(a, b), /^error /)
  assert.equal(relay.stats.pairings.matched, 0)
})
