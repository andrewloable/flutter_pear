#!/usr/bin/env node
'use strict'

// E7.3 (X7): the desktop half of the "one-phone dev" story -- a second peer
// for flutter_pear's example chat that runs on the developer's laptop
// instead of a second phone, and doubles as a scriptable CI peer.
//
// Deliberately plain Node, not a Bare worklet: there is no Flutter/platform
// channel to bridge to here, so none of pear-end's BareKit.IPC glue
// applies -- this talks Hyperswarm/Protomux directly, the same libraries
// pear-end/index.js wraps for the mobile worklet. Modules resolve through
// pear-end's OWN node_modules (see pearEndRequire below) rather than a
// second copy, so this peer is always running the exact same pinned
// versions the phone side does -- a second, independently `npm install`-ed
// copy could silently drift to a wire-incompatible minor version.
//
// Topic mode only (`--topic <name>`) -- an invite-based mode
// (`--invite`/`--create-invite`, joining via a PearPairing invite instead
// of a shared string) was attempted and pulled before shipping: it
// consistently failed blind-pairing's own MemberRequest.open() decrypt/
// signature check ("Failed to open invite with provided key") even after
// fixing two real bugs along the way (passing resourceKey instead of
// createInvite's returned publicKey to request.open(); passing undefined
// instead of an explicit Buffer.alloc(0) for userData) -- reproduced even
// in a same-process, no-network unit repro, so this isn't network flakiness.
// Tracked as flutter_pear-<TBD> for follow-up; the phone side doesn't have
// an invite-creation UI yet either (that's E7.2), so nothing regresses by
// shipping topic mode alone now.
//
// --drive mode (flutter_pear-d5w): acts as a file-drop peer instead of a
// chat peer -- opens/creates a Hyperdrive, exchanges its key with whoever
// connects over the SAME 'pear-connection-data' Protomux channel chat mode
// uses (confirmed via index.js: Method.CONNECTION_WRITE/CONNECTION_DATA and
// file_drop_screen.dart's drive-key announcement both ultimately go through
// the one per-connection message on that channel -- there's no separate
// wire protocol to match, just a different payload), replicates both
// directions (chained core-then-blobs replication onto the same stream,
// matching index.js's own replicateOverPeer), and can --put a local file
// into its drive or --mirror-to a directory once it learns a peer's drive
// key. Exists because tool/peer.js's chat mode has no Hyperdrive support of
// its own, and there was previously no way to validate E7.7's file-drop
// phone<->desktop leg without two physical phones.

const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const crypto = require('node:crypto')
const readline = require('node:readline')
const { pipeline } = require('node:stream/promises')
const { createRequire } = require('node:module')

const pearEndRequire = createRequire(
  path.join(__dirname, '..', '..', 'flutter_pear', 'pear-end', 'package.json')
)
const Hyperswarm = pearEndRequire('hyperswarm')
const Protomux = pearEndRequire('protomux')
const c = pearEndRequire('compact-encoding')
const Corestore = pearEndRequire('corestore')
const Hyperdrive = pearEndRequire('hyperdrive')
const Localdrive = pearEndRequire('localdrive')

// Matches PearCrypto.unsafeTopicFromString exactly (SHA-256 of the UTF-8
// string) so `--topic <name>` lands in the same room as the phone demo's
// "Shared room name" field.
function topicFromString (name) {
  return crypto.createHash('sha256').update(name, 'utf8').digest()
}

function parseArgs (argv) {
  const args = { timeoutMs: 30000 }
  for (let i = 0; i < argv.length; i++) {
    switch (argv[i]) {
      case '--topic':
        args.topic = argv[++i]
        break
      case '--timeout': {
        const seconds = Number(argv[++i])
        // A malformed/missing value must fail loudly here, not become NaN
        // -- setTimeout(fn, NaN) fires almost immediately, which would
        // otherwise surface as a spurious "no peer connected" instead of a
        // usage error.
        if (!Number.isFinite(seconds) || seconds <= 0) {
          throw new Error(`--timeout must be a positive number of seconds, got: ${argv[i]}`)
        }
        args.timeoutMs = seconds * 1000
        break
      }
      case '--drive':
        args.drive = true
        break
      case '--put':
        args.put = argv[++i]
        break
      case '--mirror-to':
        args.mirrorTo = argv[++i]
        break
      case '--storage':
        args.storage = argv[++i]
        break
      default:
        throw new Error(`unknown argument: ${argv[i]}`)
    }
  }
  if (!args.topic) {
    throw new Error('usage: peer.js --topic <name> [--timeout <seconds>] ' +
      '[--drive [--put <file>] [--mirror-to <dir>] [--storage <dir>]]')
  }
  if ((args.put || args.mirrorTo || args.storage) && !args.drive) {
    throw new Error('--put/--mirror-to/--storage only apply with --drive')
  }
  return args
}

async function main () {
  const args = parseArgs(process.argv.slice(2))
  const swarm = new Hyperswarm()
  // destroy() rejecting must never hang the process -- this tool's entire
  // point is a reliable exit code (CI usability), so both destroy() sites
  // below force the intended exit regardless of how destroy() itself
  // settles.
  process.on('SIGINT', () => {
    swarm.destroy().catch(() => {}).then(() => process.exit(0))
  })

  const topic = topicFromString(args.topic)
  if (args.drive) await runDrive(args, swarm, topic)
  else runChat(args, swarm, topic)

  swarm.join(topic, { server: true, client: true })
  console.error(`topic: ${topic.toString('hex')}`)
}

// Original chat mode -- unchanged.
function runChat (args, swarm, topic) {
  let connected = false
  // A single readline interface + a rebindable "current" message channel,
  // not one interface per connection -- stdin is one stream regardless of
  // how many times a peer reconnects, and re-creating the interface on
  // every reconnect would stack duplicate 'line' listeners (each firing on
  // every future line) plus an eventual MaxListenersExceededWarning.
  let currentMessage = null
  readline.createInterface({ input: process.stdin }).on('line', (line) => {
    currentMessage?.send(Buffer.from(line, 'utf8'))
  })
  const connectTimer = setTimeout(() => {
    if (connected) return
    console.error(`no peer connected within ${args.timeoutMs}ms`)
    process.exitCode = 1
    swarm.destroy().catch(() => {}).then(() => process.exit(1))
  }, args.timeoutMs)

  // Raw app data must go through a Protomux channel, not conn.write()/
  // conn.on('data') directly -- pear-end wraps every connection in
  // Protomux too (for blind-pairing's own use of the same stream), and a
  // second independent raw listener would see bytes Protomux's framing
  // doesn't recognize and destroy the connection (see index.js's own
  // comment on this for the full story). Same protocol name and encoding
  // as pear-end's Method.CONNECTION_DATA/CONNECTION_WRITE handling, so this
  // peer and a phone's PearConnection.write/.data interoperate.
  swarm.on('connection', (conn, info) => {
    connected = true
    clearTimeout(connectTimer)
    console.error(`connected to ${info.publicKey.toString('hex').slice(0, 8)}…`)

    const mux = Protomux.from(conn)
    const channel = mux.createChannel({ protocol: 'pear-connection-data' })
    const message = channel.addMessage({
      encoding: c.buffer,
      onmessage (data) {
        console.log(`peer: ${data.toString('utf8')}`)
      }
    })
    channel.open()
    currentMessage = message

    conn.on('close', () => {
      if (currentMessage === message) currentMessage = null
      console.error('peer disconnected')
    })
  })

  console.error('waiting for a peer... (type a line + Enter to send once connected; Ctrl-C to quit)')
}

// --drive mode (flutter_pear-d5w).
async function runDrive (args, swarm, topic) {
  const storageDir = args.storage || fs.mkdtempSync(path.join(os.tmpdir(), 'flutter-pear-peer-drive-'))
  const store = new Corestore(storageDir)
  const drive = new Hyperdrive(store)
  await drive.ready()
  console.error(`drive key: ${drive.key.toString('hex')}`)

  if (args.put) {
    const name = path.basename(args.put)
    // Streamed via createWriteStream, not put(name, buffer) -- matches
    // PearDrive.put's own local-file-path/never-in-memory contract
    // (BENCHMARK.md's locked bulk-transfer decision), so a --put of a
    // large file behaves the same way on this side as it does on the
    // phone's.
    await pipeline(fs.createReadStream(args.put), drive.createWriteStream('/' + name))
    console.error(`put /${name} (${fs.statSync(args.put).size} bytes) into the drive`)
  }

  let done = false
  const finish = (code) => {
    if (done) return
    done = true
    clearTimeout(connectTimer)
    swarm.destroy().catch(() => {}).then(() => process.exit(code))
  }

  let connected = false
  const connectTimer = setTimeout(() => {
    if (connected) return
    console.error(`no peer connected within ${args.timeoutMs}ms`)
    finish(1)
  }, args.timeoutMs)

  swarm.on('connection', (conn, info) => {
    onConnection(conn, info).catch((err) => console.error('connection handling failed:', err.message))
  })

  async function onConnection (conn, info) {
    connected = true
    clearTimeout(connectTimer)
    console.error(`connected to ${info.publicKey.toString('hex').slice(0, 8)}…`)

    // Chained exactly like index.js's replicateOverPeer: each core's
    // replicate() is passed the PREVIOUS call's returned stream as `base`,
    // not `conn` again -- multiple cores multiplexing onto one connection
    // via Protomux depends on this chain, not on each call getting its own
    // independent stream. AWAITED fully (not drive.getBlobs().then(...) left
    // to resolve whenever) before the channel below can possibly receive the
    // peer's key -- otherwise onPeerDriveKey could chain the peer's drive
    // onto a `base` that doesn't yet include our own blobs replication, a
    // real, empirically-hit race (intermittent "mirrored into" timeout in
    // tool/peer.check.js's drive round-trip check).
    let base = drive.core.replicate(conn)
    const blobs = await drive.getBlobs()
    base = blobs.core.replicate(base)

    const mux = Protomux.from(conn)
    const channel = mux.createChannel({ protocol: 'pear-connection-data' })
    const message = channel.addMessage({
      encoding: c.buffer,
      onmessage: (data) => {
        onPeerDriveKey(data).catch((err) => console.error('peer drive-key handling failed:', err.message))
      }
    })
    channel.open()
    message.send(Buffer.from(drive.key.toString('hex'), 'utf8'))

    async function onPeerDriveKey (data) {
      const peerKeyHex = data.toString('utf8')
      const peerKey = Buffer.from(peerKeyHex, 'hex')
      if (peerKey.length !== 32) {
        console.error(`bad drive-key announcement from peer (expected 32 bytes, got ${peerKey.length}): ${peerKeyHex}`)
        return
      }
      console.error(`learned peer's drive key: ${peerKeyHex.slice(0, 8)}…`)
      const peerDrive = new Hyperdrive(store, peerKey)
      await peerDrive.ready()
      base = peerDrive.core.replicate(base)
      const peerBlobs = await peerDrive.getBlobs()
      base = peerBlobs.core.replicate(base)

      if (args.mirrorTo) {
        fs.mkdirSync(args.mirrorTo, { recursive: true })
        const localDrive = new Localdrive(args.mirrorTo)
        // mirror-drive (the Pear ecosystem's own tool for this) streams
        // and diffs -- only changed files actually copy, same as
        // PearDrive.mirrorToDisk on the phone side.
        const mirror = peerDrive.mirror(localDrive)
        await mirror.done()
        console.error(
          `mirrored into ${args.mirrorTo}: ${mirror.count.add} added, ` +
          `${mirror.count.change} changed, ${mirror.count.remove} removed`
        )
        finish(0)
      }
    }

    conn.on('close', () => console.error('peer disconnected'))
  }

  console.error(`drive mode -- storage: ${storageDir}`)
  if (!args.put && !args.mirrorTo) {
    console.error('neither --put nor --mirror-to given -- will connect and replicate, then wait for Ctrl-C')
  } else if (!args.mirrorTo) {
    console.error('no --mirror-to given -- will stay running so a peer can pull the --put file; Ctrl-C to quit')
  }
}

main().catch((err) => {
  console.error(err.message || err)
  process.exit(1)
})
