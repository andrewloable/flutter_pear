#!/usr/bin/env node
'use strict'

// Runnable check for peer.js (E7.3, X7): a real two-process round trip over
// Hyperswarm/Protomux -- not a stub -- since the entire point of this file
// is proving two independent Node processes on the same topic actually
// interop with the same wire protocol pear-end's worklet speaks. Also
// covers the CI-usability contract: nonzero exit on connect timeout.
//
// Plain assert-based script, not `node --test`: real DHT bootstrap from
// inside node's test-runner child processes was observed hanging far
// longer than the identical spawn from a plain script or shell background
// job in this environment (undiagnosed, but consistently reproducible) --
// a plain script sidesteps whatever that interaction is.
//
// Run directly: `node tool/peer.check.js`.

const assert = require('node:assert/strict')
const crypto = require('node:crypto')
const fs = require('node:fs')
const os = require('node:os')
const path = require('node:path')
const { spawn } = require('node:child_process')

const PEER_JS = path.join(__dirname, 'peer.js')

function tmpDir (prefix) {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix))
}

function spawnPeer (args) {
  const child = spawn('node', [PEER_JS, ...args], { stdio: ['pipe', 'pipe', 'pipe'] })
  let stdout = ''
  let stderr = ''
  child.stdout.on('data', (d) => { stdout += d })
  child.stderr.on('data', (d) => { stderr += d })
  return {
    child,
    send (line) { child.stdin.write(line + '\n') },
    stdout: () => stdout,
    waitFor (predicate, timeoutMs) {
      return new Promise((resolve, reject) => {
        const start = Date.now()
        const poll = setInterval(() => {
          if (predicate(stdout, stderr)) {
            clearInterval(poll)
            resolve()
          } else if (Date.now() - start > timeoutMs) {
            clearInterval(poll)
            reject(new Error(`timed out waiting; stdout=${stdout} stderr=${stderr}`))
          }
        }, 200)
      })
    }
  }
}

async function checkRoundTrip () {
  // First-connect latency over the real DHT varies a lot by network (a few
  // seconds on a fast LAN, up to ~60s seen on a constrained/sandboxed one)
  // -- generous bounds are the point: this proves CI usability, not speed.
  const a = spawnPeer(['--topic', 'peer-js-check-round-trip', '--timeout', '75'])
  const b = spawnPeer(['--topic', 'peer-js-check-round-trip', '--timeout', '75'])
  try {
    await Promise.all([
      a.waitFor((_, err) => err.includes('connected to'), 70000),
      b.waitFor((_, err) => err.includes('connected to'), 70000)
    ])

    a.send('hello from A')
    b.send('hello from B')

    await a.waitFor((out) => out.includes('peer: hello from B'), 5000)
    await b.waitFor((out) => out.includes('peer: hello from A'), 5000)
    console.log('ok: two peers on the same --topic connected and exchanged messages both ways')
  } finally {
    a.child.kill('SIGKILL')
    b.child.kill('SIGKILL')
  }
}

// flutter_pear-d5w: real two-process round trip for --drive mode -- a
// genuine Hyperdrive replication over a real (local) Hyperswarm connection,
// not a stub. Proves the drive-key-announcement protocol (the same one
// file_drop_screen.dart speaks) and the core-then-blobs replication
// chaining actually interop between two independent processes, byte-exact.
async function checkDriveRoundTrip () {
  const sendDir = tmpDir('flutter-pear-peer-check-send-')
  const recvDir = tmpDir('flutter-pear-peer-check-recv-')
  const storageA = tmpDir('flutter-pear-peer-check-storeA-')
  const storageB = tmpDir('flutter-pear-peer-check-storeB-')
  const sourceFile = path.join(sendDir, 'payload.bin')
  const payload = crypto.randomBytes(5 * 1024 * 1024) // photo-sized, matches E7.7's own validation scale
  fs.writeFileSync(sourceFile, payload)

  const topic = 'peer-js-check-drive-round-trip'
  const sender = spawnPeer(['--topic', topic, '--drive', '--put', sourceFile, '--storage', storageA, '--timeout', '75'])
  const receiver = spawnPeer(['--topic', topic, '--drive', '--mirror-to', recvDir, '--storage', storageB, '--timeout', '75'])
  try {
    await receiver.waitFor((_, err) => err.includes('mirrored into'), 70000)

    const receivedFile = path.join(recvDir, 'payload.bin')
    assert.ok(fs.existsSync(receivedFile), 'mirrored file must exist at the expected path')
    const receivedHash = crypto.createHash('sha256').update(fs.readFileSync(receivedFile)).digest('hex')
    const sentHash = crypto.createHash('sha256').update(payload).digest('hex')
    assert.equal(receivedHash, sentHash, 'mirrored file must be byte-identical to the one --put on the other side')
    console.log('ok: --drive mode replicated a 5MB file between two peers, byte-identical')
  } finally {
    sender.child.kill('SIGKILL')
    receiver.child.kill('SIGKILL')
    for (const dir of [sendDir, recvDir, storageA, storageB]) fs.rmSync(dir, { recursive: true, force: true })
  }
}

async function checkTimeoutExit () {
  const exitCode = await new Promise((resolve) => {
    const child = spawn('node', [
      PEER_JS, '--topic', 'peer-js-check-lonely-topic', '--timeout', '2'
    ], { stdio: ['ignore', 'ignore', 'ignore'] })
    child.on('exit', (code) => resolve(code))
  })
  assert.equal(exitCode, 1, 'expected exit code 1 on connect timeout')
  console.log('ok: exits nonzero when no peer connects within --timeout')
}

async function main () {
  // Round trip first: an earlier ordering (timeout-check, then round-trip)
  // was observed to make the SECOND check's DHT bootstrap unreliable in
  // this environment, even with generous timeouts -- undiagnosed, but
  // consistently reproducible, so the cheap check runs last instead.
  await checkRoundTrip()
  await checkDriveRoundTrip()
  await checkTimeoutExit()
}

main().catch((err) => {
  console.error('FAILED:', err.message || err)
  process.exit(1)
})
