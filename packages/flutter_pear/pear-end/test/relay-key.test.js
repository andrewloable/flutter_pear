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
const { Method, EventName, FrameType, ErrorCode } = require('../schema')

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
let relayOnly = false // opt-in, see relayOnlyDht
class TestnetHyperswarm extends Hyperswarm {
  constructor (opts = {}) {
    if (relayOnly) opts = { ...opts, dht: relayOnlyDht() }
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
  const isRelayed = require(INDEX_PATH).isRelayed

  // Every event frame the worklet sends, in order.
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
    const frame = Buffer.concat([Buffer.from([FrameType.JSON]), Buffer.from(JSON.stringify({ id, m: method, p: params }))])
    const lengthPrefix = Buffer.alloc(4)
    lengthPrefix.writeUInt32BE(frame.length, 0)
    ipc.emit('data', Buffer.concat([lengthPrefix, frame]))
    return response
  }
  return { swarm, call, isRelayed, events }
}

// A DHT for Hyperswarm's public opts.dht that can only reach a peer through a relay: its server
// never hole punches or shares a local address, and Hyperswarm's own dials skip the same-host LAN
// shortcut. hyperdht's internal dial to the relay passes no keyPair and keeps its LAN path;
// without that exception it cannot reach the relay and fails with HOLEPUNCH_ABORTED.
function relayOnlyDht () {
  const dht = new DHT({ bootstrap: currentBootstrap })
  const createServer = dht.createServer.bind(dht)
  dht.createServer = (o, onconnection) => createServer({ ...o, holepunch: false, shareLocalAddress: false }, onconnection)
  const connect = dht.connect.bind(dht)
  dht.connect = (publicKey, o) => connect(publicKey, o && o.keyPair ? { ...o, localConnection: false, fastOpen: false } : o)
  cleanup.push(() => dht.destroy())
  return dht
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
async function startRelay (serverKeyPair = referenceServerKeyPair(), memberPublicKey = Buffer.from(VECTOR.member, 'hex')) {
  const members = [].concat(memberPublicKey)
  const dht = new DHT({ bootstrap: testnet.bootstrap })
  const relay = new BlindRelayServer({ createStream: (opts) => dht.createRawStream({ ...opts, framed: true }) })
  const server = dht.createServer(
    { firewall: (remotePublicKey) => !members.some((m) => remotePublicKey.equals(m)) },
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
  await server.listen(serverKeyPair)
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

// relay.setKeys (flutter_pear 0.4.10): the relay's key pair is generated on the
// relay host and never given to peers; they hold only its public key and a
// member seed, so no member can compute the relay's secret key.
const crypto = require('node:crypto')

test('relay.setKeys applies the member key pair from the seed and the given relay public key', async () => {
  const { swarm, call } = bootWorklet()
  const identity = swarm.keyPair.publicKey.toString('hex')
  const seed = crypto.randomBytes(32)
  const relayPub = DHT.keyPair().publicKey

  const res = await call(Method.RELAY_SET_KEYS, { publicKey: relayPub.toString('hex'), memberSeed: seed.toString('hex') })
  assert.equal(res.err, undefined)
  const member = DHT.keyPair(seed).publicKey.toString('hex')
  assert.equal(res.ok.memberPublicKey, member)
  assert.equal(swarm.dht.defaultKeyPair.publicKey.toString('hex'), member)
  assert.deepEqual(swarm.relayThrough(true, swarm), relayPub)
  assert.equal(swarm.keyPair.publicKey.toString('hex'), identity, 'the swarm identity never changes')
  assert.equal(JSON.stringify(res).includes(seed.toString('hex')), false, 'the reply never carries the seed')
})

test('two worklets with the same relay keys connect through a relay whose key pair no member can derive', async () => {
  const seed = crypto.randomBytes(32)
  const serverKp = DHT.keyPair() // never given to the worklets
  const relay = await startRelay(serverKp, DHT.keyPair(seed).publicKey)
  const a = bootWorklet()
  const b = bootWorklet()
  const keys = { publicKey: serverKp.publicKey.toString('hex'), memberSeed: seed.toString('hex') }
  assert.equal((await a.call(Method.RELAY_SET_KEYS, keys)).err, undefined)
  assert.equal((await b.call(Method.RELAY_SET_KEYS, keys)).err, undefined)

  assert.equal(await relayedEcho(a, b), 'ping')
  assert.equal(relay.stats.pairings.matched, 1)
})

test('a worklet with a different member seed is refused', async () => {
  const seed = crypto.randomBytes(32)
  const serverKp = DHT.keyPair()
  const relay = await startRelay(serverKp, DHT.keyPair(seed).publicKey)
  const a = bootWorklet()
  const b = bootWorklet()
  const pub = serverKp.publicKey.toString('hex')
  await a.call(Method.RELAY_SET_KEYS, { publicKey: pub, memberSeed: seed.toString('hex') })
  await b.call(Method.RELAY_SET_KEYS, { publicKey: pub, memberSeed: crypto.randomBytes(32).toString('hex') })

  assert.match(await relayedEcho(a, b), /^error /)
  assert.equal(relay.stats.pairings.matched, 0)
})

test('relay.setKeys refuses malformed input and changes nothing', async () => {
  const { swarm, call } = bootWorklet()
  const good = { publicKey: 'ab'.repeat(32), memberSeed: 'cd'.repeat(32) }
  await call(Method.RELAY_SET_KEYS, good)
  const applied = swarm.dht.defaultKeyPair
  const policy = swarm.relayThrough

  const bads = [
    { memberSeed: good.memberSeed },
    { publicKey: good.publicKey },
    { ...good, publicKey: 'ab'.repeat(32).slice(1) },
    { ...good, memberSeed: good.memberSeed + 'c' },
    { ...good, memberSeed: 'zz' + good.memberSeed.slice(2) },
    { ...good, publicKey: 12345 },
    null
  ]
  for (const bad of bads) {
    const res = await call(Method.RELAY_SET_KEYS, bad)
    assert.equal(res.err && res.err.code, ErrorCode.INVALID_RELAY_KEY, JSON.stringify(bad))
    assert.equal(swarm.dht.defaultKeyPair, applied, 'state unchanged after ' + JSON.stringify(bad))
    assert.equal(swarm.relayThrough, policy)
  }
})

test('relay.set null turns a relay.setKeys relay off', async () => {
  const { swarm, call } = bootWorklet()
  const original = swarm.dht.defaultKeyPair
  await call(Method.RELAY_SET_KEYS, { publicKey: 'ab'.repeat(32), memberSeed: 'cd'.repeat(32) })
  assert.notEqual(swarm.relayThrough, null)
  await call(Method.RELAY_SET, { key: null })
  assert.equal(swarm.dht.defaultKeyPair, original)
  assert.equal(swarm.relayThrough, null)
})

test('swarm.publicKey returns the key peers see', async () => {
  const { swarm, call } = bootWorklet()
  const res = await call(Method.SWARM_PUBLIC_KEY)
  assert.equal(res.err, undefined)
  assert.equal(res.ok.publicKey, swarm.keyPair.publicKey.toString('hex'))
})

test('a relay setting does not change swarm.publicKey', async () => {
  const { swarm, call } = bootWorklet()
  const before = (await call(Method.SWARM_PUBLIC_KEY)).ok.publicKey
  await call(Method.RELAY_SET, { key: VECTOR.key })
  const after = (await call(Method.SWARM_PUBLIC_KEY)).ok.publicKey
  assert.equal(after, before)
  assert.notEqual(after, swarm.dht.defaultKeyPair.publicKey.toString('hex'), 'the relay member key is a different key')
})

// ---- which connections are relayed (isRelayed, SWARM_CONNECTION.relayed, CONNECTION_PATH) ----

// A server on a's DHT reachable only through the relay, dialed from b's DHT (as relayedEcho),
// keeping both ends: { client, server }.
async function relayedPair (a, b) {
  let serverSocket
  const accepted = new Promise((resolve) => {
    const server = a.swarm.dht.createServer(
      { holepunch: false, shareLocalAddress: false, relayThrough: () => a.swarm.relayThrough(true, a.swarm) },
      (socket) => { socket.on('error', () => {}); serverSocket = socket; resolve() }
    )
    cleanup.push(() => server.close())
    a.server = server
  })
  await a.server.listen(DHT.keyPair())
  const client = b.swarm.dht.connect(a.server.publicKey, { localConnection: false, fastOpen: false })
  client.on('error', () => {})
  await new Promise((resolve, reject) => { client.once('open', resolve); client.once('error', reject) })
  await accepted
  cleanup.push(async () => { client.destroy(); serverSocket.destroy() })
  return { client, server: serverSocket }
}

// Both worklets join one topic; resolves with each side's Hyperswarm connection.
async function swarmPair (a, b) {
  const topic = crypto.randomBytes(32).toString('hex')
  const conns = [new Promise((resolve) => a.swarm.once('connection', resolve)), new Promise((resolve) => b.swarm.once('connection', resolve))]
  // Staggered joins plus one more discovery pass for the first joiner: simultaneous joins on
  // this local testnet never converge (see rejoin-replay.test.js's joinWorkletAndWait).
  for (const w of [a, b]) {
    await w.call(Method.SWARM_JOIN, { topic })
    await w.swarm.flush()
    await new Promise((resolve) => setTimeout(resolve, 200))
  }
  await a.swarm.join(Buffer.from(topic, 'hex'), { server: true, client: true }).flushed()
  const [connA, connB] = await Promise.all(conns)
  return { topic, connA, connB }
}

test('a connection made through the relay reports relayed on both ends', async () => {
  await startRelay()
  const a = bootWorklet()
  const b = bootWorklet()
  await a.call(Method.RELAY_SET, { key: VECTOR.key })
  await b.call(Method.RELAY_SET, { key: VECTOR.key })

  const { client, server } = await relayedPair(a, b)
  assert.equal(b.isRelayed(client), true, 'the dialing end')
  assert.equal(a.isRelayed(server), true, 'the accepting end')
})

test('a relayed connection is reported relayed even when this side has no relay configured', async () => {
  // The remote side picks the relay (payload.relayThrough); this worklet never set one.
  const a = bootWorklet()
  const b = bootWorklet()
  const seed = crypto.randomBytes(32)
  const serverKp = DHT.keyPair()
  // The relay admits a's member key and b's ordinary key (b never configures anything).
  await startRelay(serverKp, [DHT.keyPair(seed).publicKey, b.swarm.dht.defaultKeyPair.publicKey])
  await a.call(Method.RELAY_SET_KEYS, { publicKey: serverKp.publicKey.toString('hex'), memberSeed: seed.toString('hex') })

  const { client } = await relayedPair(a, b)
  assert.equal(b.swarm.relayThrough, null)
  assert.equal(b.isRelayed(client), true)
})

test('a direct connection with a relay configured reports not relayed', async () => {
  const a = bootWorklet()
  const b = bootWorklet()
  await a.call(Method.RELAY_SET, { key: VECTOR.key })
  await b.call(Method.RELAY_SET, { key: VECTOR.key })

  const { connA, connB } = await swarmPair(a, b)
  assert.equal(a.isRelayed(connA), false)
  assert.equal(b.isRelayed(connB), false)
})

test('with no relay configured, nothing is relayed', async () => {
  const a = bootWorklet()
  const b = bootWorklet()
  const { connA, connB } = await swarmPair(a, b)
  assert.equal(a.isRelayed(connA), false)
  assert.equal(b.isRelayed(connB), false)
})

test('an unreadable address counts as relayed', () => {
  const { isRelayed } = bootWorklet()
  assert.equal(isRelayed({ rawStream: {} }), true)
  assert.equal(isRelayed(null), true)
})

test('swarm.connection carries relayed, on the first connection and on the re-join replay', async () => {
  const a = bootWorklet()
  const b = bootWorklet()
  const { topic } = await swarmPair(a, b)
  await new Promise((resolve) => setTimeout(resolve, 200))
  const conns = () => a.events.filter((e) => e.ev === EventName.SWARM_CONNECTION)
  assert.equal(conns().length, 1)
  assert.equal(typeof conns()[0].p.relayed, 'boolean')

  await a.call(Method.SWARM_JOIN, { topic }) // replays the already-connected peer
  assert.equal(conns().length, 2)
  assert.equal(typeof conns()[1].p.relayed, 'boolean')
})

test('connection.path is sent only when the value changes', async () => {
  const a = bootWorklet()
  const b = bootWorklet()
  const { connA } = await swarmPair(a, b)
  await new Promise((resolve) => setTimeout(resolve, 200))
  const paths = () => a.events.filter((e) => e.ev === EventName.CONNECTION_PATH)

  connA.rawStream.emit('remote-changed') // same address: still direct
  assert.equal(paths().length, 0)

  // The address becomes unreadable: the worklet cannot show it is direct, so it says relayed.
  Object.defineProperty(connA.rawStream, 'remoteHost', { get: () => null, configurable: true })
  connA.rawStream.emit('remote-changed')
  assert.equal(paths().length, 1)
  assert.equal(paths()[0].p.relayed, true)

  connA.rawStream.emit('remote-changed') // still relayed
  assert.equal(paths().length, 1)
})

// Datagrams (Method.CONNECTION_SEND) over a connection that can only exist through the relay.
// Needs the relay-only DHT: on one host two worklets otherwise connect directly.
test('a datagram crosses a relayed connection', async () => {
  await startRelay()
  relayOnly = true
  let a, b
  try {
    a = bootWorklet()
    b = bootWorklet()
  } finally {
    relayOnly = false
  }
  await a.call(Method.RELAY_SET, { key: VECTOR.key })
  await b.call(Method.RELAY_SET, { key: VECTOR.key })
  setRandomized(a.swarm, true)
  setRandomized(b.swarm, true)

  const { connA, connB } = await swarmPair(a, b)
  await new Promise((resolve) => setTimeout(resolve, 2000)) // a datagram right after open can be lost
  const connectionEvent = (w) => w.events.find((e) => e.ev === EventName.SWARM_CONNECTION)
  assert.equal(connectionEvent(a).p.relayed, true, 'relayed on a')
  assert.equal(connectionEvent(b).p.relayed, true, 'relayed on b')
  assert.equal(a.isRelayed(connA), true)
  assert.equal(b.isRelayed(connB), true)

  const bSeesA = connectionEvent(b).p.peer
  const aSeesB = connectionEvent(a).p.peer
  const res = await a.call(Method.CONNECTION_SEND, { peer: aSeesB, data: 'b3ZlciB0aGUgcmVsYXk=' })
  assert.equal(res.err, undefined)

  const messages = () => b.events.filter((e) => e.ev === EventName.CONNECTION_MESSAGE)
  for (let i = 0; i < 50 && messages().length === 0; i++) await new Promise((resolve) => setTimeout(resolve, 100))
  assert.equal(messages().length, 1)
  assert.equal(messages()[0].p.data, 'b3ZlciB0aGUgcmVsYXk=')
  assert.equal(messages()[0].p.peer, bSeesA)
  assert.equal(a.isRelayed(connA), true, 'still relayed: the datagram went through the relay')
  assert.equal(b.isRelayed(connB), true)
})
