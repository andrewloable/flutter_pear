#!/usr/bin/env node
'use strict'

// flutter_pear-doi / flutter_pear-2vz.6 (E5.6)'s deferred real-device leg,
// downgraded this session to "real Bare Kit worklet, validated on an
// emulator against a desktop peer process" (no physical hardware available
// -- see flutter_pear-doi's own developer-decision note): the desktop half
// of a real, two-process blind-pairing invite create/accept round trip, PLUS
// the distinct, HIGH-PRIORITY property E5.6's own review flagged as
// UNVERIFIED outside the Dart fake: that Method.CONNECTION_WRITE/
// CONNECTION_DATA (the raw app-data channel) still delivers bytes correctly
// over the SAME live connection BlindPairing's own Protomux usage just
// negotiated on.
//
// A NEW SIBLING SCRIPT, not a `--pairing` mode on peer.js, because this is
// architecturally a different kind of tool: peer.js talks Hyperswarm/
// Protomux directly and never touches pear-end/index.js's own RPC surface
// (chat/--drive have no wire protocol of their own beyond what index.js's
// CONNECTION_WRITE/DATA and core/blobs replicate() already define, so peer.js
// only needs the same libraries, not the same CODE). Blind pairing is the
// opposite: ALL of its interesting logic -- the resourceKey/discoveryKey
// juggling, the optionalBuffer-empty-buffer workaround, confirm()'s
// key-vs-additional split -- lives inside pear-end/index.js's own Method
// handlers (see its PAIRING_CREATE_INVITE comment for the full story), not
// in the blind-pairing library alone. Proving desktop-JS and phone-JS
// interoperate here means running that SAME index.js code, not a
// hand-rolled reimplementation of it.
//
// THAT is exactly why peer.js's own earlier `--invite`/`--create-invite`
// mode was abandoned (see its header comment): it called blind-pairing
// directly and had to re-derive index.js's own workarounds from scratch,
// getting some of them wrong (passing resourceKey instead of createInvite's
// returned publicKey to request.open(); passing undefined instead of an
// explicit Buffer.alloc(0) for userData) and STILL failing after fixing
// those two, reproduced even in a same-process, no-network repro -- strong
// evidence the remaining gap was a real, unresolved bug in that file's own
// approach, not network flakiness. This file sidesteps the whole class of
// bug by never reimplementing blind-pairing's usage at all: it boots the
// REAL pear-end/index.js as a module (same technique
// pear-end/test/pairing-real-roundtrip.test.js's bootWorklet() already
// proves out -- stub global.BareKit/global.Bare, require index.js fresh,
// drive it over the exact IPC wire format bare_worklet.dart's real IPC
// uses) and only ever calls its Method.PAIRING_* handlers, which is the
// SAME already-fixed, already-tested code path the phone side runs.
//
// Modules resolve through pear-end's OWN node_modules (pearEndRequire,
// exactly like peer.js's own) so this always runs the exact pinned
// versions the phone-side worklet does -- a second, independently
// `npm install`-ed copy could silently drift to a wire-incompatible minor
// version.
//
// TWO PROCESSES, ONE LOCAL TESTNET: pairing-real-roundtrip.test.js runs its
// "two workers" as two in-process bootWorklet() instances (safe there only
// because that ONE file fully controls both sides' timing). This file is a
// genuine two-OS-process validation instead -- each side is its own `node
// pairing-peer.js` invocation -- so there's no shared JS heap to hand a
// createTestnet() result across. The check script (pairing-peer.check.js)
// creates ONE local hyperdht testnet and passes its `bootstrap` array (plain
// {host,port} objects, confirmed JSON-serializable) to both child processes
// via `--bootstrap <json>`; each process swaps its own required 'hyperswarm'
// export for a subclass that always injects that bootstrap, before ever
// requiring index.js (same swap technique pairing-real-roundtrip.test.js
// uses, just plumbed across a process boundary instead of a shared
// require.cache). A local testnet, not the real internet DHT peer.js's
// chat/--drive modes use, matching this ticket's own explicit guidance
// (local/offline/deterministic, no up-to-60s real-DHT first-connect
// latency to budget for) and the ALREADY-PROVEN pattern this file adapts.
//
// LEARNING THE PEER'S PUBLIC KEY (for CONNECTION_WRITE): blind-pairing's own
// discoveryKey-derived swarm.join() is entirely internal to index.js/
// blind-pairing -- never surfaced over IPC -- and a connection discovered
// ONLY that way never fires index.js's own SWARM_CONNECTION/CONNECTION_DATA
// events, since both are gated on `topics.has(topicHex)`, i.e. a topic THIS
// wrapper's Method.SWARM_JOIN was actually asked to track (see index.js's
// swarm.on('connection', ...) `announce` closure and its CONNECTION_DATA
// onmessage handler). So each side here ALSO calls Method.SWARM_JOIN on an
// ordinary shared topic (hashed from `--topic`, same recipe as peer.js's
// own topicFromString) purely to learn its peer's public key hex via
// SWARM_CONNECTION. This is not a workaround for a missing feature so much
// as it doubles as the whole point of the test: Hyperswarm shares ONE
// physical connection per remote public key across every topic that finds
// it (confirmed against hyperswarm's own source -- every peer-connect guard
// in node_modules/hyperswarm/index.js checks `_allConnections.has(publicKey)`,
// never per-topic), and blind-pairing's own `_attachToSwarm`/`_onconnection`
// (node_modules/blind-pairing/index.js) attach its 'blind-pairing' Protomux
// channel onto WHATEVER connection for that peer already exists, or vice
// versa if the shared-topic connection forms second. Either ordering ends
// up sharing the exact one physical connection/Protomux instance the
// coexistence property under test needs -- confirmed by this file's own
// check script, not just by inspection.
//
// SEQUENCING: each side sends its own Method.CONNECTION_WRITE chat-style
// message only AFTER its own half of the pairing handshake has fully
// flowed over the wire (confirmCandidate's ack on the invite side;
// acceptInvite's own resolved promise, which blind-pairing-core internally
// gates on receiving and signature-verifying the confirm response, on the
// accept side) -- so this is a genuine "pair, THEN chat over the same pipe"
// sequence, not two logically-unrelated channels that merely happen not to
// race.
//
// Run manually (two terminals) for interactive/manual dev sanity-checking:
//   node tool/pairing-peer.js --role invite --topic demo --bootstrap '[{"host":"127.0.0.1","port":PORT}]'
//   node tool/pairing-peer.js --role accept --topic demo --bootstrap '[...]' --invite <base64 printed by the invite side>
// (a real local hyperdht testnet's bootstrap port has to come from
// somewhere -- pairing-peer.check.js is the intended, automated way to run
// this; the two-terminal form above is only useful with a testnet spun up
// by hand, e.g. via `node -e "require('.../pear-end/node_modules/hyperdht/testnet')(3).then(t=>console.log(JSON.stringify(t.bootstrap)))"`.)
//
// Against a REAL PHONE (flutter_pear-g28, integration_test/
// pairing_transport_test.dart): omit --bootstrap entirely so this process
// joins the real DHT instead, e.g.
//   node tool/pairing-peer.js --role invite --topic demo --timeout 150
// then feed the printed `invite: <base64>` line to the phone side (that
// test's own header comment has the full recipe) -- see this file's
// "--bootstrap is OPTIONAL" comment in main() for why no override is needed
// (or possible) on the phone's own end.

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const crypto = require('node:crypto')
const NodeModule = require('node:module')
const { EventEmitter } = require('node:events')
const { createRequire } = require('node:module')

const pearEndRequire = createRequire(
  path.join(__dirname, '..', '..', 'flutter_pear', 'pear-end', 'package.json')
)
const INDEX_PATH = pearEndRequire.resolve('./index.js')

// Matches peer.js's own topicFromString exactly (SHA-256 of the UTF-8
// string) -- not load-bearing to match peer.js's OWN topic room (this
// script never talks to peer.js's chat mode), just the same well-understood
// recipe for turning a human-friendly `--topic` name into a 32-byte topic.
function topicFromString (name) {
  return crypto.createHash('sha256').update(name, 'utf8').digest()
}

function parseArgs (argv) {
  const args = { timeoutMs: 30000 }
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--role':
        args.role = argv[++i]
        break
      case '--topic':
        args.topic = argv[++i]
        break
      case '--bootstrap':
        args.bootstrap = argv[++i]
        break
      case '--storage':
        args.storage = argv[++i]
        break
      case '--invite':
        args.invite = argv[++i]
        break
      case '--timeout': {
        const seconds = Number(argv[++i])
        // Same guard as peer.js's own --timeout parsing, and for the same
        // reason: setTimeout(fn, NaN) fires almost immediately, which would
        // otherwise surface as a confusing early PAIRING_TIMEOUT/event
        // timeout instead of a clear usage error.
        if (!Number.isFinite(seconds) || seconds <= 0) {
          throw new Error(`--timeout must be a positive number of seconds, got: ${argv[i]}`)
        }
        args.timeoutMs = seconds * 1000
        break
      }
      default:
        throw new Error(`unknown argument: ${argv[i]}`)
    }
  }
  if (args.role !== 'invite' && args.role !== 'accept') {
    throw new Error('usage: pairing-peer.js --role invite|accept --topic <name> ' +
      '[--bootstrap <json>] [--storage <dir>] [--invite <base64>] [--timeout <seconds>]')
  }
  if (!args.topic) throw new Error('--topic is required')
  if (args.role === 'accept' && !args.invite) throw new Error('--role accept requires --invite <base64>')
  if (args.role === 'invite' && args.invite) throw new Error('--invite only applies to --role accept')
  return args
}

// Swaps pear-end's own required 'hyperswarm' export for a subclass that
// always injects the given local-testnet bootstrap -- same technique
// pairing-real-roundtrip.test.js uses (its own TestnetHyperswarm), just
// applied via pearEndRequire since this file lives outside pear-end/ and
// must resolve 'hyperswarm' through pear-end's OWN node_modules, not
// whatever (if anything) flutter_pear_example's own node_modules has.
// MUST run before index.js is ever required -- index.js's own top-level
// `new Hyperswarm()` runs at require time, with no options of its own.
function injectTestnetHyperswarm (bootstrap) {
  const Hyperswarm = pearEndRequire('hyperswarm')
  class TestnetHyperswarm extends Hyperswarm {
    constructor (opts = {}) {
      super({ ...opts, bootstrap })
    }
  }
  require.cache[pearEndRequire.resolve('hyperswarm')].exports = TestnetHyperswarm
}

// index.js requires 'bare-fs'/'bare-path' directly (Bare-runtime-only
// packages -- see pear-end/test/index.test.js's identical comment for the
// full why). Pre-seeds Node's require cache with Node-native equivalents,
// resolved through pear-end's own node_modules the same way as above.
function stubBareRuntimeDepsForNode () {
  const nodeFs = require('node:fs')
  const nodeFsPromises = require('node:fs/promises')
  const nodePath = require('node:path')
  const fsStub = { ...nodeFs, ...nodeFsPromises }
  for (const [specifier, stub] of [['bare-fs', fsStub], ['bare-path', nodePath]]) {
    const resolved = pearEndRequire.resolve(specifier)
    if (require.cache[resolved]) continue
    const fakeModule = new NodeModule(resolved, null)
    fakeModule.exports = stub
    fakeModule.loaded = true
    require.cache[resolved] = fakeModule
  }
}

// Boots a fresh instance of index.js's module-level state (its own `swarm`,
// `pairing`, `invites`, ...) against a stubbed IPC pipe -- same wire format
// bare_worklet.dart's real IPC uses (4-byte big-endian length prefix +
// FrameType byte + JSON body), and the same call()/event-matching shape as
// pairing-real-roundtrip.test.js's own bootWorklet(). This is a real,
// separate OS process (unlike that test file's two in-process instances),
// so index.js is only ever required once here -- no require.cache eviction
// needed between an "inviter" and "acceptor" the way that file needs it.
function bootWorklet (storageDir) {
  const ipc = new EventEmitter()
  const writeListeners = new Set()
  ipc.write = (buf) => { for (const listener of writeListeners) listener(buf) }

  global.BareKit = { IPC: ipc }
  global.Bare = {
    argv: [storageDir],
    on: () => {},
    // Never expected to actually fire here (see index.js's own
    // reportCrash: it only runs from Bare.on('uncaughtException'/
    // 'unhandledRejection', both no-ops above, exactly like every other
    // pear-end test harness's stub) -- a real uncaught error in THIS
    // process instead surfaces as Node's own default top-level handling,
    // which is enough for a validation script driven by an external check
    // script watching for a nonzero exit code.
    exit: (code) => { throw new Error('Bare.exit(' + code + ') called unexpectedly') }
  }

  const { Method, EventName, FrameType } = pearEndRequire('./schema')
  require(INDEX_PATH)

  let nextId = 1
  function call (method, params) {
    const id = nextId++
    return new Promise((resolve) => {
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
      const body = Buffer.from(JSON.stringify({ id, m: method, p: params }))
      const frame = Buffer.concat([Buffer.from([FrameType.JSON]), body])
      const lengthPrefix = Buffer.alloc(4)
      lengthPrefix.writeUInt32BE(frame.length, 0)
      ipc.emit('data', Buffer.concat([lengthPrefix, frame]))
    })
  }

  // Every event this worklet instance ever emits is buffered here, in
  // arrival order -- not just whatever a waitForEvent() call happens to be
  // listening for at the moment it fires. Unlike pairing-real-roundtrip.
  // test.js's in-process onEvent() (safe there only because that ONE file
  // drives both sides' timing itself, so it always calls onEvent() before
  // the event it wants could possibly fire), THIS script's events cross a
  // real network boundary to a genuinely independent process -- a peer
  // connecting, a candidate pairing, or app data arriving can all land at
  // any time relative to when this script gets around to awaiting them. A
  // one-shot "register a listener, then await" helper would silently miss
  // anything that already arrived and hang forever; checking the buffer
  // first is what makes waitForEvent() below correct regardless of timing.
  const eventLog = []
  const waiters = []
  const onEventFrame = (buf) => {
    if (buf.length < 5 || buf[4] !== FrameType.JSON) return
    const len = buf.readUInt32BE(0)
    let msg
    try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
    if (!msg.ev) return
    // Opt-in, not always-on -- this is what made both real bugs documented
    // below traceable in the first place (the full event timeline on both
    // sides is what showed which side's discovery/routing state was
    // actually stale at the moment a message got dropped).
    if (process.env.PAIRING_PEER_DEBUG) console.error(`[event] ${msg.ev} ${JSON.stringify(msg.p)}`)
    eventLog.push(msg)
    for (let i = waiters.length - 1; i >= 0; i--) {
      if (waiters[i].matcher(msg)) {
        const [waiter] = waiters.splice(i, 1)
        clearTimeout(waiter.timer)
        waiter.resolve(msg)
      }
    }
  }
  writeListeners.add(onEventFrame)

  function waitForEvent (matcher, timeoutMs) {
    const already = eventLog.find(matcher)
    if (already) return Promise.resolve(already)
    return new Promise((resolve, reject) => {
      const waiter = {
        matcher,
        resolve,
        timer: setTimeout(() => {
          const idx = waiters.indexOf(waiter)
          if (idx !== -1) waiters.splice(idx, 1)
          reject(new Error('timed out waiting for a matching event'))
        }, timeoutMs)
      }
      waiters.push(waiter)
    })
  }

  // Subscribes to every future matching event, not just the next one (same
  // shape as pairing-real-roundtrip.test.js's own onAnyEvent) -- used below
  // for the CONNECTION_DATA auto-ack responder, which must react to EVERY
  // delivery for as long as this process runs, not just the first. Replays
  // anything already buffered too, for the same reason waitForEvent checks
  // eventLog first.
  function onAnyEvent (matcher, cb) {
    for (const msg of eventLog) if (matcher(msg)) cb(msg)
    const listener = (buf) => {
      if (buf.length < 5 || buf[4] !== FrameType.JSON) return
      const len = buf.readUInt32BE(0)
      let msg
      try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
      if (!msg.ev || !matcher(msg)) return
      cb(msg)
    }
    writeListeners.add(listener)
    return () => writeListeners.delete(listener)
  }

  return { call, waitForEvent, onAnyEvent, Method, EventName }
}

async function main () {
  const args = parseArgs(process.argv.slice(2))
  // --bootstrap is OPTIONAL (flutter_pear-g28): when omitted, index.js's own
  // unmodified `new Hyperswarm()` runs against the real, public DHT --
  // required to talk to a REAL PHONE, since pear-end's bundled worklet
  // (lib/src/pear.dart's `Pear.start()`) boots the exact same index.js with
  // no options of its own and therefore no way to point it at a private
  // testnet (same constraint documented in integration_test/
  // bee_transport_test.dart and drive_transport_test.dart's own header
  // comments). Mirrors peer.js's own optional `--bootstrap` precedent
  // exactly, just with this file's pre-existing JSON array shape (needed
  // for pairing-peer.check.js's own local-testnet bootstrap array) instead
  // of peer.js's `host:port,...` shorthand. pairing-peer.check.js's real,
  // local-testnet round trip keeps passing unmodified -- it always passes
  // --bootstrap explicitly.
  if (args.bootstrap) injectTestnetHyperswarm(JSON.parse(args.bootstrap))
  stubBareRuntimeDepsForNode()

  const storageDir = args.storage || fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-pear-pairing-peer-'))
  const { call, waitForEvent, onAnyEvent, Method, EventName } = bootWorklet(storageDir)

  process.on('SIGINT', () => process.exit(0))

  const topicHex = topicFromString(args.topic).toString('hex')

  // REAL BUG FOUND while building this harness (new to this investigation,
  // not covered by any prior ticket's notes): Method.SWARM_JOIN's peer
  // discovery is effectively ONE-SHOT within any test-sized time window,
  // not a continuous background search, so whichever side joins a shared
  // topic FIRST reliably fails to discover the other. hyperswarm's
  // PeerDiscovery (node_modules/hyperswarm/lib/peer-discovery.js) only
  // re-runs its announce/lookup DHT query on a REFRESH_INTERVAL of 10
  // minutes (+ up to 2 minutes of jitter) after the ONE query
  // swarm.join()'s own initial refresh() triggers -- confirmed by reading
  // that file's own constants and _refresh/_refreshLater. Since
  // {server:true,client:true} makes that one query BOTH announce this side
  // AND surface any peer already found in the process (`this._onpeer` still
  // runs against the announce query's own result stream when `isClient` is
  // true), it can only discover a peer whose OWN announce record already
  // existed in the DHT at that single moment -- whichever side's one query
  // runs chronologically first finds nothing (nobody's announced yet) and
  // then has no real chance again for ~10+ minutes.
  //
  // First fix attempted and REJECTED: having the invite side delay its own
  // join until after receiving Method.PAIRING_CANDIDATE (reasoning: by then
  // the accept side must already be alive and already joined). Sounds
  // right, but only moves the asymmetry around instead of removing it --
  // confirmed empirically: it flipped which side timed out (accept, now the
  // structurally-first joiner) rather than fixing both. The two sides'
  // relative join order can't be pinned down as "invite first" or "accept
  // first" in general (it depends on exactly this kind of protocol-level
  // ordering assumption, which is fragile and, as just demonstrated, easy
  // to get backwards) -- so ordering alone can never make BOTH sides the
  // second joiner.
  //
  // Actual fix: retry. Method.SWARM_LEAVE followed by a fresh
  // Method.SWARM_JOIN starts an entirely new PeerDiscovery session (a brand
  // new swarm.join() call), which runs its own fresh, immediate query --
  // unlike calling Method.SWARM_JOIN again for a topic already in `topics`,
  // which index.js's own handler treats as a no-op ack, not a real rejoin.
  // Polling "join, wait a few seconds, leave, rejoin" until
  // Method.SWARM_CONNECTION fires means BOTH sides keep getting fresh
  // chances, so within a couple of short cycles one side's fresh query is
  // guaranteed to land after the other's most recent announce -- no
  // dependency on which side started first. Safe to leave/rejoin freely
  // here because blind pairing keeps the underlying connection alive on its
  // own separate discoveryKey-based join (its own Member/Candidate object,
  // untouched by anything this loop does) regardless of what this shared
  // topic's own join/leave state is doing.
  //
  // This is *why* the shared topic is joined at all, independent of blind
  // pairing's own discoveryKey-based swarm.join(): see this file's header
  // comment's own "LEARNING THE PEER'S PUBLIC KEY" section for why
  // Method.SWARM_CONNECTION (gated on a topic Method.SWARM_JOIN actually
  // registered) is this script's only IPC-visible way to learn a connected
  // peer's public key hex at all.
  const REJOIN_INTERVAL_MS = 3000
  async function joinSharedTopicAndWaitForPeer () {
    const deadline = Date.now() + args.timeoutMs
    for (;;) {
      const joinRes = await call(Method.SWARM_JOIN, { topic: topicHex })
      if (joinRes.err) throw new Error('swarm.join failed: ' + JSON.stringify(joinRes.err))
      const remainingMs = deadline - Date.now()
      if (remainingMs <= 0) throw new Error('timed out waiting for a shared-topic peer connection')
      try {
        const event = await waitForEvent(
          (msg) => msg.ev === EventName.SWARM_CONNECTION && msg.p.topic === topicHex,
          Math.min(REJOIN_INTERVAL_MS, remainingMs)
        )
        return event.p.peer
      } catch {
        // No SWARM_CONNECTION within this attempt's window -- force a fresh
        // discovery query (see the comment above) and try again.
        await call(Method.SWARM_LEAVE, { topic: topicHex })
      }
    }
  }
  const peerHexPromise = joinSharedTopicAndWaitForPeer()

  let confirmedKeyBase64
  if (args.role === 'invite') {
    const createRes = await call(Method.PAIRING_CREATE_INVITE, {})
    if (createRes.err) throw new Error('pairing.createInvite failed: ' + JSON.stringify(createRes.err))
    const { invite, inviteId } = createRes.ok
    // stdout: the one line the check script (or a human on the other
    // terminal) needs to copy to the accept side. Everything else is
    // progress/diagnostic noise on stderr, same stdout/stderr split as
    // peer.js's own chat mode.
    console.log(`invite: ${invite}`)
    console.error(`inviteId: ${inviteId}`)

    const candidateEvent = await waitForEvent(
      (msg) => msg.ev === EventName.PAIRING_CANDIDATE && msg.p.inviteId === inviteId,
      args.timeoutMs
    )
    console.error(`candidate: ${candidateEvent.p.candidateId} (userData: ${candidateEvent.p.userData || '<empty>'})`)

    const confirmKey = crypto.randomBytes(32)
    const confirmRes = await call(Method.PAIRING_CONFIRM_CANDIDATE, {
      inviteId,
      candidateId: candidateEvent.p.candidateId,
      key: confirmKey.toString('base64')
    })
    if (confirmRes.err) throw new Error('pairing.confirmCandidate failed: ' + JSON.stringify(confirmRes.err))
    confirmedKeyBase64 = confirmKey.toString('base64')
    console.log(`confirmed: ${confirmedKeyBase64}`)
  } else {
    const acceptRes = await call(Method.PAIRING_ACCEPT_INVITE, { invite: args.invite, timeoutMs: args.timeoutMs })
    if (acceptRes.err) throw new Error('pairing.acceptInvite failed: ' + JSON.stringify(acceptRes.err))
    confirmedKeyBase64 = acceptRes.ok.key
    console.log(`paired: ${confirmedKeyBase64}`)
  }

  const peerHex = await peerHexPromise
  console.error(`peer: ${peerHex.slice(0, 8)}…`)

  // The HIGH-PRIORITY, distinct property flutter_pear-doi's own notes call
  // out: Method.CONNECTION_WRITE/CONNECTION_DATA over the SAME connection
  // BlindPairing's own Protomux channel just negotiated a real pairing on,
  // sent only now that this side's own half of the pairing handshake has
  // fully flowed over the wire (see this file's header comment's
  // "SEQUENCING" note).
  //
  // SECOND REAL BUG FOUND while building this harness, root-caused with a
  // Protomux-level instrumentation pass (temporarily wrapping
  // Protomux.prototype.createChannel to log every raw arrival/send on the
  // 'pear-connection-data' channel, bypassing index.js's own routing to see
  // whether bytes even reached the transport): a naive "send once, wait for
  // ANY reply, resend on our own timeout" loop reliably lost the message in
  // ONE direction, every run. The raw instrumentation showed the accept
  // side's bytes DID physically arrive at the invite side's Protomux layer,
  // correctly decoded -- but index.js's own CONNECTION_DATA onmessage
  // handler never called send() for them, so no event ever reached this
  // script. Root cause: that handler's forwarding check
  // (`for (const topicBuf of info.topics) if (topics.has(topicHex)) send(...)`)
  // needs THIS SPECIFIC PEER's own info.topics to already include our
  // shared topic -- which is populated only once THIS side's own discovery
  // of THAT peer via that topic completes (hyperswarm's peerInfo._topic(),
  // confirmed by reading node_modules/hyperswarm/lib/peer-info.js), i.e.
  // only once this side's own Method.SWARM_CONNECTION for that peer has
  // already fired. A message physically arriving before that -- entirely
  // possible here, since the sender's own discovery can easily finish
  // before the receiver's does (see the discovery-timing bug above) -- is
  // silently and PERMANENTLY dropped: no buffering, no redelivery, nothing
  // for a naive resend to ever recover, because the retry was gated on "did
  // I myself receive a reply", not "did the peer actually get my message".
  // Once one side happened to succeed first, it stopped resending entirely
  // (mission accomplished, from its own point of view) -- silently
  // abandoning the other side, which could then wait forever for a message
  // that will never be sent again. This is a real, previously-unverified
  // (per E5.6's own review notes) property of the real wire path, not a
  // defect in a fake -- worth knowing for any real app that joins a topic
  // slightly late relative to when a peer discovered via a DIFFERENT topic
  // (exactly this scenario: blind pairing's own discoveryKey vs. this
  // shared topic) already has data to send.
  //
  // Fixed with an explicit application-level ack, not a bigger timeout or
  // more retries: only stop sending once the PEER has proven receipt, not
  // once we ourselves are satisfied. Whoever receives a non-ack message
  // immediately (and repeatedly, for every duplicate delivery -- the
  // peer's own retries may not have seen an earlier ack yet) echoes it back
  // prefixed with `ack:`; whoever is sending keeps resending its own
  // message until it sees its own content come back that way. This is the
  // one piece of real protocol design this harness needed beyond what
  // index.js's own contract provides -- CONNECTION_WRITE/DATA has no
  // built-in delivery acknowledgement of its own, same as a raw datagram
  // primitive, so an app relying on "the peer got this" has to build one,
  // exactly like this script now does.
  const RESEND_INTERVAL_MS = 1500
  const outgoingContent = `hello from ${args.role} over the paired connection`
  const ackForOutgoing = `ack:${outgoingContent}`

  function sendText (text) {
    return call(Method.CONNECTION_WRITE, { peer: peerHex, data: Buffer.from(text, 'utf8').toString('base64') })
  }
  function decodeData (msg) {
    return Buffer.from(msg.p.data, 'base64').toString('utf8')
  }

  const isDataFromPeer = (msg) => msg.ev === EventName.CONNECTION_DATA && msg.p.peer === peerHex
  // Auto-ack responder: fires for as long as this process runs, not just
  // once -- see the comment above on why every duplicate delivery needs its
  // own ack, not just the first.
  onAnyEvent(
    (msg) => isDataFromPeer(msg) && !decodeData(msg).startsWith('ack:'),
    (msg) => { sendText(`ack:${decodeData(msg)}`).catch(() => {}) }
  )

  const peerContentPromise = waitForEvent(
    (msg) => isDataFromPeer(msg) && !decodeData(msg).startsWith('ack:'),
    args.timeoutMs
  ).then(decodeData)

  // THIRD REAL BUG FOUND while building this harness's real-device leg
  // (flutter_pear-g28, against a real phone-side worklet over the real DHT
  // -- not reproduced on pairing-peer.check.js's fast local testnet):
  // Method.CONNECTION_WRITE can transiently answer UNKNOWN_PEER even
  // moments after this SAME peer's own Method.SWARM_CONNECTION already
  // fired -- confirmed with PAIRING_PEER_DEBUG=1's full event timeline. The
  // connection this side just learned about can close and re-form
  // (ordinary real-network churn, e.g. a duplicate simultaneous-connect
  // race -- both sides run {server:true,client:true}) in the gap between
  // that event firing and this call reaching index.js: `conn.on('close')`
  // there empties its connectionChannels entry immediately, repopulated
  // only once a reconnect's own swarm.on('connection', ...) reruns.
  // Treating this exactly like a missing ack -- resend on the same
  // RESEND_INTERVAL_MS cadence, not a fatal throw -- is correct: confirmed
  // empirically that a later resend succeeds once index.js's map is
  // repopulated, so this is a real but momentary race, not a permanent
  // failure.
  const ackDeadline = Date.now() + args.timeoutMs
  for (;;) {
    const writeRes = await sendText(outgoingContent)
    if (writeRes.err && writeRes.err.code !== 'UNKNOWN_PEER') {
      throw new Error('connection.write failed: ' + JSON.stringify(writeRes.err))
    }
    const remainingMs = ackDeadline - Date.now()
    if (remainingMs <= 0) throw new Error('timed out waiting for the peer to ack connection.data')
    if (writeRes.err) {
      // The write itself never reached the peer -- nothing to wait for an
      // ack on; just pace the retry the same as the ack-wait branch below.
      await new Promise((resolve) => setTimeout(resolve, Math.min(RESEND_INTERVAL_MS, remainingMs)))
      continue
    }
    try {
      await waitForEvent(
        (msg) => isDataFromPeer(msg) && decodeData(msg) === ackForOutgoing,
        Math.min(RESEND_INTERVAL_MS, remainingMs)
      )
      break
    } catch {
      // No ack within this window -- resend (see the comment above).
    }
  }

  const received = await peerContentPromise
  console.log(`app-data: ${received}`)

  console.error(`${args.role} done -- waiting to be terminated by the caller`)
  // Deliberately does not self-exit: index.js exposes no RPC method to tear
  // down its own swarm/pairing/store (out of scope for this validation
  // tool), so there is nothing graceful this script itself can call --
  // pairing-peer.check.js (or a developer's Ctrl-C) is what ends this
  // process, same as peer.js's own long-running modes.
}

main().catch((err) => {
  console.error(err.message || err)
  // An explicit process.exit(1), not just process.exitCode = 1 -- by the
  // time most failures here are possible, bootWorklet() has already opened
  // real sockets (the swarm's DHT/connections), which keep the event loop
  // (and therefore the process) alive on their own; nothing here needs a
  // graceful drain first (see main()'s own closing comment on why this
  // script has no swarm teardown to run), so exiting immediately is correct.
  process.exit(1)
})
