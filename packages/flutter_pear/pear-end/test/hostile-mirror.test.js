// Zip-slip regression coverage for Method.DRIVE_MIRROR_TO_DISK
// (flutter_pear-ovt.2.7, plan decision 36, Eng2 finding 6): a malicious peer
// publishing a symlink entry whose target escapes the mirror directory,
// followed by a file routed through that symlink's key, must never write
// outside the destination -- and the rejection must be visible to Dart as a
// drive.mirrorWarning event, not a silently-missing file.
//
// Run directly with Node's built-in test runner from the pear-end/
// directory: `node --test` (mirrors index.test.js's header note on why a
// directory path argument doesn't work on this Node version).
'use strict'

const test = require('node:test')
const assert = require('node:assert/strict')
const NodeModule = require('node:module')
const fs = require('node:fs')
const fsPromises = require('node:fs/promises')
const os = require('node:os')
const path = require('node:path')
const { EventEmitter } = require('node:events')

const Hyperswarm = require('hyperswarm')
const Corestore = require('corestore')
const Hyperdrive = require('hyperdrive')
const { Method, EventName, FrameType } = require('../schema')

const INDEX_PATH = require.resolve('../index.js')

// index.js constructs `const swarm = new Hyperswarm()` unconditionally at
// module load -- an undestroyed one keeps its DHT UDP socket bound, which
// keeps `node --test` alive forever after the last test finishes (same
// discovery documented in index.test.js's header). Track every instance so
// test.after() can destroy them all.
const swarmInstances = []
class TrackedHyperswarm extends Hyperswarm {
  constructor (...args) {
    super(...args)
    swarmInstances.push(this)
  }
}
require.cache[require.resolve('hyperswarm')].exports = TrackedHyperswarm
test.after(() => Promise.all(swarmInstances.map((s) => s.destroy().catch(() => {}))))

// index.js requires 'bare-fs'/'bare-path' directly -- both are Bare-runtime-
// only (their binding.js calls the Bare-native require.addon(), absent
// under plain Node). Same fix as index.test.js: pre-seed Node's require
// cache with Node-native equivalents so index.js's own requires resolve to
// these instead of ever loading the real Bare-only modules.
function stubBareRuntimeDepsForNode () {
  const fromDir = path.dirname(INDEX_PATH)
  const fsStub = { ...fs, ...fsPromises }
  for (const [specifier, stub] of [['bare-fs', fsStub], ['bare-path', path]]) {
    const resolved = require.resolve(specifier, { paths: [fromDir] })
    if (require.cache[resolved]) continue
    const fakeModule = new NodeModule(resolved, null)
    fakeModule.exports = stub
    fakeModule.loaded = true
    require.cache[resolved] = fakeModule
  }
}
stubBareRuntimeDepsForNode()

const tmpDirs = []
function tmpDir () {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'pear-end-hostile-mirror-'))
  tmpDirs.push(dir)
  return dir
}
test.after(() => {
  for (const dir of tmpDirs) fs.rmSync(dir, { recursive: true, force: true })
})

// Same boot pattern as index.test.js's bootWorklet, extended with an
// onEvent hook: DRIVE_MIRROR_TO_DISK's rejections surface as fire-and-forget
// {ev, p} frames (never a request/response), which bootWorklet's own
// call()-scoped write listeners deliberately ignore (they only resolve a
// promise whose id matches a pending request) -- this harness needs to see
// every raw frame, not just responses.
function bootWorklet ({ argv = [tmpDir()], onEvent = () => {} } = {}) {
  const ipc = new EventEmitter()
  const writeListeners = new Set()
  ipc.write = (buf) => { for (const listener of writeListeners) listener(buf) }

  global.BareKit = { IPC: ipc }
  global.Bare = {
    argv,
    on: () => {},
    exit: (code) => { throw new Error('Bare.exit(' + code + ') called during test') }
  }

  delete require.cache[INDEX_PATH]
  require(INDEX_PATH)

  writeListeners.add((buf) => {
    if (buf.length < 5 || buf[4] !== FrameType.JSON) return
    const len = buf.readUInt32BE(0)
    let msg
    try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
    if (msg.ev) onEvent(msg)
  })

  let nextId = 1
  function call (method, params) {
    const id = nextId++
    const response = new Promise((resolve) => {
      const onWrite = (buf) => {
        if (buf.length < 5 || buf[4] !== FrameType.JSON) return
        const len = buf.readUInt32BE(0)
        let msg
        try { msg = JSON.parse(buf.subarray(5, 4 + len).toString()) } catch { return }
        if (msg.id !== id) return
        writeListeners.delete(onWrite)
        resolve(msg)
      }
      writeListeners.add(onWrite)
    })

    const body = Buffer.from(JSON.stringify({ id, m: method, p: params }))
    const frame = Buffer.concat([Buffer.from([FrameType.JSON]), body])
    const lengthPrefix = Buffer.alloc(4)
    lengthPrefix.writeUInt32BE(frame.length, 0)
    ipc.emit('data', Buffer.concat([lengthPrefix, frame]))

    return response
  }

  return { call, argvDir: argv[0] }
}

test('DRIVE_MIRROR_TO_DISK rejects a symlink entry and the escape it would '
    + 'have enabled, emitting drive.mirrorWarning, without disturbing a '
    + 'legit file mirrored in the same run', async (t) => {
  const argvDir = tmpDir()

  // Seed the worklet's OWN corestore directory (index.js derives it as
  // <argv[0]>/pear-corestore) with a hostile drive BEFORE the worklet boots
  // -- a later DRIVE_OPEN({ key }) against that same on-disk storage then
  // finds the data locally, no real peer/network replication needed to
  // exercise the real DRIVE_MIRROR_TO_DISK handler end to end.
  const corestoreDir = path.join(argvDir, 'pear-corestore')
  const seedStore = new Corestore(corestoreDir)
  const seedDrive = new Hyperdrive(seedStore)
  await seedDrive.ready()

  await seedDrive.put('/legit.txt', Buffer.from('hello'))
  // The zip-slip entry: a relative linkname climbing well past any mirror
  // directory's depth -- Localdrive.symlink() only resolves an
  // ABSOLUTE-looking linkname against the drive root; a relative one like
  // this is written to disk uncontained.
  await seedDrive.symlink('/x', '../../../../../../tmp/pear-end-zip-slip-poc')
  // Routed through the symlink's key: if /x had been created as a real
  // symlink, the OS would follow it when writing this entry, landing the
  // write at <target>/payload instead of inside the mirror directory.
  await seedDrive.put('/x/payload', Buffer.from('pwned'))

  const driveKeyHex = seedDrive.key.toString('hex')
  await seedDrive.close()
  await seedStore.close()

  const events = []
  const worklet = bootWorklet({ argv: [argvDir], onEvent: (msg) => events.push(msg) })
  t.after(async () => {
    // Best-effort: index.js has no explicit "shut down everything" RPC:
    // process-level teardown (t.after) leaves the module-level store/drives
    // for the process lifetime, same accepted trickle index.test.js's own
    // header comment documents.
  })

  const openResp = await worklet.call(Method.DRIVE_OPEN, { key: driveKeyHex })
  assert.equal(openResp.err, undefined,
      'DRIVE_OPEN should succeed against the pre-seeded local storage: '
      + JSON.stringify(openResp.err))

  const destDir = tmpDir()
  const mirrorResp = await worklet.call(Method.DRIVE_MIRROR_TO_DISK, {
    drive: driveKeyHex,
    localDir: destDir
  })
  assert.equal(mirrorResp.err, undefined,
      'DRIVE_MIRROR_TO_DISK should succeed (rejecting the hostile entries, '
      + 'not throwing): ' + JSON.stringify(mirrorResp.err))

  // The legit file arrived, untouched by the hostile entries elsewhere in
  // the same mirror.
  assert.equal(
    fs.readFileSync(path.join(destDir, 'legit.txt'), 'utf8'),
    'hello'
  )

  // The symlink itself was never created: destDir/x exists only as an
  // ordinary directory (mkdir'd to hold the sibling /x/payload entry below,
  // a separate and otherwise-safe key), never as an actual symlink.
  assert.equal(fs.lstatSync(path.join(destDir, 'x')).isSymbolicLink(), false,
      'the rejected symlink entry must never be created as a real symlink '
      + 'on disk, even though a same-named plain directory legitimately '
      + 'exists to hold /x/payload')

  // The would-be escape target: nothing exists there. This is the actual
  // zip-slip probe -- proof the attack did not succeed, not just that the
  // symlink is absent.
  assert.equal(
    fs.existsSync('/tmp/pear-end-zip-slip-poc/payload'),
    false,
    'the file the malicious symlink target pointed at must never be '
    + 'written -- this is the actual escape this fix exists to prevent'
  )

  // drive.mirrorWarning was emitted for exactly the symlink rejection.
  const warnings = events.filter((e) => e.ev === EventName.DRIVE_MIRROR_WARNING)
  assert.equal(warnings.length, 1,
      'expected exactly one drive.mirrorWarning event, got: '
      + JSON.stringify(warnings))
  assert.deepEqual(warnings[0].p, {
    drive: driveKeyHex,
    path: '/x',
    reason: 'symlink-rejected'
  })

  // The response's rejected count matches -- Dart's typed result surfaces
  // this without needing to count events itself.
  assert.equal(mirrorResp.ok.rejected, 1)
  // /x/payload still mirrors normally -- rejecting the symlink doesn't
  // reject everything under its former key namespace, since with the
  // symlink gone there's nothing left to escape through.
  assert.equal(
    fs.readFileSync(path.join(destDir, 'x', 'payload'), 'utf8'),
    'pwned'
  )
})
