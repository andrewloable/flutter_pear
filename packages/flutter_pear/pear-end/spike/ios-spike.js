// THROWAWAY T0 spike (flutter_pear-ovt.1.3): proves BareKit + IPC + bare-rpc
// ping on iOS with ZERO native addons. Not wired into package.json, :pack,
// or assets/ -- never a committed versioned artifact. See index.js for the
// real pear-end this mirrors the framing of (send/writeFramed/IPC.on('data')
// accumulator, handleFrame's request/response envelope).
/* global BareKit, Bare */
'use strict'

const { IPC } = BareKit
const { Method, FrameType, HandshakeField, ErrorCode } = require('../schema')

const SESSION_NONCE = Math.random().toString(16).slice(2) + Math.random().toString(16).slice(2)
const BUNDLE_VERSION = 'ios-spike'

function send (obj) {
  const stamped = { ...obj, [HandshakeField.ENVELOPE_NONCE]: SESSION_NONCE }
  const body = Buffer.from(JSON.stringify(stamped))
  writeFramed(Buffer.concat([Buffer.from([FrameType.JSON]), body]))
}

function writeFramed (frame) {
  const lengthPrefix = Buffer.alloc(4)
  lengthPrefix.writeUInt32BE(frame.length, 0)
  IPC.write(Buffer.concat([lengthPrefix, frame]))
}

function reportCrash (kind, err) {
  try {
    send({ ev: 'worklet.onCrash', p: { kind, message: String((err && err.message) || err), stack: err && err.stack } })
  } catch (_) {}
  Bare.exit(1)
}

Bare.on('uncaughtException', (err) => reportCrash('uncaughtException', err))
Bare.on('unhandledRejection', (reason) => reportCrash('unhandledRejection', reason))

let recvBuffer = Buffer.alloc(0)

IPC.on('data', (buf) => {
  recvBuffer = recvBuffer.length ? Buffer.concat([recvBuffer, buf]) : buf
  while (recvBuffer.length >= 4) {
    const frameLength = recvBuffer.readUInt32BE(0)
    if (recvBuffer.length < 4 + frameLength) break
    handleFrame(recvBuffer.subarray(4, 4 + frameLength))
    recvBuffer = recvBuffer.subarray(4 + frameLength)
  }
})

function handleFrame (buf) {
  if (buf.length === 0) return
  if (buf[0] !== FrameType.JSON) return

  let frame
  try { frame = JSON.parse(buf.subarray(1).toString()) } catch (_) { return }
  if (!frame || typeof frame.id !== 'number') return

  Promise.resolve()
    .then(() => handle(frame))
    .then(
      (ok) => send({ id: frame.id, ok: ok ?? null }),
      (err) => send({ id: frame.id, err: { message: String((err && err.message) || err), code: err && err.code } })
    )
}

async function handle ({ m }) {
  if (m === Method.ATTACH_INFO) {
    return {
      [HandshakeField.NONCE]: SESSION_NONCE,
      [HandshakeField.BUNDLE_VERSION]: BUNDLE_VERSION
    }
  }
  const err = new Error('unknown method (ios-spike only answers attach.info): ' + m)
  err.code = ErrorCode.UNKNOWN_METHOD
  throw err
}
