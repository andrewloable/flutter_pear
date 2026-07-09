// Desktop's substitute for BareKit.IPC (flutter_pear-71g, E-D2a). BareKit
// only exists on mobile -- when a desktop host spawns the real `bare`
// runtime as a subprocess (E-D1's proven embedding shape, flutter_pear-bxp),
// there is no BareKit global to inject an IPC channel at all. `bare-pipe`
// wraps this process's own stdin (fd 0) and stdout (fd 1) -- exactly what
// the desktop host's Process/bare-subprocess spawn connects to -- as the
// same shape index.js already expects from BareKit.IPC: `.write(buf)` and
// `.on('data', cb)`.
//
// Only ever require()d when `typeof BareKit === 'undefined'` (see index.js's
// IPC selection) -- `bare-pipe` is a bare-native addon with no Node
// equivalent (`require.addon is not a function` under plain Node, confirmed
// empirically), so this file is NEVER loaded by pear-end's own Node-based
// test suite, which always shims a `global.BareKit`. The desktop path's real
// test is a live run under the real `bare` runtime, not a Node unit test --
// see flutter_pear-71g's own bd close reason for that evidence.
'use strict'

const Pipe = require('bare-pipe')

const stdin = new Pipe(0)
const stdout = new Pipe(1)

module.exports = {
  IPC: {
    write (buf) {
      stdout.write(buf)
    },
    on (event, cb) {
      stdin.on(event, cb)
      return this
    }
  }
}
