#!/usr/bin/env node
'use strict'

// Helper for doctor-checks.js's local loopback self-test -- joins the hex
// topic given as argv[2] and prints CONNECTED the moment a peer shows up.
// A SEPARATE PROCESS on purpose: two Hyperswarm instances in the SAME
// process were observed never connecting to each other even after 60s,
// while two independent processes connect reliably (matching the same
// same-process-vs-separate-process discrepancy found while building
// flutter_pear_example/tool/peer.check.js) -- undiagnosed, but consistently
// reproducible, so this sidesteps it the same way.
//
// `require('hyperswarm')` resolves against the COMMITTED, trimmed
// tool/node_modules/ sitting right next to this file -- see
// doctor-checks.js's own doc comment (flutter_pear-ewf).

const Hyperswarm = require('hyperswarm')

const topic = Buffer.from(process.argv[2], 'hex')
const swarm = new Hyperswarm()
swarm.on('connection', () => {
  console.log('CONNECTED')
  swarm.destroy().finally(() => process.exit(0))
})
swarm.join(topic, { server: true, client: true })
