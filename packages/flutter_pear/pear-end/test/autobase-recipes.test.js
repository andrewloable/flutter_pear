// JS-level determinism tests for the E5.7 Autobase recipes (node, no
// device -- see flutter_pear-2vz.7's own VALIDATION). Run directly with
// Node's built-in test runner: `node --test pear-end/test/`.
'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')

const Corestore = require('corestore')
const Autobase = require('autobase')

const { RECIPES, malformedOp, validateAddWriter, validateRemoveWriter } = require('../autobase-recipes')

// Every tmpDir() this file creates is tracked here and removed by the
// top-level after() hook below, regardless of which tests passed or
// failed -- otherwise a thrown assertion mid-test (which skips a test's own
// cleanup lines) leaks real directories on disk forever (E5.7 review fix).
const tmpDirs = []
function tmpDir () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-autobase-test-'))
  tmpDirs.push(dir)
  return dir
}

test.after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

async function createBases (n, recipe) {
  const stores = []
  for (let i = 0; i < n; i++) stores.push(new Corestore(tmpDir()))

  const opts = { open: recipe.open, apply: recipe.apply, valueEncoding: 'json', ackInterval: 0, ackThreshold: 0 }

  const bases = [new Autobase(stores[0], null, opts)]
  await bases[0].ready()

  for (let i = 1; i < n; i++) {
    const base = new Autobase(stores[i], bases[0].local.key, opts)
    await base.ready()
    bases.push(base)
  }

  return bases
}

function tick () {
  return new Promise((resolve) => setImmediate(resolve))
}

// Pipes every pair of bases' replicate() streams together, then drives
// update() for a fixed number of rounds. A round-count heuristic rather
// than a real fixed-point check: tried detecting convergence via "system
// core length stable for N consecutive rounds" and found (empirically,
// logging round-by-round) that this system has long, GENUINELY-stable-
// looking plateaus -- e.g. 10 rounds of no visible change -- before a piped
// stream's async I/O actually starts delivering data at all, so a short
// stability window declares victory before anything has even started
// syncing. `rounds` is deliberately generous (2-3x the largest round count
// actually observed to matter for this suite's 2-writer, tiny-payload
// scenarios) rather than clever -- a future test adding a 3rd writer or
// much larger payloads should pass a bigger `rounds` explicitly rather than
// relying on this default (E5.7 review: a bare fixed count doesn't scale on
// its own, but neither did the "smarter" alternative actually tried here).
async function replicateAndSync (bases, { rounds = 60 } = {}) {
  const streams = []
  for (let i = 0; i < bases.length; i++) {
    for (let j = i + 1; j < bases.length; j++) {
      const a = bases[i].replicate(true)
      const b = bases[j].replicate(false)
      a.pipe(b).pipe(a)
      streams.push(a, b)
    }
  }

  for (let round = 0; round < rounds; round++) {
    await tick()
    for (const base of bases) await base.update()
  }

  await Promise.all(streams.map((s) => new Promise((resolve) => {
    s.destroy()
    s.on('close', resolve)
  })))
}

async function addWriterAndSync (fromBase, newBase, bases) {
  await fromBase.append({ addWriter: newBase.local.key.toString('hex') })
  await replicateAndSync(bases)
  if (fromBase.ackable) await fromBase.append(null) // manual ack (ackInterval disabled above) -- see Autobase's README "ack"
  await replicateAndSync(bases)
}

async function closeAll (bases) {
  await Promise.all(bases.map((b) => b.close()))
}

// recipe.open() expects Autobase's own internal view-store (which tracks
// each store.get() call for checkpoint/rewind), not a bare Corestore -- a
// bare Corestore's .get() interprets a plain string as a hex key to decode,
// not a view name, and throws. A solo (single-writer) Autobase is the
// simplest real view-store available for tests that only need to call
// apply() directly without a second peer.
async function soloBase (recipe) {
  const base = new Autobase(new Corestore(tmpDir()), null, { open: recipe.open, apply: recipe.apply, valueEncoding: 'json' })
  await base.ready()
  return base
}

// Every convergence test below registers this immediately after creating
// its bases, via t.after() -- not a plain call at the test's final line --
// so an assertion failure partway through still closes the underlying
// Autobase/Corestore instances instead of leaking them (E5.7 review fix).
function closeOnTeardown (t, bases) {
  t.after(() => closeAll(bases))
}

function b64 (s) {
  return Buffer.from(s).toString('base64')
}

// A minimal apply() call bypassing real Autobase entirely -- used only by
// the recipe.validate() tests below, which want to assert the recipe's OWN
// shape-checking throws, without needing a full Autobase/Corestore
// instance just to construct one bad node.
function fakeNode (value, { writer = 'aa', seq = 0 } = {}) {
  return { value, from: { key: Buffer.from(writer, 'hex') }, length: seq }
}

const noopHost = { addWriter: async () => {} }

function assertMalformed (fn) {
  assert.throws(fn, (err) => err.code === malformedOp('x').code)
}

test('lww: two writers racing the same key converge to the identical winner on both sides', async (t) => {
  const [a, b] = await createBases(2, RECIPES.lww)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  // Fully concurrent: neither has replicated the other's write yet.
  await a.append({ type: 'put', key: b64('color'), value: b64('red') })
  await b.append({ type: 'put', key: b64('color'), value: b64('blue') })
  await replicateAndSync([a, b])

  const winnerA = await RECIPES.lww.get(a.view, b64('color'))
  const winnerB = await RECIPES.lww.get(b.view, b64('color'))
  assert.deepEqual(winnerA, winnerB)
  assert.equal(winnerA.exists, true)

  // A causally-later write (made only after fully syncing) must win.
  await a.append({ type: 'put', key: b64('shape'), value: b64('square') })
  await replicateAndSync([a, b])
  await b.append({ type: 'put', key: b64('shape'), value: b64('circle') })
  await replicateAndSync([a, b])

  assert.deepEqual(await RECIPES.lww.get(a.view, b64('shape')), { exists: true, value: b64('circle') })
  assert.deepEqual(await RECIPES.lww.get(b.view, b64('shape')), { exists: true, value: b64('circle') })

  // A del beats an earlier, now-stale put.
  await a.append({ type: 'del', key: b64('shape') })
  await replicateAndSync([a, b])
  assert.deepEqual(await RECIPES.lww.get(a.view, b64('shape')), { exists: false })
  assert.deepEqual(await RECIPES.lww.get(b.view, b64('shape')), { exists: false })
})

test('lww: the SAME concurrent race, with the two appends made in the opposite ' +
  'code order, still converges to one agreed winner (arrival order shouldn\'t matter)', async (t) => {
  const [a, b] = await createBases(2, RECIPES.lww)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  // Same fully-concurrent race as the test above, but B's append executes
  // first in this test's own code order -- a correct implementation must
  // not care which side happened to run its .append() call first in either
  // test, only Autobase's own causal linearization.
  await b.append({ type: 'put', key: b64('color'), value: b64('blue') })
  await a.append({ type: 'put', key: b64('color'), value: b64('red') })
  await replicateAndSync([a, b])

  const winnerA = await RECIPES.lww.get(a.view, b64('color'))
  const winnerB = await RECIPES.lww.get(b.view, b64('color'))
  assert.deepEqual(winnerA, winnerB)
  assert.equal(winnerA.exists, true)
})

test('lww: apply() never crashes/closes the base on a malformed op from a peer -- ' +
  'it is skipped, and later valid ops from the SAME batch still apply', async (t) => {
  // apply() runs independently, locally, on EVERY replica that linearizes a
  // node -- A doesn't need a special "buggy peer" stand-in to prove this:
  // A itself running the real recipe already skips its own malformed
  // append when IT applies it, and B, on replicating the identical node,
  // independently does the same. No permissive/stand-in apply needed.
  const [a, b] = await createBases(2, RECIPES.lww)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  await a.append({ type: 'bogus-op-shape' }) // malformed -- no `key`/`type` lww understands
  await a.append({ type: 'put', key: b64('ok'), value: b64('still-works') })
  await replicateAndSync([a, b])

  let closed = false
  b.once('close', () => { closed = true })
  await tick()
  assert.equal(closed, false, 'a malformed op must not close the base')
  assert.deepEqual(await RECIPES.lww.get(a.view, b64('ok')), { exists: true, value: b64('still-works') })
  assert.deepEqual(await RECIPES.lww.get(b.view, b64('ok')), { exists: true, value: b64('still-works') })
})

test('lww: validate() rejects a malformed op with MALFORMED_OP', () => {
  assertMalformed(() => RECIPES.lww.validate({ type: 'put', key: 123 }))
  assertMalformed(() => RECIPES.lww.validate({ type: 'bogus', key: b64('k') }))
  assertMalformed(() => RECIPES.lww.validate({ type: 'put', key: b64('k'), value: 42 }))
})

test('orderedLog: two writers interleaving entries converge to the identical merged order on both sides', async (t) => {
  const [a, b] = await createBases(2, RECIPES.orderedLog)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  await a.append({ entry: b64('a0') })
  await b.append({ entry: b64('b0') })
  await replicateAndSync([a, b])
  await a.append({ entry: b64('a1') })
  await b.append({ entry: b64('b1') })
  await replicateAndSync([a, b])

  // Exact length + exact content set (not just ">= 4" and "A mirrors B") --
  // a symmetric duplication bug (e.g. a reorder replay double-appending)
  // would affect both replicas identically and slip past a weaker A-vs-B-
  // only check (E5.7 review fix).
  assert.equal(a.view.length, 4)
  assert.equal(b.view.length, 4)
  const entriesA = []
  for (let i = 0; i < a.view.length; i++) entriesA.push((await a.view.get(i)).toString('base64'))
  const entriesB = []
  for (let i = 0; i < b.view.length; i++) entriesB.push((await b.view.get(i)).toString('base64'))
  assert.deepEqual(entriesA, entriesB)
  assert.deepEqual(new Set(entriesA), new Set([b64('a0'), b64('b0'), b64('a1'), b64('b1')]))
})

test('orderedLog: apply() never crashes/closes the base on a malformed op -- it is skipped', async (t) => {
  const [a, b] = await createBases(2, RECIPES.orderedLog)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  await a.append({ notAnEntry: true })
  await a.append({ entry: b64('still-works') })
  await replicateAndSync([a, b])

  assert.equal(a.view.length, 1)
  assert.equal(b.view.length, 1)
  assert.equal((await b.view.get(0)).toString('base64'), b64('still-works'))
})

test('orderedLog: validate() rejects a malformed op with MALFORMED_OP', () => {
  assertMalformed(() => RECIPES.orderedLog.validate({ entry: 42 }))
  assertMalformed(() => RECIPES.orderedLog.validate({}))
})

test('crdtMap: a concurrent, not-yet-observed put survives a delete (add wins)', async (t) => {
  const [a, b] = await createBases(2, RECIPES.crdtMap)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  // A puts 'x', both sync so B has observed it.
  await a.append({ type: 'put', key: b64('x'), value: b64('from-a') })
  await replicateAndSync([a, b])

  // Concurrently: A deletes what it observed (its own put) while B, at the
  // SAME time, adds a second value for 'x' that A hasn't seen yet.
  const tagsBeforeDelete = Object.keys(await RECIPES.crdtMap.tagsFor(a.view, b64('x')))
  await a.append({ type: 'del', key: b64('x'), removes: tagsBeforeDelete })
  await b.append({ type: 'put', key: b64('x'), value: b64('from-b') })
  await replicateAndSync([a, b])

  // B's put was never in A's removes list (A couldn't have observed it), so
  // it survives on both sides -- this is the CRDT property distinguishing
  // this recipe from plain lww, where the later op would just clobber.
  const resultA = await RECIPES.crdtMap.get(a.view, b64('x'))
  const resultB = await RECIPES.crdtMap.get(b.view, b64('x'))
  assert.deepEqual(resultA, resultB)
  assert.deepEqual(resultA, { exists: true, value: b64('from-b') })
})

test('crdtMap: deleting every observed tag converges to not-exists on both sides', async (t) => {
  const [a, b] = await createBases(2, RECIPES.crdtMap)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  await a.append({ type: 'put', key: b64('y'), value: b64('only-value') })
  await replicateAndSync([a, b])

  const tags = Object.keys(await RECIPES.crdtMap.tagsFor(b.view, b64('y')))
  await b.append({ type: 'del', key: b64('y'), removes: tags })
  await replicateAndSync([a, b])

  assert.deepEqual(await RECIPES.crdtMap.get(a.view, b64('y')), { exists: false })
  assert.deepEqual(await RECIPES.crdtMap.get(b.view, b64('y')), { exists: false })
})

test('crdtMap: two fully-concurrent surviving puts to the same key (neither ever ' +
  'deleted) resolve to the identical canonical winner on both sides -- exercises ' +
  'the isNewer tiebreak the other tests never reach', async (t) => {
  const [a, b] = await createBases(2, RECIPES.crdtMap)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  // Fully concurrent -- neither observes the other's put, and nobody ever
  // deletes either one, so BOTH tags survive and get() must pick a single
  // canonical winner via isNewer.
  await a.append({ type: 'put', key: b64('z'), value: b64('from-a') })
  await b.append({ type: 'put', key: b64('z'), value: b64('from-b') })
  await replicateAndSync([a, b])

  const tagsA = await RECIPES.crdtMap.tagsFor(a.view, b64('z'))
  const tagsB = await RECIPES.crdtMap.tagsFor(b.view, b64('z'))
  assert.equal(Object.keys(tagsA).length, 2, 'both concurrent adds must survive')
  assert.deepEqual(tagsA, tagsB)

  const winnerA = await RECIPES.crdtMap.get(a.view, b64('z'))
  const winnerB = await RECIPES.crdtMap.get(b.view, b64('z'))
  assert.deepEqual(winnerA, winnerB)
  assert.equal(winnerA.exists, true)
})

test('crdtMap: apply() never crashes/closes the base on a malformed op -- it is skipped', async (t) => {
  const [a, b] = await createBases(2, RECIPES.crdtMap)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  await a.append({ type: 'del', key: b64('k'), removes: ['not-a-real-tag'] }) // wrong tag encoding -- malformed
  await a.append({ type: 'put', key: b64('k'), value: b64('still-works') })
  await replicateAndSync([a, b])

  assert.deepEqual(await RECIPES.crdtMap.get(a.view, b64('k')), { exists: true, value: b64('still-works') })
  assert.deepEqual(await RECIPES.crdtMap.get(b.view, b64('k')), { exists: true, value: b64('still-works') })
})

test('crdtMap: normalizeAppend fills in removes from the current view -- a caller ' +
  'never has to read tags itself just to construct a legal del', async (t) => {
  const base = await soloBase(RECIPES.crdtMap)
  t.after(() => base.close())

  await base.append({ type: 'put', key: b64('k'), value: b64('v') })
  for (let i = 0; i < 20 && Object.keys(await RECIPES.crdtMap.tagsFor(base.view, b64('k'))).length === 0; i++) await tick()

  const bareDel = { type: 'del', key: b64('k') }
  const normalized = await RECIPES.crdtMap.normalizeAppend(base.view, bareDel)
  const expectedTags = Object.keys(await RECIPES.crdtMap.tagsFor(base.view, b64('k')))
  assert.deepEqual(normalized.removes, expectedTags)
  assert.ok(expectedTags.length > 0, 'the put must have actually landed a tag to remove')

  // An explicit removes is left untouched, even if it doesn't match reality
  // -- normalizeAppend only FILLS IN a missing removes, it never overrides
  // a caller's own explicit choice.
  const explicit = { type: 'del', key: b64('k'), removes: ['already-decided:0'] }
  assert.deepEqual(await RECIPES.crdtMap.normalizeAppend(base.view, explicit), explicit)
})

test('crdtMap: validate() rejects a malformed op with MALFORMED_OP', () => {
  assertMalformed(() => RECIPES.crdtMap.validate({ type: 'put', key: 123 }))
  assertMalformed(() => RECIPES.crdtMap.validate({ type: 'put', key: b64('k'), value: 42 }))
  assertMalformed(() => RECIPES.crdtMap.validate({ type: 'del', key: b64('k'), removes: 'not-an-array' }))
  assertMalformed(() => RECIPES.crdtMap.validate({ type: 'del', key: b64('k'), removes: [42] }))
  assertMalformed(() => RECIPES.crdtMap.validate({ type: 'del', key: b64('k'), removes: ['not-a-real-tag'] }))
  assertMalformed(() => RECIPES.crdtMap.validate({ type: 'bogus', key: b64('k') }))
})

test('addWriter: validateAddWriter rejects a malformed shape (wrong type, non-hex, wrong length)', () => {
  assertMalformed(() => validateAddWriter({ addWriter: 12345 }))
  assertMalformed(() => validateAddWriter({ addWriter: 'nothex!!' }))
  assertMalformed(() => validateAddWriter({ addWriter: 'aa' })) // valid hex, wrong length (needs 32 bytes)
})

test('addWriter: apply() never crashes/closes the base on a malformed addWriter op -- it is skipped', async (t) => {
  // Shared across all three recipes -- lww stands in for all of them here.
  const base = await soloBase(RECIPES.lww)
  t.after(() => base.close())

  await RECIPES.lww.apply([fakeNode({ addWriter: 12345 })], base.view, noopHost)
  await RECIPES.lww.apply([fakeNode({ addWriter: 'nothex!!' })], base.view, noopHost)
  await RECIPES.lww.apply([fakeNode({ addWriter: 'aa' })], base.view, noopHost)
})

test('removeWriter: validateRemoveWriter rejects a malformed shape (wrong type, non-hex, wrong length)', () => {
  assertMalformed(() => validateRemoveWriter({ removeWriter: 12345 }))
  assertMalformed(() => validateRemoveWriter({ removeWriter: 'nothex!!' }))
  assertMalformed(() => validateRemoveWriter({ removeWriter: 'aa' }))
})

test('removeWriter: apply() never crashes/closes the base on a malformed removeWriter op -- it is skipped', async (t) => {
  const base = await soloBase(RECIPES.lww)
  t.after(() => base.close())

  await RECIPES.lww.apply([fakeNode({ removeWriter: 12345 })], base.view, noopHost)
  await RECIPES.lww.apply([fakeNode({ removeWriter: 'nothex!!' })], base.view, noopHost)
  await RECIPES.lww.apply([fakeNode({ removeWriter: 'aa' })], base.view, noopHost)
})

test('removeWriter: a writer removed via a real Autobase can no longer append -- ' +
  'and the recipe still converges to the same view on both sides', async (t) => {
  const [a, b] = await createBases(2, RECIPES.lww)
  closeOnTeardown(t, [a, b])
  await addWriterAndSync(a, b, [a, b])

  await b.append({ type: 'put', key: b64('before'), value: b64('ok') })
  await replicateAndSync([a, b])

  await a.append({ removeWriter: b.local.key.toString('hex') })
  await replicateAndSync([a, b])
  if (a.ackable) await a.append(null)
  await replicateAndSync([a, b])

  assert.equal(b.writable, false)
  assert.deepEqual(await RECIPES.lww.get(a.view, b64('before')), { exists: true, value: b64('ok') })
  assert.deepEqual(await RECIPES.lww.get(b.view, b64('before')), { exists: true, value: b64('ok') })
})
