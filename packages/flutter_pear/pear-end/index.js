// pear-end — the JavaScript that runs inside the Bare worklet.
//
// Dart never sees this: it ships prebuilt (via `dart run flutter_pear:pack`,
// which wraps bare-pack) and is driven entirely over the RPC schema below.
//
// E4.4: implements the full E2 schema for real -- dynamic, Dart-driven
// topic join/leave (replacing the E1/E1.4 gate's one hardcoded topic) plus
// the file-path bulk seam (codex #4 LOCKED).
//
// Every IPC frame is a 1-byte FrameType discriminator followed by a body
// (mirrors flutter_pear/lib/src/rpc.dart). For FrameType.JSON the body is
// one UTF-8 JSON object:
//   in : {"id","m","p"}                 request
//   out: {"id","ok"} | {"id","err"}     response
//   out: {"ev","p"}                     event
/* global BareKit, Bare */
'use strict'

const { IPC } = BareKit
const Hyperswarm = require('hyperswarm')
const Corestore = require('corestore')
const Hyperbee = require('hyperbee')
const Hyperdrive = require('hyperdrive')
const Localdrive = require('localdrive')
const Autobase = require('autobase')
const { RECIPES, validateAddWriter, validateRemoveWriter } = require('./autobase-recipes')
const BlindPairing = require('blind-pairing')
const Protomux = require('protomux')
const c = require('compact-encoding')
const crypto = require('hypercore-crypto')
const fs = require('bare-fs')
const path = require('bare-path')
const { pipelinePromise } = require('streamx')
const { Method, EventName, ErrorCode, SwarmState, FrameType, HandshakeField } = require('./schema')

// Identifies this worklet process/generation. Generated once at boot, never
// changes for as long as this worklet stays alive (which may span several
// Dart hot restarts -- see attach.info below).
const SESSION_NONCE = crypto.randomBytes(16).toString('hex')
// Baked in at pack time (see pack.dart's writeBundleVersion) from a hash of
// this file + schema.js -- changes automatically whenever either does.
const BUNDLE_VERSION = require('./version')

function send (obj) {
  // Every frame this side sends carries the session nonce (E2.5 LOCKED:
  // envelope-level, not nested in `p`) so Dart can drop anything from a
  // worklet generation it has since killed or replaced -- including a
  // frame already in flight when the kill happened, which alone wouldn't
  // otherwise be caught.
  const stamped = { ...obj, [HandshakeField.ENVELOPE_NONCE]: SESSION_NONCE }
  const body = Buffer.from(JSON.stringify(stamped))
  writeFramed(Buffer.concat([Buffer.from([FrameType.JSON]), body]))
}

// E4.4 fix: IPC.write() is a byte stream, not a message queue -- nothing
// guarantees one write() arrives as exactly one delivery on the Dart side
// (bare_worklet.dart's _onIpc). Confirmed with a burst of 5 back-to-back
// diagnostic() sends during E4.4's real Hyperswarm join work (the first
// traffic pattern dense enough to ever trigger it): frames coalesced into
// one delivery, and jsonDecode failed on the mashed-together bytes. A
// 4-byte big-endian length prefix (mirrored by bare_worklet.dart's own
// send/_onIpc) lets the receiver always find the true frame boundary
// regardless of how the transport chunks or coalesces the underlying bytes.
function writeFramed (frame) {
  const lengthPrefix = Buffer.alloc(4)
  lengthPrefix.writeUInt32BE(frame.length, 0)
  IPC.write(Buffer.concat([lengthPrefix, frame]))
}

function diagnostic (reason, extra) {
  send({ ev: EventName.RPC_DIAGNOSTIC, p: { reason, ...extra } })
}

// E2.6 LOCKED: an uncaught exception or unhandled rejection would otherwise
// abort this worklet's whole host process with zero warning to Dart (bare's
// documented default). Bare.on(...) overrides that default, so instead of a
// silent abort, self-report over the existing IPC/event pipe -- reaching
// this handler means send() and the rest of the module already loaded fine,
// which covers the overwhelming majority of realistic crashes (anything
// after the first few lines of this file). A crash too early for even
// THIS handler to run (predates Bare.on registration, or the process is
// killed at the OS level) is exactly what FlutterPearBarePlugin.kt's
// IPC-closed-unexpectedly backstop (WorkletIpc.onCrash) exists for --
// see that file's relayFromWorklet.
function reportCrash (kind, err) {
  try {
    send({
      ev: EventName.WORKLET_CRASH,
      p: {
        kind,
        message: String((err && err.message) || err),
        stack: err && err.stack
      }
    })
  } catch (_) {
    // Best-effort: if send() itself is what's broken, there's nothing more
    // this handler can do -- falling through to Bare.exit() below still
    // gives the native side its IPC-closed backstop signal.
  }
  // Deliberately exit rather than let execution continue: an uncaught
  // exception means something is in an unknown state, and Bare's own
  // default (abort) reflects that continuing is unsafe. This just makes
  // the exit reportable first instead of an opaque abort.
  Bare.exit(1)
}

Bare.on('uncaughtException', (err) => reportCrash('uncaughtException', err))
Bare.on('unhandledRejection', (reason) => reportCrash('unhandledRejection', reason))

const swarm = new Hyperswarm()
const connections = new Map() // peer public key (hex) -> connection, shared across topics
// peer hex -> Protomux message sender for Method.CONNECTION_WRITE -- see the
// Protomux.from(conn) comment in swarm.on('connection', ...) below for why
// this can't just be conn.write() directly once BlindPairing (E5.6) is in
// the picture.
const connectionChannels = new Map()

// E5.6 -- blind-pairing wrapper (PearPairing). Reuses the SAME swarm every
// other capability shares (blind-pairing listens for its own 'connection'
// events on it, exactly like the swarm.on('connection', ...) below).
const pairing = new BlindPairing(swarm)

// Topics Dart has asked to join, by hex -- Hyperswarm itself tracks join
// state internally (per-topic PeerDiscovery in its own `_discovery` map);
// this is OUR bookkeeping for event routing and the E2.7 state machine, one
// entry per topic actually requested via Method.SWARM_JOIN below (E4.4:
// replaces the E1/E1.4 gate's single hardcoded topic).
const topics = new Map() // topic hex -> { connectedPeers: Set<peer hex>, everConnected: bool }

// E2.7: the PearSwarmState machine's wire side -- see swarm.dart's
// PearSwarmStatus/PearSwarmState for the Dart-side consumer.
function sendState (topicHex, state, reason) {
  send({ ev: EventName.SWARM_LIFECYCLE, p: { topic: topicHex, state, ...(reason ? { reason } : {}) } })
}

swarm.on('connection', (conn, info) => {
  const peer = info.publicKey.toString('hex')
  connections.set(peer, conn)

  // A peer can be discovered via more than one joined topic at once
  // (Hyperswarm shares one connection across every topic that found it) --
  // `info.topics` lists every topic seen SO FAR, and `info.on('topic', ...)`
  // fires for one discovered AFTER this connection already exists. Route
  // each associated, currently-joined topic its own swarm.connection +
  // CONNECTED transition; a topic nobody asked to join (not in `topics`) is
  // silently ignored here, same as everywhere else below.
  const announce = (topicBuf) => {
    const topicHex = topicBuf.toString('hex')
    const t = topics.get(topicHex)
    if (!t || t.connectedPeers.has(peer)) return
    t.connectedPeers.add(peer)
    t.everConnected = true
    send({ ev: EventName.SWARM_CONNECTION, p: { topic: topicHex, peer } })
    sendState(topicHex, SwarmState.CONNECTED)
  }
  for (const topicBuf of info.topics) announce(topicBuf)
  info.on('topic', announce)

  // Method.CONNECTION_DATA/CONNECTION_WRITE's raw app-data pass-through must
  // go through a Protomux channel, not conn.on('data')/conn.write()
  // directly (E5.6 review fix). BlindPairing wraps EVERY connection in a
  // Protomux instance the moment it connects (its own getMuxer, which does
  // `Protomux.from(stream)` and caches the result on `stream.userData`) --
  // a second, independent raw 'data' listener on that same stream sees
  // bytes Protomux's own framing doesn't recognize and destroys the whole
  // connection on the first parse failure (confirmed by tracing
  // protomux/index.js's _ondata -> _safeDestroy -> stream.destroy). Calling
  // Protomux.from(conn) here reuses that SAME shared instance (the
  // stream.userData cache works regardless of which side constructs it
  // first) instead of attaching a second, conflicting listener -- exactly
  // the pattern Hypercore's own replicate() uses to coexist with
  // BlindPairing on one connection.
  const mux = Protomux.from(conn)
  const channel = mux.createChannel({ protocol: 'pear-connection-data' })
  const message = channel.addMessage({
    encoding: c.buffer,
    onmessage (data) {
      const payload = data.toString('base64')
      for (const topicBuf of info.topics) {
        const topicHex = topicBuf.toString('hex')
        if (topics.has(topicHex)) {
          send({ ev: EventName.CONNECTION_DATA, p: { topic: topicHex, peer, data: payload } })
        }
      }
    }
  })
  channel.open()
  connectionChannels.set(peer, message)

  conn.on('close', () => {
    // Identity-checked: if `peer` already reconnected (a new `conn` for the
    // same public key raced this stale one's close), this is a stale
    // connection closing -- don't clear the live entry a newer
    // 'connection' event already installed, and don't tell Dart the
    // (still-live) peer disconnected.
    if (connections.get(peer) !== conn) return
    connections.delete(peer)
    connectionChannels.delete(peer)
    replicationStreams.delete(peer) // E5.2: the chained replicate() stream dies with its connection
    for (const topicBuf of info.topics) {
      const topicHex = topicBuf.toString('hex')
      const t = topics.get(topicHex)
      if (!t || !t.connectedPeers.has(peer)) continue
      t.connectedPeers.delete(peer)
      send({ ev: EventName.CONNECTION_CLOSE, p: { topic: topicHex, peer } })
      if (t.connectedPeers.size === 0) sendState(topicHex, SwarmState.RECONNECTING)
    }
  })
  // 'close' fires after 'error' regardless; nothing more to do here beyond
  // surfacing it as a diagnostic per associated topic.
  conn.on('error', (err) => {
    for (const topicBuf of info.topics) {
      send({ ev: EventName.SWARM_LIFECYCLE, p: { topic: topicBuf.toString('hex'), event: 'connection-error', message: String(err) } })
    }
  })
})

// Hyperswarm 4.x's own event surface (checked against its installed source)
// is only 'connection'/'update'/'ban' -- no distinct "found a candidate,
// handshaking" event exists to observe. 'update' (fired on any change to
// the swarm's known-peer set) is the closest available proxy for
// PearSwarmState.connecting: something is happening and a given tracked
// topic doesn't have a live connection yet.
swarm.on('update', () => {
  for (const [topicHex, t] of topics) {
    if (t.connectedPeers.size === 0 && swarm.peers.size > 0) sendState(topicHex, SwarmState.CONNECTING)
  }
})

// Defensive, not load-bearing: Hyperswarm 4.17.0 never actually emits
// 'error' on the swarm itself (checked against its installed source) -- but
// Node/Bare's EventEmitter aborts the whole process on an unhandled 'error'
// emission, so keeping a listener here is cheap insurance against a future
// version (or an internal dependency) that does. PearSwarm.join's Dart-side
// bounded timeout (swarm.dart's PearSwarmDefaults.joinTimeout) is what
// actually GUARANTEES a PearSwarmState.failed transition regardless of
// whether this ever fires -- this is best-effort classification only.
swarm.on('error', (err) => {
  for (const [topicHex, t] of topics) {
    send({ ev: EventName.SWARM_LIFECYCLE, p: { topic: topicHex, event: 'swarm-error', message: String(err) } })
    if (!t.everConnected) sendState(topicHex, SwarmState.FAILED, ErrorCode.UDP_BLOCKED)
  }
})

// File-path bulk seam (E4.4, codex #4 LOCKED) -- see Method.BULK_WRITE_FILE
// below. A worklet-private directory, not shared/external storage.
// Bare.argv[0] is this app's own private files directory, set by
// FlutterPearBarePlugin.kt's Worklet.start() -- bare-os's cwd() resolves to
// "/" in this sandbox (confirmed on-device), and neither BareKit nor Bare
// expose a storage-path helper, so argv is the only channel available.
const BULK_STORAGE_DIR = path.join(Bare.argv[0], 'pear-bulk')

// E5.2 -- Corestore/Hypercore wrapper (PearStore/PearCore). Same
// Bare.argv[0]-rooted storage rationale as BULK_STORAGE_DIR above. Opened
// once at boot, like `swarm` -- Method.STORE_GET below never re-opens it.
const store = new Corestore(path.join(Bare.argv[0], 'pear-corestore'))

// Cores this worklet generation has opened via Method.STORE_GET, by public
// key (hex) -- Method.CORE_APPEND/CORE_GET/CORE_REPLICATE/CORE_CLOSE all
// look a core up here rather than trusting whatever key Dart sends.
const cores = new Map() // key hex -> hypercore instance
const closedCores = new Set() // key hex -- see Method.CORE_CLOSE

// Per-peer chained replication stream (E5.2): Hypercore's own replicate()
// takes either a raw duplex stream OR the stream object returned by a
// PRIOR replicate() call, so multiple cores can multiplex over the same
// peer connection -- passing the raw connection twice would open two
// independent protocol streams over one socket and corrupt both. Chaining
// through here is what lets E5.3's Hyperbee (itself hypercore-backed) and
// this wrapper share a connection safely later.
const replicationStreams = new Map() // peer hex -> stream

function getCoreOrThrow (keyHex) {
  const core = cores.get(keyHex)
  if (!core) {
    const err = new Error('unknown core: ' + keyHex)
    err.code = ErrorCode.UNKNOWN_CORE
    throw err
  }
  return core
}

function getOpenCoreOrThrow (keyHex) {
  const core = getCoreOrThrow(keyHex)
  if (closedCores.has(keyHex)) {
    const err = new Error('core is closed: ' + keyHex)
    err.code = ErrorCode.CORE_CLOSED
    throw err
  }
  return core
}

// Shared by Method.CORE_REPLICATE (E5.2) and Method.BEE_REPLICATE (E5.3):
// replicates [core] over the connection to [peerHex], chaining through any
// prior replicate() call's returned stream for that same peer -- see
// replicationStreams' doc above for why passing the raw connection twice
// would corrupt things.
function replicateOverPeer (core, peerHex) {
  const conn = connections.get(peerHex)
  if (!conn) {
    const err = new Error('unknown peer: ' + peerHex)
    err.code = ErrorCode.UNKNOWN_PEER
    throw err
  }
  const base = replicationStreams.get(peerHex) || conn
  const stream = core.replicate(base)
  replicationStreams.set(peerHex, stream)
}

// Wraps an E5.2/E5.3 handler body so a genuine Corestore/Hypercore failure
// (disk I/O, corrupt storage, an unwritable session, ...) reaches Dart as
// STORAGE_UNAVAILABLE (schema.dart documents every E5 storage err.code as
// reusing it) instead of an uncategorized base PearException. Only applies
// when the caught error has no `.code` yet -- every error this file already
// throws with one set (INDEX_OUT_OF_RANGE, CORE_CLOSED, UNKNOWN_CORE,
// UNKNOWN_PEER, ...) passes through untouched.
async function withStorageErrors (fn) {
  try {
    return await fn()
  } catch (err) {
    if (!err.code) err.code = ErrorCode.STORAGE_UNAVAILABLE
    throw err
  }
}

// E5.6's own analog of withStorageErrors above -- a pairing failure isn't a
// storage-substrate issue (schema.dart categorizes every explicit E5.6 code
// as .connection, never .storage), so an uncoded blind-pairing/Protomux
// error (e.g. a malformed confirm key) gets PAIRING_FAILED instead of
// STORAGE_UNAVAILABLE (E5.6 review fix -- using withStorageErrors here would
// silently surface as the wrong exception category, PearStorageException
// instead of PearConnectionException).
async function withPairingErrors (fn) {
  try {
    return await fn()
  } catch (err) {
    if (!err.code) err.code = ErrorCode.PAIRING_FAILED
    throw err
  }
}

// E5.3 -- Hyperbee KV wrapper (PearBee). Its own registry, independent of
// `cores` above: a bee wraps a hypercore in B-tree-encoded blocks, which is
// a different (and incompatible) use of that same underlying core than
// treating it as a raw Method.CORE_* log -- callers shouldn't open the same
// name/key for both purposes, same caveat real Corestore/Hyperbee has.
const bees = new Map() // bee key hex -> hyperbee instance
const closedBees = new Set() // bee key hex -- see Method.BEE_CLOSE
const beeWatchers = new Map() // watchId -> { watcher, beeKeyHex } -- see Method.BEE_WATCH/BEE_UNWATCH

function getBeeOrThrow (keyHex) {
  const bee = bees.get(keyHex)
  if (!bee) {
    const err = new Error('unknown bee: ' + keyHex)
    err.code = ErrorCode.UNKNOWN_BEE
    throw err
  }
  return bee
}

function getOpenBeeOrThrow (keyHex) {
  const bee = getBeeOrThrow(keyHex)
  if (closedBees.has(keyHex)) {
    const err = new Error('bee is closed: ' + keyHex)
    err.code = ErrorCode.BEE_CLOSED
    throw err
  }
  return bee
}

// A bee's range/watch bounds arrive as optional base64 fields -- decodes
// whichever of gt/gte/lt/lte are present into the {gt,gte,lt,lte} shape
// Hyperbee's own range methods expect (undefined bounds are simply absent
// from the returned object, matching "no bound on this side").
function decodeRange (p) {
  const range = {}
  for (const bound of ['gt', 'gte', 'lt', 'lte']) {
    if (p[bound] != null) range[bound] = Buffer.from(p[bound], 'base64')
  }
  if (p.reverse) range.reverse = true
  if (p.limit != null) range.limit = p.limit
  return range
}

// E5.5 -- Hyperdrive file wrapper (PearDrive). Its own registry, same
// independence rationale as `bees` above.
const drives = new Map() // drive key hex -> hyperdrive instance
const closedDrives = new Set() // drive key hex -- see Method.DRIVE_CLOSE

function getDriveOrThrow (keyHex) {
  const drive = drives.get(keyHex)
  if (!drive) {
    const err = new Error('unknown drive: ' + keyHex)
    err.code = ErrorCode.UNKNOWN_DRIVE
    throw err
  }
  return drive
}

function getOpenDriveOrThrow (keyHex) {
  const drive = getDriveOrThrow(keyHex)
  if (closedDrives.has(keyHex)) {
    const err = new Error('drive is closed: ' + keyHex)
    err.code = ErrorCode.DRIVE_CLOSED
    throw err
  }
  return drive
}

// E5.6 -- blind-pairing wrapper (PearPairing). One entry per invite this
// worklet generation created via Method.PAIRING_CREATE_INVITE -- unlike
// cores/bees/drives, an invite has no name/key-based reopen (each
// PAIRING_CREATE_INVITE call always makes a genuinely new invite), so
// there's no closedInvites-style set: PAIRING_REVOKE just deletes the
// entry outright.
const invites = new Map() // invite id hex -> { member, candidates: Map<candidateId hex, { request, resolve }> }

function getInviteOrThrow (inviteIdHex) {
  const invite = invites.get(inviteIdHex)
  if (!invite) {
    const err = new Error('unknown invite: ' + inviteIdHex)
    err.code = ErrorCode.UNKNOWN_INVITE
    throw err
  }
  return invite
}

// E5.8 -- Autobase wrapper (PearBase). Its own registry, same independence
// rationale as bees/drives above -- an Autobase instance owns its OWN
// writer/system/view cores inside a per-base NAMESPACED session of `store`
// (see BASE_OPEN below for why namespacing is required at all: Autobase
// always derives its local writer core as store.get({name: 'local'})
// internally, so two DIFFERENT bases sharing the same un-namespaced store
// would silently collide on the identical writer core).
const bases = new Map() // base key hex -> { base, recipe }
const closedBases = new Set() // base key hex -- see Method.BASE_CLOSE
const baseWatchers = new Map() // watchId -> { unlisten, baseKeyHex } -- see Method.BASE_WATCH/BASE_UNWATCH

function getBaseOrThrow (keyHex) {
  const entry = bases.get(keyHex)
  if (!entry) {
    const err = new Error('unknown base: ' + keyHex)
    err.code = ErrorCode.UNKNOWN_BASE
    throw err
  }
  return entry
}

function getOpenBaseOrThrow (keyHex) {
  const entry = getBaseOrThrow(keyHex)
  if (closedBases.has(keyHex)) {
    const err = new Error('base is closed: ' + keyHex)
    err.code = ErrorCode.BASE_CLOSED
    throw err
  }
  return entry
}

// E4.4 fix: accumulates bytes across deliveries and splits on the 4-byte
// length prefix writeFramed() stamps -- see that function's doc. Mirrors
// bare_worklet.dart's _onIpc accumulator on the Dart side.
let recvBuffer = Buffer.alloc(0)

IPC.on('data', (buf) => {
  recvBuffer = recvBuffer.length ? Buffer.concat([recvBuffer, buf]) : buf
  while (recvBuffer.length >= 4) {
    const frameLength = recvBuffer.readUInt32BE(0)
    if (recvBuffer.length < 4 + frameLength) break // frame not fully here yet
    handleFrame(recvBuffer.subarray(4, 4 + frameLength))
    recvBuffer = recvBuffer.subarray(4 + frameLength)
  }
})

function handleFrame (buf) {
  if (buf.length === 0) return

  const frameType = buf[0]
  if (frameType !== FrameType.JSON) {
    // No FrameType.RAW reader exists yet (M3's bulk transport is the first
    // planned consumer) -- surfaced, not silently dropped, same as any
    // other byte this version of the schema doesn't recognize.
    diagnostic('unhandled frame type', { frameType })
    return
  }

  let frame
  try { frame = JSON.parse(buf.subarray(1).toString()) } catch (error) {
    diagnostic('malformed JSON control frame', { error: String(error) })
    return
  }
  if (!frame || typeof frame.id !== 'number') {
    // `!frame` guards `frame.id` below from throwing on JSON `null`
    // (JSON.parse('null') is valid JS `null`, and `null.id` throws --
    // that would otherwise crash the whole worklet host process, since
    // bare-kit has no per-call error boundary here). Valid-but-wrong-shape
    // JSON (including this) is a shape mismatch: the worklet only ever
    // receives request frames (Dart->worklet).
    diagnostic('JSON control frame was not a request', { frame })
    return
  }
  Promise.resolve()
    .then(() => handle(frame))
    .then(
      (ok) => send({ id: frame.id, ok: ok ?? null }),
      (err) => send({
        id: frame.id,
        err: {
          message: String((err && err.message) || err),
          code: err && err.code,
          stack: err && err.stack
        }
      })
    )
}

async function handle ({ m, p }) {
  switch (m) {
    // Request/response, not a fire-once event: works correctly whether
    // Dart is asking for the first time (fresh boot) or re-asking after a
    // hot restart reattached to this same already-running worklet.
    case Method.ATTACH_INFO: {
      return {
        [HandshakeField.NONCE]: SESSION_NONCE,
        [HandshakeField.BUNDLE_VERSION]: BUNDLE_VERSION
      }
    }
    // Dynamic, Dart-driven join (E4.4) -- idempotent: joining an
    // already-joined topic again is a no-op ack, not a second
    // swarm.join()/DISCOVERING notice.
    case Method.SWARM_JOIN: {
      if (!topics.has(p.topic)) {
        topics.set(p.topic, { connectedPeers: new Set(), everConnected: false })
        swarm.join(Buffer.from(p.topic, 'hex'), { server: true, client: true })
        sendState(p.topic, SwarmState.DISCOVERING)
      }
      return { joined: p.topic }
    }
    // Awaited before acking (unlike SWARM_JOIN, which doesn't wait on
    // discovery either): swarm.leave() is genuinely async, and
    // PearSwarm.leave() (swarm.dart) awaits this call before tearing down
    // its own Dart-side state, so the ack should mean "actually left", not
    // just "request accepted".
    case Method.SWARM_LEAVE: {
      if (topics.has(p.topic)) {
        topics.delete(p.topic)
        await swarm.leave(Buffer.from(p.topic, 'hex'))
      }
      return { left: p.topic }
    }
    case Method.CONNECTION_WRITE: {
      // Sent over the shared Protomux channel (see connectionChannels' doc
      // above), not conn.write() directly -- required for this connection
      // to coexist with BlindPairing (E5.6).
      const message = connectionChannels.get(p.peer)
      if (!message) {
        const err = new Error('unknown peer: ' + p.peer)
        err.code = ErrorCode.UNKNOWN_PEER
        throw err
      }
      message.send(Buffer.from(p.data, 'base64'))
      return null
    }
    // File-path bulk seam (E4.4, codex #4 LOCKED) -- see Method.BULK_WRITE_FILE's
    // doc in schema.dart. The whole payload arrives in one request (no
    // in-channel chunking); this just relocates it from an RPC response
    // (which would inflate through JSON/base64 on every future access) to a
    // file the caller can read directly by path.
    case Method.BULK_WRITE_FILE: {
      const bytes = Buffer.from(p.data, 'base64')
      const filePath = path.join(BULK_STORAGE_DIR, crypto.randomBytes(16).toString('hex'))
      try {
        await fs.mkdir(BULK_STORAGE_DIR, { recursive: true })
        await fs.writeFile(filePath, bytes)
      } catch (writeErr) {
        const err = new Error('failed to write bulk payload: ' + String(writeErr))
        err.code = ErrorCode.STORAGE_UNAVAILABLE
        throw err
      }
      return { path: filePath }
    }
    // E5.2 -- Corestore/Hypercore wrapper. See schema.dart's PearMethod
    // doc comments for the full contract of each of these. Every case body
    // runs through withStorageErrors so a genuine Corestore/Hypercore I/O
    // failure (as opposed to one of THIS handler's own coded throws below,
    // which withStorageErrors leaves alone -- see its doc) reaches Dart as
    // the documented PearStorageException, per schema.dart's
    // storageUnavailable doc comment.
    case Method.STORE_GET: {
      return withStorageErrors(async () => {
        if ((p.key == null) === (p.name == null)) {
          const err = new Error('store.get needs exactly one of name/key')
          err.code = ErrorCode.STORAGE_UNAVAILABLE
          throw err
        }
        const core = p.key ? store.get(Buffer.from(p.key, 'hex')) : store.get({ name: p.name })
        await core.ready()
        const keyHex = core.key.toString('hex')
        // Re-register on EVERY reopen of a previously-closed key, not just
        // the first-ever open: store.get() always returns a fresh session
        // object, but `cores` (unlike `closedCores`) is never pruned on
        // close, so `cores.has(keyHex)` alone can't tell a genuinely new
        // key apart from a stale closed session's key still sitting in the
        // map -- checking closedCores too is what lets a reopen replace
        // that stale session instead of silently keeping it (and its
        // permanently-closed status) forever.
        if (!cores.has(keyHex) || closedCores.has(keyHex)) {
          cores.set(keyHex, core)
          closedCores.delete(keyHex)
          core.on('append', () => {
            send({ ev: EventName.CORE_UPDATE, p: { key: keyHex, length: core.length } })
          })
        }
        return { key: keyHex, length: core.length }
      })
    }
    case Method.CORE_APPEND: {
      return withStorageErrors(async () => {
        const core = getOpenCoreOrThrow(p.key)
        await core.append(p.data.map((b) => Buffer.from(b, 'base64')))
        return { length: core.length }
      })
    }
    case Method.CORE_GET: {
      return withStorageErrors(async () => {
        const core = getOpenCoreOrThrow(p.key)
        if (p.index < 0 || p.index >= core.length) {
          const err = new Error('index out of range: ' + p.index)
          err.code = ErrorCode.INDEX_OUT_OF_RANGE
          throw err
        }
        const block = await core.get(p.index)
        return { data: block.toString('base64') }
      })
    }
    case Method.CORE_REPLICATE: {
      return withStorageErrors(async () => {
        const core = getOpenCoreOrThrow(p.key)
        replicateOverPeer(core, p.peer)
        return null
      })
    }
    case Method.CORE_CLOSE: {
      return withStorageErrors(async () => {
        const core = getCoreOrThrow(p.key)
        if (!closedCores.has(p.key)) {
          // Marked closed BEFORE the await so a request arriving after this
          // point gets a clean CORE_CLOSED immediately. A request already
          // past getOpenCoreOrThrow's check when close() itself starts
          // running is a narrower, accepted race: it still fails, just as
          // an uncoded error that withStorageErrors maps to
          // STORAGE_UNAVAILABLE rather than the more precise CORE_CLOSED --
          // deemed acceptable for this wrapper's first substrate ticket
          // rather than adding per-core operation locking to close it
          // completely.
          closedCores.add(p.key)
          await core.close()
        }
        return null
      })
    }
    // E5.3 -- Hyperbee KV wrapper. See schema.dart's PearMethod doc
    // comments for the full contract of each of these. Same
    // withStorageErrors + reopen-after-close handling as E5.2 above.
    case Method.BEE_OPEN: {
      return withStorageErrors(async () => {
        if ((p.key == null) === (p.name == null)) {
          const err = new Error('bee.open needs exactly one of name/key')
          err.code = ErrorCode.STORAGE_UNAVAILABLE
          throw err
        }
        const core = p.key ? store.get(Buffer.from(p.key, 'hex')) : store.get({ name: p.name })
        await core.ready()
        const keyHex = core.key.toString('hex')
        if (!bees.has(keyHex) || closedBees.has(keyHex)) {
          const bee = new Hyperbee(core, { keyEncoding: 'binary', valueEncoding: 'binary' })
          await bee.ready()
          bees.set(keyHex, bee)
          closedBees.delete(keyHex)
        }
        return { key: keyHex }
      })
    }
    case Method.BEE_GET: {
      return withStorageErrors(async () => {
        const bee = getOpenBeeOrThrow(p.bee)
        const node = await bee.get(Buffer.from(p.key, 'base64'))
        if (!node) return { found: false }
        return { found: true, value: node.value.toString('base64') }
      })
    }
    case Method.BEE_PUT: {
      return withStorageErrors(async () => {
        const bee = getOpenBeeOrThrow(p.bee)
        await bee.put(Buffer.from(p.key, 'base64'), Buffer.from(p.value, 'base64'))
        return null
      })
    }
    case Method.BEE_DEL: {
      return withStorageErrors(async () => {
        const bee = getOpenBeeOrThrow(p.bee)
        await bee.del(Buffer.from(p.key, 'base64'))
        return null
      })
    }
    case Method.BEE_REPLICATE: {
      return withStorageErrors(async () => {
        const bee = getOpenBeeOrThrow(p.bee)
        replicateOverPeer(bee.core, p.peer)
        return null
      })
    }
    case Method.BEE_RANGE: {
      return withStorageErrors(async () => {
        const bee = getOpenBeeOrThrow(p.bee)
        const entries = []
        for await (const node of bee.createReadStream(decodeRange(p))) {
          entries.push({ key: node.key.toString('base64'), value: node.value.toString('base64') })
        }
        return { entries }
      })
    }
    // Consumes the Watcher's own async-iterator protocol in a detached loop
    // (not awaited by this handler -- BEE_WATCH itself acks immediately,
    // same "subscribe now, events follow" shape as Method.SWARM_JOIN) and
    // forwards each change as a BEE_UPDATE event tagged with p.watch, so
    // Dart can demultiplex when a bee has more than one concurrent watch.
    case Method.BEE_WATCH: {
      return withStorageErrors(async () => {
        const bee = getOpenBeeOrThrow(p.bee)
        const watcher = bee.watch(decodeRange(p))
        beeWatchers.set(p.watch, { watcher, beeKeyHex: p.bee })
        ;(async () => {
          try {
            // eslint-disable-next-line no-unused-vars
            for await (const _ of watcher) {
              send({ ev: EventName.BEE_UPDATE, p: { bee: p.bee, watch: p.watch } })
            }
          } catch (_) {
            // Watcher closed (Method.BEE_UNWATCH/BEE_CLOSE) or the bee
            // itself errored -- either way nothing more to notify Dart
            // about; a genuine bee failure already surfaced via whatever
            // RPC call triggered it.
          }
        })()
        return null
      })
    }
    case Method.BEE_UNWATCH: {
      return withStorageErrors(async () => {
        const entry = beeWatchers.get(p.watch)
        if (entry) {
          // Scoped by bee, same as BEE_CLOSE's cleanup loop below -- a
          // watchId naming the wrong bee is a caller bug, not a silent
          // "sure, I'll close whatever this id happens to point at".
          if (entry.beeKeyHex !== p.bee) {
            const err = new Error('watch ' + p.watch + ' does not belong to bee ' + p.bee)
            err.code = ErrorCode.UNKNOWN_BEE
            throw err
          }
          beeWatchers.delete(p.watch)
          await entry.watcher.close()
        }
        return null
      })
    }
    case Method.BEE_CLOSE: {
      return withStorageErrors(async () => {
        const bee = getBeeOrThrow(p.bee)
        if (!closedBees.has(p.bee)) {
          closedBees.add(p.bee)
          // Closing a bee also stops every watch still open on it -- an
          // app that forgets to unwatch before closing shouldn't leak a
          // JS-side listener forever.
          for (const [watchId, entry] of beeWatchers) {
            if (entry.beeKeyHex === p.bee) {
              beeWatchers.delete(watchId)
              await entry.watcher.close()
            }
          }
          await bee.close()
        }
        return null
      })
    }
    // E5.5 -- Hyperdrive file wrapper. See schema.dart's PearMethod doc
    // comments for the full contract of each of these. LOCKED (E5.1 codex
    // #4, confirmed by BENCHMARK.md's numbers): every put/get below streams
    // straight between the local filesystem and the drive -- the RPC
    // envelope only ever carries path strings, never file bytes, so a
    // payload of any size never inflates through JSON/base64.
    case Method.DRIVE_OPEN: {
      return withStorageErrors(async () => {
        if ((p.key == null) === (p.name == null)) {
          const err = new Error('drive.open needs exactly one of name/key')
          err.code = ErrorCode.STORAGE_UNAVAILABLE
          throw err
        }
        // A name-derived drive's KEY is learned by first deriving ITS OWN
        // core by name (giving a writable session, same as
        // store.get/bee.open) -- Hyperdrive has no `name` option of its
        // own, only `key`. That scratch session's only job is handing back
        // .key; closed immediately after so it doesn't leak for the life
        // of the worklet (E5.5 review fix -- a name-derived Hyperdrive's
        // OWN internal corestore.get({key, ...}) call re-derives a fresh
        // session for the same underlying core once constructed below, so
        // closing this one first costs nothing).
        let driveKey
        if (p.key) {
          driveKey = Buffer.from(p.key, 'hex')
        } else {
          const nameCore = store.get({ name: p.name })
          await nameCore.ready()
          driveKey = nameCore.key
          await nameCore.close()
        }
        const keyHex = driveKey.toString('hex')
        // Constructing (and .ready()-ing) a Hyperdrive eagerly opens TWO
        // more sessions of its own (db + blobs) -- deferred until INSIDE
        // this guard, same as BEE_OPEN's Hyperbee construction, so a
        // redundant re-open of an already-registered drive never builds
        // and silently discards a second, fully-opened Hyperdrive (E5.5
        // review fix).
        if (!drives.has(keyHex) || closedDrives.has(keyHex)) {
          const drive = new Hyperdrive(store, driveKey)
          await drive.ready()
          drives.set(keyHex, drive)
          closedDrives.delete(keyHex)
        }
        return { key: keyHex }
      })
    }
    case Method.DRIVE_PUT: {
      return withStorageErrors(async () => {
        const drive = getOpenDriveOrThrow(p.drive)
        await pipelinePromise(
          fs.createReadStream(p.localSourcePath),
          drive.createWriteStream(p.path)
        )
        return null
      })
    }
    case Method.DRIVE_GET: {
      return withStorageErrors(async () => {
        const drive = getOpenDriveOrThrow(p.drive)
        // Narrower, accepted race (same class as CORE_CLOSE's above): if
        // p.path is deleted between this check and createReadStream()
        // below, the read fails with hyperdrive's own uncoded "blob does
        // not exist" error instead of the more precise FILE_NOT_FOUND --
        // withStorageErrors still stamps it STORAGE_UNAVAILABLE, so it's
        // never silent, just less exact than the simple (non-concurrent)
        // missing-file case this check exists for.
        if (!(await drive.exists(p.path))) {
          const err = new Error('file not found: ' + p.path)
          err.code = ErrorCode.FILE_NOT_FOUND
          throw err
        }
        await pipelinePromise(
          drive.createReadStream(p.path),
          fs.createWriteStream(p.destinationPath)
        )
        return null
      })
    }
    case Method.DRIVE_EXISTS: {
      return withStorageErrors(async () => {
        const drive = getOpenDriveOrThrow(p.drive)
        return { exists: await drive.exists(p.path) }
      })
    }
    case Method.DRIVE_DELETE: {
      return withStorageErrors(async () => {
        const drive = getOpenDriveOrThrow(p.drive)
        await drive.del(p.path)
        return null
      })
    }
    case Method.DRIVE_LIST: {
      return withStorageErrors(async () => {
        const drive = getOpenDriveOrThrow(p.drive)
        const paths = []
        for await (const entry of drive.list(p.folder || '/')) {
          paths.push(entry.key)
        }
        return { paths }
      })
    }
    case Method.DRIVE_REPLICATE: {
      return withStorageErrors(async () => {
        const drive = getOpenDriveOrThrow(p.drive)
        // A drive's file CONTENT lives in a separate Hyperblobs core from
        // its metadata (path -> blob reference) core -- both must
        // replicate, or file listings would sync with no bytes ever
        // following them. Chained through the same replicationStreams
        // entry as any other core/bee replicating with this peer (see
        // replicateOverPeer's doc).
        replicateOverPeer(drive.core, p.peer)
        const blobs = await drive.getBlobs()
        replicateOverPeer(blobs.core, p.peer)
        return null
      })
    }
    case Method.DRIVE_MIRROR_TO_DISK: {
      return withStorageErrors(async () => {
        const drive = getOpenDriveOrThrow(p.drive)
        const localDrive = new Localdrive(p.localDir)
        // mirror-drive (the Pear ecosystem's own tool for this) streams
        // and diffs -- only changed files actually copy, and nothing here
        // reimplements that copy logic by hand.
        const mirror = drive.mirror(localDrive)
        await mirror.done()
        return {
          added: mirror.count.add,
          changed: mirror.count.change,
          removed: mirror.count.remove
        }
      })
    }
    case Method.DRIVE_CLOSE: {
      return withStorageErrors(async () => {
        const drive = getDriveOrThrow(p.drive)
        if (!closedDrives.has(p.drive)) {
          closedDrives.add(p.drive)
          await drive.close()
        }
        return null
      })
    }
    // E5.6 -- blind-pairing wrapper. See schema.dart's PearMethod doc
    // comments for the full contract of each of these. `key` in
    // CONFIRM_CANDIDATE/ACCEPT_INVITE's response is fixed at exactly 32
    // bytes by blind-pairing-core's own wire format (ResponsePayload
    // encodes it as a mandatory fixed32) -- not a limitation this wrapper
    // adds, which is why PearPairingCandidate.confirm takes a PearKey
    // rather than arbitrary bytes.
    case Method.PAIRING_CREATE_INVITE: {
      return withPairingErrors(async () => {
        // The invite's own "resource key" only exists to derive a unique
        // discovery channel -- this wrapper has no data structure to tie
        // an invite to (unlike the README's Autobase example), so a fresh
        // random key per invite is all that's needed.
        const resourceKey = crypto.randomBytes(32)
        const { invite, id, publicKey, discoveryKey } = BlindPairing.createInvite(resourceKey, {
          expires: p.expiresAt || 0
        })
        const inviteIdHex = id.toString('hex')
        const candidates = new Map()
        const member = pairing.addMember({
          discoveryKey,
          onadd: (request) => {
            // onadd's returned promise is awaited internally by
            // blind-pairing before it moves on -- resolving it is exactly
            // what "wait for Method.PAIRING_CONFIRM_CANDIDATE" means here.
            return new Promise((resolve) => {
              try {
                request.open(publicKey)
              } catch (err) {
                // A malformed/tampered pairing request -- request.open()
                // throws synchronously on a decrypt/signature-verify
                // failure (blind-pairing-core's openAuth). Left uncaught,
                // this propagates through blind-pairing's own
                // Member._addRequest into Protomux's per-message rejection
                // handling, which destroys the WHOLE peer connection, not
                // just this one bad candidate (E5.6 review fix). Dropping
                // the request here (no candidate event, nothing further to
                // confirm) rejects just this one candidate instead.
                diagnostic('pairing request rejected', { error: String(err) })
                resolve()
                return
              }
              const candidateId = crypto.randomBytes(16).toString('hex')
              candidates.set(candidateId, { request, resolve })
              send({
                ev: EventName.PAIRING_CANDIDATE,
                p: {
                  inviteId: inviteIdHex,
                  candidateId,
                  userData: request.userData ? request.userData.toString('base64') : ''
                }
              })
            })
          }
        })
        await member.ready()
        await member.flushed()
        invites.set(inviteIdHex, { member, candidates })
        return { invite: invite.toString('base64'), inviteId: inviteIdHex }
      })
    }
    case Method.PAIRING_CONFIRM_CANDIDATE: {
      return withPairingErrors(async () => {
        const inviteEntry = getInviteOrThrow(p.inviteId)
        const candidateEntry = inviteEntry.candidates.get(p.candidateId)
        if (!candidateEntry) {
          const err = new Error('unknown candidate: ' + p.candidateId)
          err.code = ErrorCode.UNKNOWN_CANDIDATE
          throw err
        }
        // confirm() first, delete only once it succeeds (E5.6 review fix):
        // confirm() can throw synchronously (e.g. a wrong-length key --
        // blind-pairing-core's ResponsePayload encodes `key` as a mandatory
        // fixed32). Deleting beforehand meant a failed confirm permanently
        // discarded the candidate -- a retry with a corrected key got
        // UNKNOWN_CANDIDATE instead of succeeding, and the candidate's own
        // onadd promise was left resolved-never, leaking a pending request
        // inside blind-pairing's Member.
        candidateEntry.request.confirm({ key: Buffer.from(p.key, 'base64') })
        inviteEntry.candidates.delete(p.candidateId)
        candidateEntry.resolve()
        return null
      })
    }
    case Method.PAIRING_REVOKE: {
      return withPairingErrors(async () => {
        const inviteEntry = invites.get(p.inviteId)
        if (inviteEntry) {
          invites.delete(p.inviteId)
          // Unblock any candidate still awaiting confirmation BEFORE
          // closing the member (E5.6 review fix): blind-pairing's own
          // Member._addRequest awaits each candidate's onadd() promise
          // before its internal poll loop can terminate, so
          // member.close() below would otherwise hang forever on an
          // invite with an announced-but-not-yet-confirmed candidate.
          // Resolving without calling request.confirm() leaves that
          // candidate's own acceptInvite() unconfirmed -- it still times
          // out via its own bound, same as any other revoked invite.
          for (const candidateEntry of inviteEntry.candidates.values()) {
            candidateEntry.resolve()
          }
          inviteEntry.candidates.clear()
          await inviteEntry.member.close()
        }
        return null
      })
    }
    case Method.PAIRING_ACCEPT_INVITE: {
      return withPairingErrors(async () => {
        const inviteBytes = Buffer.from(p.invite, 'base64')
        let decoded
        try {
          decoded = BlindPairing.decodeInvite(inviteBytes)
        } catch (decodeErr) {
          const err = new Error('invalid invite: ' + String(decodeErr))
          err.code = ErrorCode.INVALID_INVITE
          throw err
        }
        // Enforced here, not by blind-pairing itself -- confirmed by
        // reading blind-pairing-core's source: `expires` is encoded into
        // the invite bytes verbatim but never checked by the library's
        // own pairing flow.
        if (decoded.expires && Date.now() > decoded.expires) {
          const err = new Error('invite expired')
          err.code = ErrorCode.INVITE_EXPIRED
          throw err
        }
        const userData = p.userData ? Buffer.from(p.userData, 'base64') : Buffer.alloc(0)
        const candidate = pairing.addCandidate({ invite: inviteBytes, userData })
        await candidate.ready()
        // candidate.pairing never resolves on its own if nobody ever
        // confirms (blind-pairing's own polling loop has no built-in
        // bound) -- this is also what makes a revoked invite "block
        // accept" rather than erroring immediately: revoking just means
        // nothing is left to confirm, so this bound is what eventually
        // surfaces that as a clean, typed failure instead of a silent
        // hang.
        // `!= null`, not `||` (E5.6 review fix): an explicit timeoutMs of 0
        // (fail-fast) is falsy in JS, so `||` silently substituted the
        // 30s default for it instead of honoring "return immediately".
        const timeoutMs = p.timeoutMs != null ? p.timeoutMs : 30000
        let timedOut = false
        const timeout = new Promise((resolve) => {
          setTimeout(() => {
            timedOut = true
            resolve(null)
          }, timeoutMs)
        })
        const paired = await Promise.race([candidate.pairing, timeout])
        if (timedOut || !paired) {
          await candidate.close()
          const err = new Error('pairing timed out')
          err.code = ErrorCode.PAIRING_TIMEOUT
          throw err
        }
        return { key: paired.key.toString('base64') }
      })
    }
    // E5.8 -- Autobase wrapper. See schema.dart's PearMethod doc comments
    // for the full contract of each of these. Uses withStorageErrors, not
    // its own wrapper, unlike E5.6 pairing -- every explicit E5.8 error
    // code is .storage category, matching every other data-structure
    // wrapper (base is a corestore-backed structure, unlike pairing's
    // handshake protocol).
    case Method.BASE_OPEN: {
      return withStorageErrors(async () => {
        if ((p.key == null) === (p.name == null)) {
          const err = new Error('base.open needs exactly one of name/key')
          err.code = ErrorCode.STORAGE_UNAVAILABLE
          throw err
        }
        const recipe = RECIPES[p.recipe]
        if (!recipe) {
          const err = new Error('unknown recipe: ' + p.recipe)
          err.code = ErrorCode.UNKNOWN_RECIPE
          throw err
        }
        // Autobase always derives its own local writer core as
        // store.get({name: 'local'}) INTERNALLY (confirmed against the
        // real package) -- so every base needs its OWN namespaced session
        // of `store`, or two different bases (by name or by key) would
        // silently collide on the identical writer core. Namespaced by
        // the name/key itself so the SAME name/key always resolves to the
        // SAME namespace (deterministic reopen, matching every other
        // wrapper's convention).
        const namespaceSeed = p.key || p.name
        let keyHex
        if (p.key) {
          keyHex = p.key
        } else {
          // A cheap scratch read of the SAME core Autobase would derive
          // internally, just to learn its key before deciding whether a
          // redundant reopen needs a fresh Autobase at all (E5.2/E5.5's
          // session-leak lesson applied proactively -- see DRIVE_OPEN's
          // own comment for the precedent this mirrors).
          const scratch = store.namespace(namespaceSeed).get({ name: 'local' })
          await scratch.ready()
          keyHex = scratch.key.toString('hex')
          await scratch.close()
        }
        if (!bases.has(keyHex) || closedBases.has(keyHex)) {
          const base = new Autobase(store.namespace(namespaceSeed), p.key ? Buffer.from(p.key, 'hex') : null, {
            open: recipe.open,
            apply: recipe.apply,
            valueEncoding: 'json'
          })
          await base.ready()
          // Autobase's own default for an apply()-time error with no
          // 'error' listener is crashSoon() -- kill the WHOLE worklet
          // process (confirmed against node_modules/autobase/index.js's
          // _onError: with zero 'error' listeners it calls crashSoon(err)
          // instead of this.close()+emit('error', err)). That's the right
          // call for a MALFORMED_OP (see autobase-recipes.js's doc), but
          // wrong for a genuine operational constraint local to just THIS
          // base (e.g. removeWriter refusing to remove the last indexer,
          // see handleWriterOp's comment) -- registering a listener here
          // makes _onError just close this one base instead, so every
          // other open core/bee/drive/base in this worklet generation
          // survives.
          base.on('error', () => {
            closedBases.add(keyHex)
            for (const [watchId, entry] of baseWatchers) {
              if (entry.baseKeyHex === keyHex) {
                baseWatchers.delete(watchId)
                entry.unlisten()
              }
            }
          })
          bases.set(keyHex, { base, recipe, appendQueue: Promise.resolve() })
          closedBases.delete(keyHex)
        }
        // writerKey: this worklet generation's OWN local writer identity
        // for this base -- the caller shares it (out of band, e.g. via
        // PearPairing) with whichever peer they want to admit via a
        // BASE_APPEND addWriter op.
        return { key: keyHex, writerKey: bases.get(keyHex).base.local.key.toString('hex') }
      })
    }
    case Method.BASE_REPLICATE: {
      return withStorageErrors(async () => {
        const { base } = getOpenBaseOrThrow(p.base)
        // base.replicate(streamOrConn) matches Hypercore/Corestore's own
        // replicate() signature exactly (confirmed against autobase's
        // source: it just delegates to this.store.replicate(...)), so the
        // same chained-stream helper every other E5.x wrapper shares works
        // here unchanged.
        replicateOverPeer(base, p.peer)
        return null
      })
    }
    case Method.BASE_APPEND: {
      return withStorageErrors(async () => {
        const entry = getOpenBaseOrThrow(p.base)
        // Serializes concurrent appends on the SAME base: crdtMap's
        // normalizeAppend below does a genuine async read of the current
        // view to auto-fill a del's `removes`, and Autobase's own append()
        // has multiple await points before a node is actually linearized
        // into the view -- with no per-base ordering, an overlapping
        // put-then-del on the same key could have the del's read run
        // before the put it's meant to observe is applied, silently
        // dropping nothing instead of the intended value. Chaining every
        // append off the base's own queue (which never rejects, so a
        // failed append doesn't wedge the ones behind it) makes BASE_APPEND
        // calls on one base strictly FIFO regardless of arrival order.
        const task = entry.appendQueue.catch(() => {}).then(async () => {
          const { base, recipe } = entry
          const value = recipe.normalizeAppend ? await recipe.normalizeAppend(base.view, p.value) : p.value
          // Validate BEFORE ever appending (see autobase-recipes.js's top
          // doc comment for why this must happen here, not just inside
          // apply()): apply() only SKIPS a MALFORMED_OP node so one writer's
          // shape bug can never brick the base, but that means a caller
          // who never validates gets no signal at all that their op was
          // silently dropped. Mirrors handleWriterOp's own dispatch order
          // (addWriter/removeWriter first, else the recipe's own op shape).
          if (value && typeof value === 'object' && value.addWriter != null) {
            validateAddWriter(value)
          } else if (value && typeof value === 'object' && value.removeWriter != null) {
            validateRemoveWriter(value)
          } else {
            recipe.validate(value)
          }
          await base.append(value)
          return null
        })
        entry.appendQueue = task.catch(() => {})
        return task
      })
    }
    case Method.BASE_GET: {
      return withStorageErrors(async () => {
        const { base, recipe } = getOpenBaseOrThrow(p.base)
        if (!recipe.get) {
          const err = new Error('base.get is not supported by the ' + p.base + ' recipe')
          err.code = ErrorCode.STORAGE_UNAVAILABLE
          throw err
        }
        return recipe.get(base.view, p.key)
      })
    }
    case Method.BASE_RANGE: {
      return withStorageErrors(async () => {
        const { base, recipe } = getOpenBaseOrThrow(p.base)
        if (recipe !== RECIPES.orderedLog) {
          const err = new Error('base.range is only supported by the orderedLog recipe')
          err.code = ErrorCode.STORAGE_UNAVAILABLE
          throw err
        }
        const start = p.start || 0
        const end = p.end != null ? p.end : base.view.length
        const entries = []
        for (let i = start; i < end; i++) {
          entries.push((await base.view.get(i)).toString('base64'))
        }
        return { entries }
      })
    }
    case Method.BASE_WATCH: {
      return withStorageErrors(async () => {
        const { base, recipe } = getOpenBaseOrThrow(p.base)
        const cores = recipe.viewCores(base.view)
        const onAppend = () => {
          send({ ev: EventName.BASE_UPDATE, p: { base: p.base, watch: p.watch } })
        }
        for (const core of cores) core.on('append', onAppend)
        baseWatchers.set(p.watch, {
          unlisten: () => { for (const core of cores) core.off('append', onAppend) },
          baseKeyHex: p.base
        })
        return null
      })
    }
    case Method.BASE_UNWATCH: {
      return withStorageErrors(async () => {
        const entry = baseWatchers.get(p.watch)
        if (entry) {
          // Scoped by base, same as BASE_CLOSE's cleanup loop below -- a
          // watchId naming the wrong base is a caller bug, not a silent
          // "sure, I'll unwatch whatever this id happens to point at".
          if (entry.baseKeyHex !== p.base) {
            const err = new Error('watch ' + p.watch + ' does not belong to base ' + p.base)
            err.code = ErrorCode.UNKNOWN_BASE
            throw err
          }
          baseWatchers.delete(p.watch)
          entry.unlisten()
        }
        return null
      })
    }
    case Method.BASE_CLOSE: {
      return withStorageErrors(async () => {
        const { base } = getBaseOrThrow(p.base)
        if (!closedBases.has(p.base)) {
          closedBases.add(p.base)
          // Closing a base also stops every watch still open on it -- same
          // as BEE_CLOSE/DRIVE_CLOSE's precedent.
          for (const [watchId, entry] of baseWatchers) {
            if (entry.baseKeyHex === p.base) {
              baseWatchers.delete(watchId)
              entry.unlisten()
            }
          }
          await base.close()
        }
        return null
      })
    }
    // Lets the E1 gate prove the JS error path end-to-end: message/code/stack
    // travel through the `err` envelope above into a typed PearException in
    // Dart (see flutter_pear/lib/src/exceptions.dart + rpc.dart).
    case Method.DEBUG_FORCE_ERROR: {
      const err = new Error((p && p.message) || 'forced error for E1 gate test')
      err.code = ErrorCode.FORCED_ERROR
      throw err
    }
    // E2.6 validation hook: throwing HERE would just become a normal err
    // response (this whole handler runs inside a Promise chain that
    // catches it) -- setTimeout escapes that chain entirely, so it reaches
    // Bare's uncaughtException handling for real, exercising the actual
    // crash-report path this ticket exists to prove.
    case Method.DEBUG_FORCE_CRASH: {
      setTimeout(() => {
        throw new Error((p && p.message) || 'forced crash for E2.6 validation')
      }, 0)
      return null
    }
    // E5.1 -- the platform-channel throughput benchmark's in-channel leg:
    // a raw round trip with no JS-side work (no base64 re-decode/re-encode
    // beyond what the RPC envelope itself already does) to attribute
    // latency to besides the transport.
    case Method.DEBUG_ECHO: {
      return { data: p.data }
    }
    default: {
      const err = new Error('unknown method: ' + m)
      err.code = ErrorCode.UNKNOWN_METHOD
      throw err
    }
  }
}
