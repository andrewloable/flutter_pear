#!/usr/bin/env node
'use strict'

// E7.4 (X5): runtime connectivity diagnostics for `dart run flutter_pear:doctor`.
//
// Deliberately desktop-side network checks, not a real worklet boot: a
// plain `dart run` CLI has no Flutter engine, so it can't drive
// BareWorklet's platform channels the way a real app does -- there is no
// way for a pure-Dart CLI to boot the ACTUAL Android/iOS worklet. What it
// CAN do, and what actually answers "is this network going to work",
// is join the real Hyperswarm DHT directly and report what it finds.
//
// This file used to ALSO check for a `bare` CLI on PATH here (a non-failing
// [SKIP] when absent). That check has moved to the pure-Dart half
// (doctor_macos_checks.dart/doctor_linux_checks.dart/
// doctor_windows_checks.dart) as a real [FAIL] -- flutter_pear-bhv: a
// missing `bare` is a fatal precondition (it hard-crashed macOS apps before
// flutter_pear-a4p's fix), not a nice-to-have this Node half could shrug
// off as a SKIP, and the Node half is unreachable for consumers whenever
// IT is the thing broken (flutter_pear-ewf) -- exactly the scenario where
// the check matters most. Removed here rather than duplicated, so doctor
// never emits two contradictory verdicts about the same `bare` binary.
//
// `require('hyperswarm')` resolves against the COMMITTED, trimmed
// tool/node_modules/ sitting right next to this file (flutter_pear-ewf) --
// NOT pear-end/node_modules, which is gitignored and never published, so
// this used to throw MODULE_NOT_FOUND for every pub.dev consumer. See
// tool/build_doctor_node_modules.dart's own doc comment for how that tree
// is built/regenerated and why the already-committed
// assets/desktop/<host>/node_modules/*/prebuilds/*.bare files can't be
// reused for it (they're Bare-addon-ABI binaries, not Node-loadable).

const path = require('node:path')
const { spawn } = require('node:child_process')

const Hyperswarm = require('hyperswarm')
const crypto = require('node:crypto')

const LOOPBACK_PEER_JS = path.join(__dirname, 'doctor-loopback-peer.js')

const DHT_READY_TIMEOUT_MS = 15000
// 35s, not 20s (flutter_pear-ewf): observed repeatedly during testing that
// a COLD DHT client (first Hyperswarm instance created in a while) can take
// >20s to complete its DHT rendezvous+hole-punch even on a healthy network
// -- a warm client reconnects in ~5s. 20s produced a false [FAIL] ("likely
// a local firewall blocking loopback UDP") on a perfectly reachable
// network, exactly the false diagnosis this check exists to avoid.
const LOOPBACK_TIMEOUT_MS = 35000

function pass (line) {
  console.log(`[PASS] ${line}`)
}
function fail (line) {
  console.log(`[FAIL] ${line}`)
}
function info (line) {
  console.log(`[INFO] ${line}`)
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

async function main () {
  console.log('flutter_pear doctor -- runtime connectivity diagnostics\n')

  // DHT reachability and the loopback self-test are independent -- run
  // concurrently so the total wall-clock is the max of the two, not the
  // sum, keeping this closer to the "<30s" target.
  const dhtSwarm = new Hyperswarm()
  const [dhtOk, loopbackOk] = await Promise.all([
    checkDhtReachability(dhtSwarm).finally(() => {
      checkNatType(dhtSwarm)
      return dhtSwarm.destroy()
    }),
    checkLoopback()
  ])
  const ok = dhtOk && loopbackOk

  console.log()
  console.log(ok ? 'All checks passed.' : 'Some checks failed -- see [FAIL] lines above.')
  process.exit(ok ? 0 : 1)
}

main().catch((err) => {
  console.error(err.message || err)
  process.exit(1)
})
