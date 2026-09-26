// BladeWatch-rdtj.24 -- the opt-in persistent swarm identity (--persistent-identity).
//
// A head unit's server peer was restarting as a stranger: a random Hyperswarm key
// pair per worklet start, so dial-only clients redialed a dead key forever and
// every restart left a dead announcer on the DHT. These pin that the flag keeps
// one key across restarts, that WITHOUT it every start is still a fresh identity
// (apps must not become trackable by default), and how the seed file is kept.
//
// RUNBOOK -- from packages/flutter_pear/pear-end/:
//   node --test test/persistent-identity.test.js
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

const INDEX_PATH = require.resolve('../index.js')
const SEED_FILE = 'swarm-identity.seed'

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
function tmpDir () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-identity-test-'))
  tmpDirs.push(dir)
  return dir
}

let testnet
test.before(async () => {
  testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
})
test.after(async () => {
  await Promise.all(swarmInstances.map((s) => s.destroy().catch(() => {})))
  await testnet.destroy()
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

// Loads index.js as a fresh worklet generation with [argv], and returns the public
// key of the swarm it built.
function boot (argv) {
  const ipc = new EventEmitter()
  ipc.write = () => {}
  global.BareKit = { IPC: ipc }
  global.Bare = {
    argv,
    on: () => {},
    exit: (code) => { throw new Error('Bare.exit(' + code + ') called during test') }
  }
  const before = swarmInstances.length
  delete require.cache[INDEX_PATH]
  require(INDEX_PATH)
  assert.equal(swarmInstances.length, before + 1, 'index.js builds exactly one swarm')
  return swarmInstances[before].keyPair.publicKey.toString('hex')
}

test('with --persistent-identity, a restart keeps the same key', () => {
  const dir = tmpDir()
  const first = boot([dir, '--persistent-identity'])
  const second = boot([dir, '--persistent-identity'])
  assert.equal(second, first)
})

test('the seed is 32 bytes at mode 0600, and no temp file is left behind', () => {
  const dir = tmpDir()
  boot([dir, '--persistent-identity'])
  const file = path.join(dir, SEED_FILE)
  assert.equal(fs.readFileSync(file).length, 32)
  assert.equal(fs.statSync(file).mode & 0o777, 0o600, 'whoever holds the seed IS this peer')
  assert.equal(fs.existsSync(file + '.tmp'), false)
})

test('without the flag every start is a fresh identity, and no seed is written', () => {
  const dir = tmpDir()
  const first = boot([dir])
  const second = boot([dir])
  assert.notEqual(second, first, 'apps must not carry one trackable identity by default')
  assert.equal(fs.existsSync(path.join(dir, SEED_FILE)), false)
})

test('each storage dir has its own identity', () => {
  assert.notEqual(boot([tmpDir(), '--persistent-identity']), boot([tmpDir(), '--persistent-identity']))
})

test('a seed of the wrong length is replaced once, then kept', () => {
  const dir = tmpDir()
  const file = path.join(dir, SEED_FILE)
  fs.writeFileSync(file, Buffer.from('short'))
  const first = boot([dir, '--persistent-identity'])
  assert.equal(fs.readFileSync(file).length, 32)
  assert.equal(boot([dir, '--persistent-identity']), first)
})
