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

const path = require('node:path')
const crypto = require('node:crypto')
const readline = require('node:readline')
const { createRequire } = require('node:module')

const pearEndRequire = createRequire(
  path.join(__dirname, '..', '..', 'flutter_pear', 'pear-end', 'package.json')
)
const Hyperswarm = pearEndRequire('hyperswarm')
const Protomux = pearEndRequire('protomux')
const c = pearEndRequire('compact-encoding')

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
      default:
        throw new Error(`unknown argument: ${argv[i]}`)
    }
  }
  if (!args.topic) {
    throw new Error('usage: peer.js --topic <name> [--timeout <seconds>]')
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

  swarm.join(topic, { server: true, client: true })
  console.error(`topic: ${topic.toString('hex')}`)
  console.error('waiting for a peer... (type a line + Enter to send once connected; Ctrl-C to quit)')
}

main().catch((err) => {
  console.error(err.message || err)
  process.exit(1)
})
