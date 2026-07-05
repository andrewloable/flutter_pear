#!/usr/bin/env node
'use strict'

// Runnable check for pairing-peer.js (flutter_pear-doi / flutter_pear-2vz.6's
// deferred real-device leg) -- a real two-process blind-pairing invite
// create/accept round trip over an actual (local) Hyperswarm connection, not
// a stub, mirroring peer.check.js's own checkRoundTrip/checkDriveRoundTrip
// structure: spawn two real child processes, wait for real events, assert
// real, content-exact behavior.
//
// Own local hyperdht testnet (not the real internet DHT peer.check.js's
// other two checks use): this file creates ONE testnet and hands its
// `bootstrap` array to both child processes via `--bootstrap <json>`, since
// they're independent OS processes with no shared JS heap -- see
// pairing-peer.js's own header comment for the full rationale (deterministic,
// fast, no real-network first-connect latency to budget for, and this is
// the exact technique pear-end/test/pairing-real-roundtrip.test.js already
// proved out for real, non-fake blind-pairing).
//
// Plain assert-based script, not `node --test` -- same reason as
// peer.check.js's own (real DHT-adjacent bootstrap from inside node's
// test-runner child processes was observed hanging far longer than an
// identical spawn from a plain script in this environment).
//
// Run directly: `node tool/pairing-peer.check.js`.

const assert = require('node:assert/strict')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')
const { createRequire } = require('node:module')

const pearEndRequire = createRequire(
  path.join(__dirname, '..', '..', 'flutter_pear', 'pear-end', 'package.json')
)
const createTestnet = pearEndRequire('hyperdht/testnet')

const PAIRING_PEER_JS = path.join(__dirname, 'pairing-peer.js')

function tmpDir (prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix))
}

function spawnPairingPeer (args) {
  const child = spawn('node', [PAIRING_PEER_JS, ...args], { stdio: ['ignore', 'pipe', 'pipe'] })
  let stdout = ''
  let stderr = ''
  child.stdout.on('data', (d) => { stdout += d })
  child.stderr.on('data', (d) => { stderr += d })
  return {
    child,
    stdout: () => stdout,
    stderr: () => stderr,
    waitFor (predicate, timeoutMs) {
      return new Promise((resolve, reject) => {
        const start = Date.now()
        const poll = setInterval(() => {
          if (predicate(stdout, stderr)) {
            clearInterval(poll)
            resolve()
          } else if (child.exitCode !== null) {
            // Failed and exited already -- keep waiting would just hang
            // until timeoutMs for no reason; surface the real failure now,
            // with its actual output attached.
            clearInterval(poll)
            reject(new Error(`process exited (code ${child.exitCode}) before matching; stdout=${stdout} stderr=${stderr}`))
          } else if (Date.now() - start > timeoutMs) {
            clearInterval(poll)
            reject(new Error(`timed out waiting; stdout=${stdout} stderr=${stderr}`))
          }
        }, 200)
      })
    }
  }
}

async function checkPairingRoundTrip () {
  const testnet = await createTestnet(3)
  const bootstrap = JSON.stringify(testnet.bootstrap)
  const storageA = tmpDir('flutter-pear-pairing-check-storeA-')
  const storageB = tmpDir('flutter-pear-pairing-check-storeB-')

  // Generous but not peer.check.js's real-DHT-sized bounds (up to 60s) --
  // a local testnet's own DHT rendezvous is fast and deterministic, so a
  // much smaller bound still gives real signal without being flaky.
  const timeoutSeconds = '20'
  const timeoutMs = 20000

  let inviter
  let acceptor
  try {
    inviter = spawnPairingPeer([
      '--role', 'invite', '--topic', 'pairing-peer-check', '--bootstrap', bootstrap,
      '--storage', storageA, '--timeout', timeoutSeconds
    ])
    await inviter.waitFor((out) => /^invite: (\S+)$/m.test(out), timeoutMs)
    const invite = inviter.stdout().match(/^invite: (\S+)$/m)[1]

    acceptor = spawnPairingPeer([
      '--role', 'accept', '--topic', 'pairing-peer-check', '--bootstrap', bootstrap,
      '--storage', storageB, '--invite', invite, '--timeout', timeoutSeconds
    ])

    // (a) invite created on one process, accepted on the other, paired
    // connection exchanges the confirmed key end to end over a real
    // DHT/discovery-channel handshake -- not the fake's in-memory hub.
    await inviter.waitFor((out) => /^confirmed: (\S+)$/m.test(out), timeoutMs)
    await acceptor.waitFor((out) => /^paired: (\S+)$/m.test(out), timeoutMs)
    const confirmedKey = inviter.stdout().match(/^confirmed: (\S+)$/m)[1]
    const pairedKey = acceptor.stdout().match(/^paired: (\S+)$/m)[1]
    assert.equal(pairedKey, confirmedKey, 'the accepting process must receive exactly the key the inviting process confirmed')
    console.log('ok: real two-process blind-pairing invite create/accept round trip confirmed the same key on both sides')

    // (b) HIGH PRIORITY, distinct property (flutter_pear-doi's own notes):
    // Method.CONNECTION_WRITE/CONNECTION_DATA (the raw app-data channel)
    // still delivers bytes correctly over the SAME live connection
    // BlindPairing's own Protomux channel just used -- proving E5.6's
    // review-fix (routing app data through its own 'pear-connection-data'
    // Protomux channel instead of a raw conn.on('data')/conn.write(), so it
    // coexists with BlindPairing's own Protomux wrapper instead of
    // colliding and destroying the connection) actually holds under a
    // real two-process round trip, not just by code inspection. Delivery
    // itself needs an application-level ack/resend loop on pairing-peer.js's
    // own side to be reliable (see that file's own SECOND REAL BUG comment)
    // -- this assertion is what actually proves that loop converges for
    // real, not just that it doesn't throw.
    await inviter.waitFor((out) => out.includes('app-data: hello from accept over the paired connection'), timeoutMs)
    await acceptor.waitFor((out) => out.includes('app-data: hello from invite over the paired connection'), timeoutMs)
    console.log('ok: connection.write/connection.data delivered bytes correctly, content-exact, over the SAME connection BlindPairing just paired on')
  } finally {
    inviter?.child.kill('SIGKILL')
    acceptor?.child.kill('SIGKILL')
    await testnet.destroy().catch(() => {})
    for (const dir of [storageA, storageB]) fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function main () {
  await checkPairingRoundTrip()
}

main().catch((err) => {
  console.error('FAILED:', err.message || err)
  process.exit(1)
})
