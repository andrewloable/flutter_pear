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
const path = require('node:path')
const { spawn } = require('node:child_process')

const PEER_JS = path.join(__dirname, 'peer.js')

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
  await checkTimeoutExit()
}

main().catch((err) => {
  console.error('FAILED:', err.message || err)
  process.exit(1)
})
