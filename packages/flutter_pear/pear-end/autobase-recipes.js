// E5.7 -- Autobase prebuilt merge recipes.
//
// LOCKED (project decision, "codex #2"): Autobase is multi-writer, and its
// `apply` handler runs once per linearized batch, potentially replayed many
// times as new causal information reorders the DAG (see Autobase's own
// README "Reordering" section) -- routing THAT through Dart, across the
// RPC boundary, on every reorder would be slow, reentrant, and a single
// dropped/slow Dart callback could stall every writer's merge. So instead
// of a generic Dart-driven open/apply, app devs pick one of the NAMED
// recipes below (see schema.dart's PearRecipe) and this module supplies
// both halves of the Autobase contract entirely in JS. A custom worklet
// with its own hand-written open/apply remains a documented advanced path
// (BareWorklet.start(customBundle)), never exposed through the default API.
//
// Every recipe also recognizes two shared, cross-cutting op shapes
// regardless of its own vocabulary: `{ addWriter: <hex-or-Buffer>, indexer }`
// (see Autobase's own README example) and `{ removeWriter: <hex-or-Buffer> }`
// -- how a writer joins or leaves an existing base; handled identically by
// all three so a caller never has to special-case it per recipe.
//
// apply() NEVER throws, by design -- verified live against the real
// autobase package (node_modules/autobase/lib/apply-state.js's non-
// optimistic apply call site has no try/catch, unlike its optimistic path)
// that an exception escaping apply() propagates to Autobase's own
// _onError(), which UNCONDITIONALLY closes the whole base -- and closing
// doesn't self-heal on restart, since a fresh Autobase replays the exact
// same stored, causally-final node and hits the identical throw again.
// That means one shape-invalid op from ANY writer (buggy or malicious)
// would permanently brick every replica that ever linearizes it -- a total,
// unrecoverable outage, which is a far worse failure mode than the
// "corruption" this ticket's own validation requirement ("malformed op ->
// typed error, not corruption") was written to prevent. So each recipe
// exposes its shape-checking as a separate `validate(value)` function that
// DOES throw a MALFORMED_OP-coded error (for a caller -- eventually
// PearBase.put/del, E5.8 -- to validate BEFORE ever appending, catching an
// app bug before it reaches the shared log at all) while `apply()` itself
// only ever SKIPS a node that fails validation (no view mutation, no
// host.addWriter call for it) and continues with the rest of the batch.
// A genuine storage/session failure from view.put()/view.append()/
// host.addWriter() -- as opposed to a data-shape problem with the op
// itself -- is NOT swallowed and propagates normally; unlike a malformed
// op, that's a real environmental failure, and stopping the base is the
// safer response to it (an analog of index.js's withStorageErrors exists
// at the RPC-handler layer, not here, since this module has no RPC
// boundary of its own yet -- E5.8's job).
'use strict'

const Hyperbee = require('hyperbee')
const { ErrorCode } = require('./schema')

// A factory, not index.js's usual inline `new Error(...); err.code = ...;
// throw err` three-liner repeated at each coded-throw site -- a deliberate
// departure, not an oversight: this file has ~15 call sites all throwing
// the exact same code with only the reason string varying (three recipes x
// several shape checks each), unlike index.js's throws, which are each
// paired with a different, one-off error code.
function malformedOp (reason) {
  const err = new Error('malformed Autobase op: ' + reason)
  err.code = ErrorCode.MALFORMED_OP
  return err
}

const HEX32_RE = /^[0-9a-f]{64}$/i
const TAG_RE = /^[0-9a-f]+:\d+$/i

function keyField (value, field) {
  const ok = Buffer.isBuffer(value[field])
    ? value[field].length === 32
    : typeof value[field] === 'string' && HEX32_RE.test(value[field])
  if (!ok) throw malformedOp(field + ' must be a 32-byte key, as a Buffer or 64-char hex string')
  return Buffer.isBuffer(value[field]) ? value[field] : Buffer.from(value[field], 'hex')
}

// Shared by every recipe -- see this module's own doc comment above. Throws
// malformedOp on a bad key shape -- the caller (processNode below) is what
// decides whether that's swallowed.
function validateAddWriter (value) {
  keyField(value, 'addWriter')
}

function validateRemoveWriter (value) {
  keyField(value, 'removeWriter')
}

// Returns true if `value` was an addWriter/removeWriter directive (and was
// handled), false if the caller should go on to interpret `value` as its
// own recipe-specific op.
async function handleWriterOp (value, host) {
  if (value == null || typeof value !== 'object') return false
  if (value.addWriter != null) {
    const key = keyField(value, 'addWriter')
    await host.addWriter(key, { indexer: value.indexer !== false })
    return true
  }
  if (value.removeWriter != null) {
    const key = keyField(value, 'removeWriter')
    // Autobase itself refuses to remove the last remaining indexer (throws
    // an uncoded Error) -- a genuine operational constraint, not a shape
    // problem with this op, so it's deliberately NOT treated as
    // MALFORMED_OP and propagates like any other host-call failure (see
    // processNode's doc). index.js registers a base.on('error', ...)
    // listener specifically so this closes just the one base instead of
    // crashing the whole worklet (Autobase's default with no listener).
    await host.removeWriter(key)
    return true
  }
  return false
}

// Runs `handleOp(node)` for one node, after first trying handleWriterOp --
// see this module's top doc comment for why a MALFORMED_OP-coded throw is
// swallowed (skip this node, view untouched) while anything else propagates.
async function processNode (node, host, handleOp) {
  if (node.value == null) return // an ack node -- nothing to apply
  try {
    if (await handleWriterOp(node.value, host)) return
    await handleOp(node)
  } catch (err) {
    if (err && err.code === ErrorCode.MALFORMED_OP) return
    throw err
  }
}

// A tiebreak comparator used ONLY by crdtMap below, to pick a single
// canonical representative among a set of already-CONVERGED, still-live
// concurrent adds (see crdtMap's own doc comment) -- higher writer-local
// sequence number wins; a genuine tie (two different writers' unrelated
// concurrent ops landing at the same seq) breaks on the writer's own public
// key, greater hex string wins. Both fields come straight from Autobase's
// own per-node identity (node.from.key / node.length).
//
// IMPORTANT: this is NOT a substitute for Autobase's own causal/canonical
// ordering, and must never be used to decide "did op A really happen after
// op B" across writers -- two different writers' local sequence counters
// are independent scales (writer B's 3rd write isn't "later" than writer
// A's 5th write just because 5 > 3). It's only safe here because both sides
// apply it to the IDENTICAL final survivor set after full convergence, so
// any fixed rule over that set agrees everywhere -- it answers "which one do
// we canonically pick", never "which one happened later".
function isNewer (a, b) {
  if (a.seq !== b.seq) return a.seq > b.seq
  return a.writer > b.writer
}

// ---------------------------------------------------------------------------
// Recipe 1: last-writer-wins map. key -> value; "latest" means whichever op
// apply() is handed LAST for that key -- which is exactly Autobase's own
// deterministic causal linearization, not a comparator this module layers
// on top (an earlier draft tried comparing writer-local seq numbers across
// writers directly and got it wrong -- see isNewer's doc above for why that
// doesn't work). A plain, unconditional overwrite is correct BECAUSE
// Autobase guarantees the same causal graph state always linearizes to the
// same node order on every replica, and safely replayable on reorder: a
// truncate-and-reapply from an earlier checkpoint just re-runs the same
// unconditional overwrites in the (possibly corrected) canonical order.
// ---------------------------------------------------------------------------
const lww = {
  open (store) {
    return new Hyperbee(store.get('lww'), { keyEncoding: 'binary', valueEncoding: 'json' })
  },

  // Throws malformedOp on a shape this recipe can't interpret. Exported so a
  // caller can validate BEFORE appending (see this module's top doc
  // comment) -- apply() below also calls this, but only ever skips a node
  // that fails it, never throws further.
  validate (value) {
    const { type, key } = value
    if (typeof key !== 'string') throw malformedOp('lww op missing a base64 string key')
    if (type !== 'put' && type !== 'del') {
      throw malformedOp('lww op type must be put or del, got ' + JSON.stringify(type))
    }
    if (type === 'put' && typeof value.value !== 'string') {
      throw malformedOp('lww put missing a base64 string value')
    }
  },

  async apply (nodes, view, host) {
    for (const node of nodes) {
      await processNode(node, host, async () => {
        lww.validate(node.value)
        const { type, key, value } = node.value
        const keyBuf = Buffer.from(key, 'base64')
        if (type === 'put') {
          await view.put(keyBuf, { deleted: false, value })
        } else {
          await view.put(keyBuf, { deleted: true, value: null })
        }
      })
    }
  },

  // Materializes the current value for `key` (base64), or {exists:false} if
  // never put or the latest write was a del.
  async get (view, key) {
    const entry = await view.get(Buffer.from(key, 'base64'))
    if (!entry || entry.value.deleted) return { exists: false }
    return { exists: true, value: entry.value.value }
  },

  // The underlying hypercore(s) whose 'append' event means "this view
  // changed" -- index.js's BASE_WATCH listens on these generically, without
  // needing to know each recipe's internal view shape (a Hyperbee wraps its
  // core in `.core`; crdtMap needs two; orderedLog's view IS the core).
  viewCores (view) {
    return [view.core]
  }
}

// ---------------------------------------------------------------------------
// Recipe 2: ordered-log. An append-only merged log -- every writer's entries
// interleaved into ONE order. Deterministic because it's exactly Autobase's
// own causal linearization (see the README's "Ordering" section): no extra
// recipe-level sort/tiebreak layered on top, which is also why this is safe
// to replay on reorder -- Autobase itself truncates and rebuilds this view
// from the reordering checkpoint forward, this recipe just has to append in
// whatever order it's handed for that segment.
// ---------------------------------------------------------------------------
const orderedLog = {
  open (store) {
    return store.get('orderedLog', { valueEncoding: 'binary' })
  },

  validate (value) {
    if (typeof value.entry !== 'string') throw malformedOp('orderedLog op missing a base64 string entry')
  },

  async apply (nodes, view, host) {
    for (const node of nodes) {
      await processNode(node, host, async () => {
        orderedLog.validate(node.value)
        await view.append(Buffer.from(node.value.entry, 'base64'))
      })
    }
  },

  // See lww's viewCores doc -- orderedLog's view IS the hypercore directly
  // (no `.core` indirection).
  viewCores (view) {
    return [view]
  }
}

// ---------------------------------------------------------------------------
// Recipe 3: crdt-map. An ADD-WINS OBSERVED-REMOVE MAP (an OR-Set of
// (tag, value) pairs per key, materialized to one scalar value) -- naming
// the exact variant per this ticket's own instruction, since "CRDT" alone
// underspecifies concurrent add/remove resolution:
//
// - Every put is tagged with a globally unique, content-derived tag
//   (writerHex:seq, straight from Autobase's own node identity -- callers
//   never generate or exchange a tag themselves).
// - A del names the exact tags it OBSERVED for that key at delete time --
//   it removes only those, so a put the deleter never saw survives
//   (add-wins: a concurrent, not-yet-observed put beats a delete). A caller
//   never has to compute this list itself: normalizeAppend below fills in
//   `removes` from the appending peer's OWN current view right before the
//   op is appended (see its own doc for why this is still correct/observed
//   -- not just convenient).
// - A tombstone (removed tag) is permanent and checked before ANY future put
//   using that same tag is allowed to resurrect it -- a defensive guard for
//   the (should-be-impossible, per Autobase's causal ordering guarantee) case
//   of a del's node being replayed before the put whose tag it references.
// - Multiple SURVIVING concurrent adds to the same key (nobody deleted
//   either) resolve to one scalar view value via the same (seq, writer)
//   tiebreak as the lww recipe above.
//
// Two named sub-views (Autobase supports "one or more" cores per view, see
// its README) rather than one Hyperbee with hand-rolled key-prefixing --
// avoids any prefix-boundary ambiguity between an arbitrary-bytes app key
// and a tag suffix.
// ---------------------------------------------------------------------------
const crdtMap = {
  open (store) {
    return {
      adds: new Hyperbee(store.get('crdtMap-adds'), { keyEncoding: 'binary', valueEncoding: 'json' }),
      tombs: new Hyperbee(store.get('crdtMap-tombs'), { keyEncoding: 'binary', valueEncoding: 'json' })
    }
  },

  // Optional hook index.js's BASE_APPEND calls (if a recipe defines it)
  // BEFORE base.append(), on the LOCAL view of whichever peer is making
  // this call. Fills in a bare `{type:'del', key}`'s `removes` from that
  // peer's own currently-observed tags for `key`, so a caller (PearBase.del,
  // E5.8) never has to read tags itself just to construct a legal del --
  // this is still "observed remove" in the CRDT sense (not a shortcut that
  // weakens it): `removes` is computed from and travels with THIS peer's
  // own current view at append time, identically to what a caller reading
  // tagsFor() itself and passing the result back would produce. A del that
  // ALREADY specifies `removes` (e.g. a future caller with its own reason
  // to name specific tags) is left untouched.
  async normalizeAppend (view, value) {
    if (value && value.type === 'del' && value.removes == null && typeof value.key === 'string') {
      value = { ...value, removes: Object.keys(await crdtMap.tagsFor(view, value.key)) }
    }
    return value
  },

  validate (value) {
    const { type, key } = value
    if (typeof key !== 'string') throw malformedOp('crdtMap op missing a base64 string key')
    if (type === 'put') {
      if (typeof value.value !== 'string') throw malformedOp('crdtMap put missing a base64 string value')
    } else if (type === 'del') {
      if (!Array.isArray(value.removes)) throw malformedOp('crdtMap del missing a removes array')
      for (const tag of value.removes) {
        if (typeof tag !== 'string' || !TAG_RE.test(tag)) {
          throw malformedOp('crdtMap del: every removes entry must be a writerHex:seq tag, got ' + JSON.stringify(tag))
        }
      }
    } else {
      throw malformedOp('crdtMap op type must be put or del, got ' + JSON.stringify(type))
    }
  },

  async apply (nodes, view, host) {
    for (const node of nodes) {
      await processNode(node, host, async () => {
        crdtMap.validate(node.value)
        const { type, key } = node.value
        if (type === 'put') await applyPut(view, key, node)
        else await applyDel(view, key, node.value.removes)
      })
    }
  },

  // The tags currently live for `key` (base64), as {tag: valueBase64} --
  // the caller (eventually PearBase's del(), E5.8) reads this BEFORE
  // appending a del op, and passes Object.keys(...) back as `removes`. That
  // read-then-write is what "observed remove" means: you can only remove
  // what you've actually seen.
  async tagsFor (view, key) {
    const entry = await view.adds.get(Buffer.from(key, 'base64'))
    return entry ? entry.value.tags : {}
  },

  // Materializes the single scalar value currently visible for `key`
  // (base64), or {exists:false} if every add-tag was removed or none ever
  // existed.
  async get (view, key) {
    const tags = await crdtMap.tagsFor(view, key)
    let winnerTag = null
    let winnerValue = null
    for (const [tag, value] of Object.entries(tags)) {
      if (winnerTag !== null && !isNewer(parseTag(tag), parseTag(winnerTag))) continue
      winnerTag = tag
      winnerValue = value
    }
    return winnerTag === null ? { exists: false } : { exists: true, value: winnerValue }
  },

  // See lww's viewCores doc -- crdtMap's view is a {adds, tombs} pair, so
  // either Hyperbee changing counts as "this view changed".
  viewCores (view) {
    return [view.adds.core, view.tombs.core]
  }
}

function parseTag (tag) {
  const sep = tag.lastIndexOf(':')
  return { writer: tag.slice(0, sep), seq: Number(tag.slice(sep + 1)) }
}

async function applyPut (view, key, node) {
  const tag = node.from.key.toString('hex') + ':' + node.length
  if (await view.tombs.get(Buffer.from(tag))) return // already observed-removed (reorg edge case) -- never resurrect

  const keyBuf = Buffer.from(key, 'base64')
  const existing = await view.adds.get(keyBuf)
  const tags = existing ? { ...existing.value.tags } : {}
  tags[tag] = node.value.value
  await view.adds.put(keyBuf, { tags })
}

async function applyDel (view, key, removes) {
  const keyBuf = Buffer.from(key, 'base64')
  const existing = await view.adds.get(keyBuf)
  const tags = existing ? { ...existing.value.tags } : {}

  for (const tag of removes) {
    delete tags[tag]
    await view.tombs.put(Buffer.from(tag), true)
  }

  if (Object.keys(tags).length > 0) await view.adds.put(keyBuf, { tags })
  else await view.adds.del(keyBuf)
}

module.exports = { RECIPES: { lww, orderedLog, crdtMap }, malformedOp, validateAddWriter, validateRemoveWriter }
