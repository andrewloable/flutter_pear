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
// (flutter_pear-0zq: a candidate de-dup layer was attempted here after an
// early investigation observed onadd firing twice for one candidate, but
// reverted -- `request.session` is a pure function of (invite, userData),
// NOT a per-device identity, so the de-dup layer would have silently merged
// two DIFFERENT candidates sharing the same invite/empty-userData, and
// worse, silently auto-admitted any later one with the already-confirmed
// key. Re-investigated (2026-07-05): CONFIRMED still real, but intermittent
// and timing/load-dependent, not a fixed synchronous-scratch-script
// artifact -- an isolated run of just this file (or a standalone repro
// script) never reproduced it across 14+ attempts, but running the FULL
// `npm test` suite reproduced it in 2 of 5 attempts (a genuine duplicate
// candidateId for one physical candidate), consistent with the original
// report's own framing: two independent delivery channels (DHT-poll
// discovery and live-connection delivery) racing, more likely to both fire
// under real system/network load than in a quiet, isolated test run. NOT
// turned into a CI assertion here -- a ~40%-flaky pass/fail would just make
// this file flaky by design, the opposite of its own stated goal (see the
// `--test-concurrency=1` note below). No backend fix attempted (the
// ticket's own reopened notes require a properly per-delivery/per-
// connection identity, never blind-pairing's own session hash, and real
// design work this investigation didn't attempt). The flutter_pear
// PACKAGE itself (lib/src/pairing.dart's PearInvite.candidates stream) has
// NO dedup of its own -- a consumer subscribing directly gets every
// delivery, duplicates included. The example app's
// packages/flutter_pear_example/lib/pairing_screens.dart happens to
// already handle this gracefully: StartRoomScreen._onCandidate's
// synchronous re-entrancy guard (`if (_pairing) return`) drops a second
// delivery for the same physical device arriving mid-confirm, and its
// candidates subscription is cancelled on dispose so a late duplicate
// arriving after handoff has no listener left either -- but that's this
// ONE app's UI code, not a library-level guarantee. Any other
// `PearPairing`/`PearInvite.candidates` consumer needs its own equivalent
// handling. Matches this ticket's own suggested alternative ("an app can
// reasonably just handle an occasional unexpected duplicate
// PAIRING_CANDIDATE notification gracefully... rather than needing a
// backend fix at all") at the app layer, not the library layer.)
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

  // Subscribes to every future matching event (not just the next one, like
  // onEvent above) -- for flutter_pear-0zq's regression test below, which
  // needs to notice a SECOND delivery, not just resolve on the first.
  // Returns an unsubscribe function.
  function onAnyEvent (matcher, cb) {
    const onWrite = (buf) => {
      if (buf.length < 5 || buf[4] !== FrameType.JSON) return
      const len = buf.readUInt32BE(0)
      let msg
      try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
      if (!msg.ev || !matcher(msg)) return
      cb(msg)
    }
    writeListeners.add(onWrite)
    return () => writeListeners.delete(onWrite)
  }

  return { call, onEvent, onAnyEvent }
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

// flutter_pear-0zq: NOT a regression test for "exactly one PAIRING_CANDIDATE
// per candidate" -- see this file's header comment for why that isn't a
// safe CI assertion (confirmed genuinely flaky: ~40% duplicate rate under
// full-suite load, 0% isolated). This instead asserts the property that
// stays true either way: pairing succeeds and confirms the RIGHT device
// even when a duplicate candidate notification for it fires, by confirming
// every notification for the same candidate with the same key (mirroring
// pairOnce's own approach above) and logging when more than one appeared,
// for visibility without failing the build over inherent library timing.
test('real (non-fake) blind-pairing succeeds even if blind-pairing delivers a duplicate candidate notification (flutter_pear-0zq)',
  async (t) => {
    const testnet = await createTestnet(3)
    currentBootstrap = testnet.bootstrap
    t.after(() => testnet.destroy().catch(() => {}))

    const inviter = bootWorklet()
    const acceptor = bootWorklet()

    const createRes = await inviter.call(Method.PAIRING_CREATE_INVITE, {})
    assert.ok(createRes.ok, 'createInvite ok: ' + JSON.stringify(createRes.err))
    const { invite, inviteId } = createRes.ok

    const candidateIds = new Set()
    const confirmKey = crypto.randomBytes(32)
    const off = inviter.onAnyEvent(
      (msg) => msg.ev === EventName.PAIRING_CANDIDATE && msg.p.inviteId === inviteId,
      (event) => {
        candidateIds.add(event.p.candidateId)
        // bootWorklet's call() only ever resolves (matches replies by id,
        // never rejects) -- no .catch needed; a confirm for an
        // already-confirmed/gone candidateId still resolves, just with an
        // {err}, which this test doesn't need to inspect since the
        // assertion below only cares whether the ACCEPTOR ends up with the
        // right key.
        inviter.call(Method.PAIRING_CONFIRM_CANDIDATE, {
          inviteId,
          candidateId: event.p.candidateId,
          key: confirmKey.toString('base64')
        })
      }
    )

    const acceptRes = await acceptor.call(Method.PAIRING_ACCEPT_INVITE, { invite, timeoutMs: 15000 })
    off()

    assert.ok(acceptRes.ok, 'acceptInvite ok: ' + JSON.stringify(acceptRes.err))
    assert.equal(
      acceptRes.ok.key,
      confirmKey.toString('base64'),
      'the accepting side must receive exactly the key the inviter confirmed, even amid a possible duplicate'
    )
    // Not asserting exactly 1 (confirmed flaky, see header comment), but a
    // bound still gives real regression signal: every run observed during
    // this investigation (14 isolated + several full-suite) saw AT MOST 2
    // (the two-delivery-channel model the original report described) --
    // 3+ would mean a materially different, worse characteristic than what
    // was investigated and accepted here.
    assert.ok(
      candidateIds.size <= 2,
      `expected at most 2 distinct candidateIds (the known two-delivery-channel duplicate), got ${candidateIds.size}`
    )
    if (candidateIds.size > 1) {
      // t.diagnostic(), not console.log -- E5.9's log-hygiene guardrail
      // (log_hygiene_test.dart) bans console.* anywhere in pear-end's own
      // first-party JS source, test files included.
      t.diagnostic(`flutter_pear-0zq: observed ${candidateIds.size} distinct candidateIds this run (informational, not a failure)`)
    }
  })

// flutter_pear-xtj: StartRoomScreen now revokes its invite immediately
// after confirming its one candidate (no longer leaving an unconfirmed
// candidate/invite lingering after a successful pairing). index.js's own
// PAIRING_CONFIRM_CANDIDATE handler calls blind-pairing-core's
// request.confirm() WITHOUT awaiting the confirmation's actual wire
// delivery to the peer -- so revoking (which calls member.close()) right
// after confirming is a plausible race that could tear down the
// connection before that confirmation is flushed. Verified empirically
// (10/10 runs) that it does not: the confirmed key still reaches the
// accepting side's acceptInvite() every time.
test('real (non-fake) blind-pairing: revoking an invite immediately after confirming its one candidate does not break that candidate\'s acceptInvite (flutter_pear-xtj)',
  async (t) => {
    const testnet = await createTestnet(3)
    currentBootstrap = testnet.bootstrap
    t.after(() => testnet.destroy().catch(() => {}))

    const inviter = bootWorklet()
    const acceptor = bootWorklet()

    const createRes = await inviter.call(Method.PAIRING_CREATE_INVITE, {})
    assert.ok(createRes.ok, 'createInvite ok: ' + JSON.stringify(createRes.err))
    const { invite, inviteId } = createRes.ok

    const confirmKey = crypto.randomBytes(32)
    const acceptResPromise = acceptor.call(Method.PAIRING_ACCEPT_INVITE, { invite, timeoutMs: 10000 })
    const candidateEvent = await inviter.onEvent(
      (msg) => msg.ev === EventName.PAIRING_CANDIDATE && msg.p.inviteId === inviteId
    )
    await inviter.call(Method.PAIRING_CONFIRM_CANDIDATE, {
      inviteId,
      candidateId: candidateEvent.p.candidateId,
      key: confirmKey.toString('base64')
    })
    // No delay -- matches StartRoomScreen's own fire-and-forget timing
    // exactly (revoke() called synchronously right after confirm()
    // resolves, same tick as the navigation hand-off).
    await inviter.call(Method.PAIRING_REVOKE, { inviteId })

    const acceptRes = await acceptResPromise
    assert.ok(acceptRes.ok, 'acceptInvite must still succeed despite the immediate revoke: ' + JSON.stringify(acceptRes.err))
    assert.equal(
      acceptRes.ok.key,
      confirmKey.toString('base64'),
      'the accepting side must still receive the confirmed key, not be caught by the revoke'
    )
  })
