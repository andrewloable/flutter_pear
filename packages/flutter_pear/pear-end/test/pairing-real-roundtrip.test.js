// Regression test for flutter_pear-qfz -- two distinct root causes, both
// fixed entirely within index.js (no node_modules changes). See index.js's
// own WORKAROUND comments above Method.PAIRING_CREATE_INVITE for the full
// root-cause writeups:
//
// 1. blind-pairing-core@2.10.1's compact-encoding round trip decodes a
//    zero-length buffer back as `null`, tripping up verifyReceipt's caller
//    into misreading a valid signature as a failure -- so pairing with an
//    empty candidate userData (the common case) always failed. Confirmed by
//    an isolated repro against a local DHT testnet and by intercepting
//    sodium's own crypto_sign_verify_detached to prove the signature itself
//    is valid.
// 2. blind-pairing-core's MemberRequest.confirm({key}) requires the
//    confirmed key's discoveryKey to match the invite's own -- but
//    PearPairingCandidate.confirm's documented contract (and the fake) lets
//    the app pass an unrelated, arbitrary key. Before the fix, NO real
//    pairing could ever complete, independent of bug 1.
//
// (A candidate de-dup layer was attempted here for flutter_pear-0zq --
// blind-pairing can call onadd more than once for the same candidate -- but
// reverted: `request.session` is a pure function of (invite, userData), NOT
// a per-device identity, so two DIFFERENT physical candidates sharing the
// same invite and the same default empty userData collide on session. The
// de-dup layer would have silently merged them, and worse, silently
// auto-admitted any later distinct candidate with the confirmed key once
// the first was confirmed. flutter_pear-0zq is reopened with this finding;
// a correct fix needs a properly per-delivery identity, not blind-pairing's
// own session hash.)
//
// This drives the REAL Method.PAIRING_CREATE_INVITE / PAIRING_ACCEPT_INVITE /
// PAIRING_CONFIRM_CANDIDATE handlers in index.js end to end, over a REAL
// (but fully local/offline) hyperdht testnet -- proving an actual blind
// -pairing round trip succeeds. flutter_pear_test's in-memory fake cannot
// catch any of this: it never runs blind-pairing-core's real crypto/wire
// code (see qfz's own notes -- this was previously entirely unexercised
// outside the fake).
//
// Run directly with Node's built-in test runner from the pear-end/
// directory: `node --test` (see autobase-recipes.test.js's header for why a
// directory path argument doesn't work on this Node version). Each
// `node --test` file runs in its own process by default, so this file's
// require.cache/global.Bare mutations don't collide with index.test.js's own.
//
// This file's real DHT/network operations noticeably raise the whole
// suite's CPU/timing load when Node's test runner executes every test FILE
// concurrently (its own default) -- confirmed empirically to be enough to
// occasionally flip an unrelated, pre-existing timing-sensitive
// autobase-recipes.test.js assertion (a crdtMap convergence check) from
// pass to fail, despite that test passing reliably alone. package.json's
// own `test` script now pins `--test-concurrency=1` for exactly this
// reason -- the total suite runtime cost is negligible (this file adds
// ~3s either way), and it buys deterministic, non-flaky CI runs.
'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const NodeModule = require('node:module')
const fs = require('node:fs')
const fsPromises = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const { EventEmitter } = require('node:events')

const crypto = require('hypercore-crypto')
const Hyperswarm = require('hyperswarm')
const createTestnet = require('hyperdht/testnet')
const { Method, FrameType, EventName } = require('../schema')

const INDEX_PATH = require.resolve('../index.js')

// Every Hyperswarm index.js constructs must talk to our local, offline DHT
// testnet, not the real internet bootstrap (deterministic, fast, no
// network) -- same swap technique as index.test.js's own TrackedHyperswarm,
// plus injecting the testnet's bootstrap since index.js calls
// `new Hyperswarm()` with no options of its own.
let currentBootstrap = null
const swarmInstances = []
class TestnetHyperswarm extends Hyperswarm {
  constructor (opts = {}) {
    super({ ...opts, bootstrap: currentBootstrap })
    swarmInstances.push(this)
  }
}
require.cache[require.resolve('hyperswarm')].exports = TestnetHyperswarm

// index.js constructs `new BlindPairing(swarm)` with no poll option, so it
// uses blind-pairing's own DEFAULT_POLL (7 minutes -- reasonable for real
// DHT-scale usage, far too slow for a test). Swap in a subclass that always
// injects a short poll interval; static methods (createInvite/decodeInvite)
// inherit through the normal prototype chain, unaffected.
const BlindPairingReal = require('blind-pairing')
class FastBlindPairing extends BlindPairingReal {
  constructor (swarm, opts = {}) {
    super(swarm, { ...opts, poll: 300 })
  }
}
require.cache[require.resolve('blind-pairing')].exports = FastBlindPairing

test.after(() => Promise.all(swarmInstances.map((s) => s.destroy().catch(() => {}))))

// index.js requires 'bare-fs'/'bare-path' directly -- both Bare-runtime-only
// (see index.test.js's own identical comment for the full why). Pre-seed
// Node's require cache with Node-native equivalents.
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
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-pairing-test-'))
  tmpDirs.push(dir)
  return dir
}
test.after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

// Boots a fresh, independent instance of index.js's module-level state (its
// own `swarm`, `pairing`, `invites`, ...) against its own stubbed IPC pipe --
// same pattern as index.test.js's bootWorklet, plus onEvent() to await a
// specific fire-and-forget event (PAIRING_CANDIDATE here), since pairing is
// event-driven, not purely request/response.
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

  return { call, onEvent }
}

async function pairOnce (t, { acceptUserData } = {}) {
  const testnet = await createTestnet(3)
  currentBootstrap = testnet.bootstrap
  t.after(() => testnet.destroy().catch(() => {}))

  const inviter = bootWorklet()
  const acceptor = bootWorklet()

  const createRes = await inviter.call(Method.PAIRING_CREATE_INVITE, {})
  assert.ok(createRes.ok, 'createInvite ok: ' + JSON.stringify(createRes.err))
  const { invite, inviteId } = createRes.ok

  const acceptParams = { invite, timeoutMs: 30000 }
  if (acceptUserData !== undefined) acceptParams.userData = acceptUserData.toString('base64')
  const acceptResPromise = acceptor.call(Method.PAIRING_ACCEPT_INVITE, acceptParams)

  // blind-pairing can deliver the SAME candidate's request more than once
  // (observed empirically: both a DHT-poll discovery and a live swarm
  // connection can independently trigger onadd for the same underlying
  // token/session, each producing its own PAIRING_CANDIDATE event with a
  // fresh candidateId -- a separate, orthogonal characteristic from THIS
  // ticket's bug; a de-dup fix was attempted and reverted, see this file's
  // header comment for why. Confirm every notification with the SAME key
  // so the accepting side succeeds regardless of which delivery it ends up
  // racing against.
  const confirmKey = crypto.randomBytes(32)
  let firstCandidateEvent = null
  let stop = false
  const confirmLoop = (async () => {
    while (!stop) {
      let event
      try {
        event = await inviter.onEvent(
          (msg) => msg.ev === EventName.PAIRING_CANDIDATE && msg.p.inviteId === inviteId,
          1000
        )
      } catch {
        continue // no new candidate notification in this window -- keep polling until `stop`
      }
      if (!firstCandidateEvent) firstCandidateEvent = event
      await inviter.call(Method.PAIRING_CONFIRM_CANDIDATE, {
        inviteId,
        candidateId: event.p.candidateId,
        key: confirmKey.toString('base64')
      })
    }
  })()

  const acceptRes = await acceptResPromise
  stop = true
  await confirmLoop

  assert.ok(
    acceptRes.ok,
    // Neither pre-fix bug threw synchronously all the way to the acceptor:
    // bug 1 (empty userData) made request.open() throw 'Failed to open
    // invite with provided key' on the INVITER's side, but that's caught
    // locally inside onadd (see index.js's own comment there) and never
    // propagated -- no PAIRING_CANDIDATE event fires at all, so the
    // acceptor just silently never gets confirmed. Bug 2 (unrelated confirm
    // key) fails inside blind-pairing-core's own _openResponse on the
    // CANDIDATE side, also caught internally (emits 'rejected', never
    // throws out). Both pre-fix bugs are only visible here, on the
    // acceptor, as PAIRING_TIMEOUT once the full timeoutMs bound elapses.
    'acceptInvite must succeed, not time out the way both pre-fix bugs did: ' + JSON.stringify(acceptRes.err)
  )
  assert.equal(
    acceptRes.ok.key,
    confirmKey.toString('base64'),
    'the accepting side must receive exactly the key the inviter confirmed'
  )
  assert.ok(firstCandidateEvent, 'at least one PAIRING_CANDIDATE notification must have fired')

  return firstCandidateEvent
}

test('real (non-fake) blind-pairing round trip succeeds with NO userData -- the default, most common case (flutter_pear-qfz regression)',
  async (t) => {
    const candidateEvent = await pairOnce(t)
    assert.equal(candidateEvent.p.userData, '', 'no userData was sent, so it must render as empty, not corrupt/throw')
  })

test('real (non-fake) blind-pairing round trip still succeeds with NON-empty userData, and it survives intact',
  async (t) => {
    const candidateEvent = await pairOnce(t, { acceptUserData: Buffer.from('hello from the candidate') })
    assert.equal(
      Buffer.from(candidateEvent.p.userData, 'base64').toString(),
      'hello from the candidate',
      'non-empty userData must round-trip byte-for-byte to the inviter'
    )
  })

test('real (non-fake) blind-pairing round trip succeeds with a genuine single zero-byte userData (the workaround\'s edge case)',
  async (t) => {
    const candidateEvent = await pairOnce(t, { acceptUserData: Buffer.from([0]) })
    assert.equal(
      Buffer.from(candidateEvent.p.userData, 'base64').toString('hex'),
      '00',
      'a real single zero-byte userData must not be misidentified as "no userData"'
    )
  })
