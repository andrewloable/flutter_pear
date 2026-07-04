#!/usr/bin/env node
'use strict'

// E7.4 (X5): runtime connectivity diagnostics for `dart run flutter_pear:doctor`.
//
// Deliberately desktop-side network checks, not a real worklet boot: a
// plain `dart run` CLI has no Flutter engine, so it can't drive
// BareWorklet's platform channels the way a real app does -- there is no
// way for a pure-Dart CLI to boot the ACTUAL Android/iOS worklet. What it
// CAN do, and what actually answers "is this network going to work",
// is join the real Hyperswarm DHT directly (same libraries pear-end wraps,
// resolved through its own node_modules so versions never drift -- see
// flutter_pear_example/tool/peer.js's identical pattern) and report what it
// finds. The worklet-boot check below is attempted only if a `bare` CLI is
// on PATH; if not, it's reported as an explicit SKIP, never faked as a pass.

const path = require('node:path')
const { execFile, spawn } = require('node:child_process')
const { promisify } = require('node:util')
const execFileAsync = promisify(execFile)

const pearEndRequire = require('node:module').createRequire(
  path.join(__dirname, '..', 'pear-end', 'package.json')
)
const Hyperswarm = pearEndRequire('hyperswarm')
const crypto = require('node:crypto')

const LOOPBACK_PEER_JS = path.join(__dirname, 'doctor-loopback-peer.js')

const DHT_READY_TIMEOUT_MS = 15000
const LOOPBACK_TIMEOUT_MS = 20000

function pass (line) {
  console.log(`[PASS] ${line}`)
}
function fail (line) {
  console.log(`[FAIL] ${line}`)
}
function info (line) {
  console.log(`[INFO] ${line}`)
}
function skip (line) {
  console.log(`[SKIP] ${line}`)
}

async function checkDhtReachability (swarm) {
  const start = Date.now()
  try {
    await Promise.race([
      swarm.dht.ready(),
      new Promise((_, reject) =>
        setTimeout(() => reject(new Error('timeout')), DHT_READY_TIMEOUT_MS))
    ])
    pass(`DHT bootstrap reachable (${Date.now() - start}ms, public address ${swarm.dht.host}:${swarm.dht.port})`)
    return true
  } catch {
    fail(`DHT bootstrap unreachable after ${DHT_READY_TIMEOUT_MS}ms -- UDP is likely blocked on this network. See ERRORS.md#UDP_BLOCKED`)
    return false
  }
}

function checkNatType (swarm) {
  // firewalled=true is the NORMAL case behind most home/carrier NATs --
  // Hyperswarm's hole-punching is designed for exactly this and most peers
  // still connect fine. This is informational, not a pass/fail signal on
  // its own (a fully UDP-blocked network already failed the check above).
  if (swarm.dht.firewalled) {
    info('NAT: firewalled (normal -- direct connections need hole-punching, which Hyperswarm does automatically)')
  } else {
    info('NAT: not firewalled (this machine is directly reachable)')
  }
}

function spawnLoopbackPeer (topicHex) {
  const child = spawn('node', [LOOPBACK_PEER_JS, topicHex], { stdio: ['ignore', 'pipe', 'ignore'] })
  const connected = new Promise((resolve, reject) => {
    child.stdout.on('data', (d) => {
      if (d.toString().includes('CONNECTED')) resolve(true)
    })
    // Without this, a spawn failure (e.g. `node` briefly unresolvable on
    // PATH) emits Node's unhandled 'error' event instead of rejecting this
    // promise -- which crashes the whole process before the `finally`
    // cleanup below ever runs, leaking the sibling child.
    child.on('error', reject)
  })
  // Resolves once the OS has actually reaped the process, not just once
  // kill() was called -- checkLoopback's caller (doctor-checks.check.js)
  // greps for leftover processes right after this script exits, and a
  // kill() that hasn't been confirmed yet would make that check flaky.
  const exited = new Promise((resolve) => child.once('exit', resolve))
  return { child, connected, exited }
}

async function checkLoopback () {
  const topicHex = crypto.randomBytes(32).toString('hex')
  const start = Date.now()
  const a = spawnLoopbackPeer(topicHex)
  const b = spawnLoopbackPeer(topicHex)
  try {
    const connected = await Promise.race([
      Promise.all([a.connected, b.connected]).then(() => true),
      new Promise((resolve) => setTimeout(() => resolve(false), LOOPBACK_TIMEOUT_MS))
    ])
    if (connected) {
      pass(`Local loopback self-test: two peers on this machine connected in ${Date.now() - start}ms`)
    } else {
      fail(`Local loopback self-test: two peers on THIS machine never connected within ${LOOPBACK_TIMEOUT_MS}ms -- likely a local firewall blocking loopback UDP, not just a remote-network issue`)
    }
    return connected
  } catch {
    fail('Local loopback self-test: could not spawn the local test peers (see stderr)')
    return false
  } finally {
    a.child.kill('SIGKILL')
    b.child.kill('SIGKILL')
    await Promise.all([a.exited, b.exited])
  }
}

// Always returns true (SKIP and PASS both count as non-failing) --
// intentional: this check can only ever confirm a `bare` runtime starts,
// never that pear-end's own code boots (see the PASS message below), so it
// isn't a fair contributor to the overall pass/fail verdict either way.
async function checkWorkletBoot () {
  try {
    await execFileAsync('bare', ['--version'])
  } catch {
    skip("Worklet boot check -- 'bare' CLI not found on PATH (npm i -g bare-kit's bare to enable this check); the real worklet only boots inside the example app's Flutter engine anyway")
    return true // not a failure -- nothing to report as broken
  }
  // A `bare` CLI is present but actually booting pear-end/index.js needs
  // BareKit.IPC (the mobile embedding's global, not available to a plain
  // `bare` process either) -- so even with `bare` installed, this can only
  // confirm the runtime itself starts, not that pear-end's own code boots.
  pass("'bare' CLI found -- full worklet boot still requires the example app's Flutter engine to provide BareKit.IPC")
  return true
}

async function main () {
  console.log('flutter_pear doctor -- runtime connectivity diagnostics\n')

  // DHT reachability and the loopback self-test are independent -- run
  // concurrently so the total wall-clock is the max of the two, not the
  // sum, keeping this closer to the "<30s" target.
  const dhtSwarm = new Hyperswarm()
  const [dhtOk, loopbackOk, workletOk] = await Promise.all([
    checkDhtReachability(dhtSwarm).finally(() => {
      checkNatType(dhtSwarm)
      return dhtSwarm.destroy()
    }),
    checkLoopback(),
    checkWorkletBoot()
  ])
  const ok = dhtOk && loopbackOk && workletOk

  console.log()
  console.log(ok ? 'All checks passed.' : 'Some checks failed -- see [FAIL] lines above.')
  process.exit(ok ? 0 : 1)
}

main().catch((err) => {
  console.error(err.message || err)
  process.exit(1)
})
