#!/usr/bin/env node
'use strict'

// Runnable check for doctor-checks.js (E7.4, X5): runs it for real against
// the actual network (no stubs -- the whole point is proving the real DHT/
// loopback checks work), then confirms the two loopback-peer subprocesses
// it spawns are gone afterward (regression check for the cleanup this
// script's SIGKILL calls are responsible for).
//
// Plain assert-based script, not `node --test`: see peer.check.js's own
// header for why (real DHT bootstrap from inside node's test-runner child
// processes was observed far less reliable than from a plain script in
// this environment).
//
// Run directly: `node tool/doctor-checks.check.js`.

const assert = require('node:assert/strict')
const path = require('node:path')
const { execFile } = require('node:child_process')
const { promisify } = require('node:util')
const execFileAsync = promisify(execFile)

const DOCTOR_CHECKS_JS = path.join(__dirname, 'doctor-checks.js')

async function main () {
  const { stdout, code } = await new Promise((resolve) => {
    execFile('node', [DOCTOR_CHECKS_JS], (err, stdout, stderr) => {
      resolve({ stdout, stderr, code: err ? err.code : 0 })
    })
  })

  console.log(stdout)
  assert.equal(code, 0, 'expected doctor-checks.js to exit 0 on a working network')
  assert.match(stdout, /\[PASS\] DHT bootstrap reachable/)
  assert.match(stdout, /\[PASS\] Local loopback self-test/)
  console.log('ok: doctor-checks.js passes on a working network')

  // Regression check for the SIGKILL cleanup in checkLoopback(): no
  // leftover doctor-loopback-peer.js processes should survive the run.
  // pgrep's OWN exit code distinguishes "ran fine, found nothing" (1) from
  // a real problem (anything else, e.g. ENOENT if pgrep isn't installed) --
  // collapsing every failure into "found nothing" would let a missing
  // pgrep binary silently and permanently pass this check without ever
  // having looked.
  const psOut = await execFileAsync('pgrep', ['-f', 'doctor-loopback-peer.js'])
    .then(({ stdout }) => stdout)
    .catch((err) => {
      if (err.code === 1) return '' // pgrep's own "no processes matched"
      throw err
    })
  assert.equal(psOut.trim(), '', `expected no leftover loopback-peer processes, found:\n${psOut}`)
  console.log('ok: no orphaned loopback-peer processes after the run')
}

main().catch((err) => {
  console.error('FAILED:', err.message || err)
  process.exit(1)
})
