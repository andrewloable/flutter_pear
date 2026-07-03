'use strict'

// The RPC/event contract shared with the Dart side. Hand-kept mirror of
// flutter_pear/lib/src/schema.dart -- no codegen (LOCKED, see E2.1). Keep the
// two files in sync by hand; schema_test.dart cross-checks the values.

const Method = {
  SWARM_JOIN: 'swarm.join',
  SWARM_LEAVE: 'swarm.leave',
  CONNECTION_WRITE: 'connection.write',
  // Debug-only: throws a forced JS error so the RPC error path can be
  // exercised end-to-end. Not part of the production surface.
  DEBUG_FORCE_ERROR: 'debug.forceError',
  // Debug-only: schedules a genuinely uncaught exception (escaping this
  // call's own promise chain, unlike DEBUG_FORCE_ERROR) so the
  // WORKLET_CRASH path can be exercised end-to-end. Not part of the
  // production surface.
  DEBUG_FORCE_CRASH: 'debug.forceCrash',
  // Debug-only: echoes p.data (base64) straight back as {data} -- a raw
  // in-channel round trip with no other JS-side work. Exists for E5.1's
  // platform-channel throughput benchmark. Not part of the production
  // surface.
  DEBUG_ECHO: 'debug.echo',
  // Returns this worklet's session identity: {nonce, bundleVersion}.
  // Request/response (not an event) so it works correctly whether this is
  // the first-ever query or a Dart hot restart re-querying an
  // already-running worklet.
  ATTACH_INFO: 'attach.info',
  // File-path bulk seam (E4.4, codex #4 LOCKED): writes p.data (whole
  // payload, base64, NOT chunked/streamed) to a new file in this worklet's
  // storage and returns {path}. See schema.dart's PearMethod.bulkWriteFile.
  BULK_WRITE_FILE: 'bulk.writeFile',
  // E5.2 -- Corestore/Hypercore wrapper. See schema.dart's PearMethod for
  // full doc on each of these.
  STORE_GET: 'store.get',
  CORE_APPEND: 'core.append',
  CORE_GET: 'core.get',
  CORE_REPLICATE: 'core.replicate',
  CORE_CLOSE: 'core.close',
  // E5.3 -- Hyperbee KV wrapper. See schema.dart's PearMethod for full doc
  // on each of these.
  BEE_OPEN: 'bee.open',
  BEE_GET: 'bee.get',
  BEE_PUT: 'bee.put',
  BEE_DEL: 'bee.del',
  BEE_REPLICATE: 'bee.replicate',
  BEE_RANGE: 'bee.range',
  BEE_WATCH: 'bee.watch',
  BEE_UNWATCH: 'bee.unwatch',
  BEE_CLOSE: 'bee.close',
  // E5.5 -- Hyperdrive file wrapper. See schema.dart's PearMethod for full
  // doc on each of these.
  DRIVE_OPEN: 'drive.open',
  DRIVE_PUT: 'drive.put',
  DRIVE_GET: 'drive.get',
  DRIVE_EXISTS: 'drive.exists',
  DRIVE_DELETE: 'drive.delete',
  DRIVE_LIST: 'drive.list',
  DRIVE_REPLICATE: 'drive.replicate',
  DRIVE_MIRROR_TO_DISK: 'drive.mirrorToDisk',
  DRIVE_CLOSE: 'drive.close',
  // E5.6 -- blind-pairing wrapper. See schema.dart's PearMethod for full
  // doc on each of these.
  PAIRING_CREATE_INVITE: 'pairing.createInvite',
  PAIRING_ACCEPT_INVITE: 'pairing.acceptInvite',
  PAIRING_CONFIRM_CANDIDATE: 'pairing.confirmCandidate',
  PAIRING_REVOKE: 'pairing.revoke'
}

const EventName = {
  SWARM_CONNECTION: 'swarm.connection',
  CONNECTION_DATA: 'connection.data',
  CONNECTION_CLOSE: 'connection.close',
  SWARM_LIFECYCLE: 'swarm.lifecycle',
  // A frame this side couldn't handle (unrecognized FrameType byte, or a
  // JSON frame that failed to parse) -- synthesized locally, never a real
  // worklet-to-worklet wire event.
  RPC_DIAGNOSTIC: 'rpc.diagnostic',
  // Self-reported imminent death (uncaught exception / unhandled rejection)
  // sent just before Bare.exit() -- see index.js's Bare.on(...) handlers.
  WORKLET_CRASH: 'worklet.crash',
  // A core's length changed (local append or replicated blocks) -- E5.2.
  CORE_UPDATE: 'core.update',
  // A bee changed within an active BEE_WATCH's bounds -- E5.3.
  BEE_UPDATE: 'bee.update',
  // A new candidate wants to pair on a PAIRING_CREATE_INVITE'd invite --
  // E5.6.
  PAIRING_CANDIDATE: 'pairing.candidate'
}

const ErrorCode = {
  UNKNOWN_PEER: 'UNKNOWN_PEER',
  UNKNOWN_METHOD: 'UNKNOWN_METHOD',
  FORCED_ERROR: 'FORCED_ERROR',
  // Best-effort guess that UDP is blocked on this network -- see index.js's
  // swarm error handling. CONNECT_TIMEOUT (schema.dart's other
  // PearSwarmState.failed reason) is Dart-only, like RPC_TIMEOUT etc. below,
  // so it has no entry here.
  UDP_BLOCKED: 'UDP_BLOCKED',
  // Thrown by Method.BULK_WRITE_FILE (E4.4) when writing to worklet storage
  // fails.
  STORAGE_UNAVAILABLE: 'STORAGE_UNAVAILABLE',
  // E5.2 -- Corestore/Hypercore wrapper error codes. See schema.dart's
  // PearErrorCode for full doc on each of these.
  INDEX_OUT_OF_RANGE: 'INDEX_OUT_OF_RANGE',
  CORE_CLOSED: 'CORE_CLOSED',
  UNKNOWN_CORE: 'UNKNOWN_CORE',
  // E5.3 -- Hyperbee KV wrapper error codes.
  UNKNOWN_BEE: 'UNKNOWN_BEE',
  BEE_CLOSED: 'BEE_CLOSED',
  // E5.5 -- Hyperdrive file wrapper error codes.
  UNKNOWN_DRIVE: 'UNKNOWN_DRIVE',
  DRIVE_CLOSED: 'DRIVE_CLOSED',
  FILE_NOT_FOUND: 'FILE_NOT_FOUND',
  // E5.6 -- blind-pairing wrapper error codes.
  INVALID_INVITE: 'INVALID_INVITE',
  INVITE_EXPIRED: 'INVITE_EXPIRED',
  PAIRING_TIMEOUT: 'PAIRING_TIMEOUT',
  UNKNOWN_INVITE: 'UNKNOWN_INVITE',
  UNKNOWN_CANDIDATE: 'UNKNOWN_CANDIDATE'
}

// PearSwarm connection-state vocabulary (E2.7) -- the `state` field of a
// SWARM_LIFECYCLE event. Mirrors schema.dart's PearSwarmState enum; each
// Dart member's `.name` IS the wire string below.
const SwarmState = {
  DISCOVERING: 'discovering',
  CONNECTING: 'connecting',
  CONNECTED: 'connected',
  RECONNECTING: 'reconnecting',
  SUSPENDED: 'suspended',
  FAILED: 'failed'
}

// Every IPC frame is prefixed with one of these. RAW has no reader yet
// (M3's bulk transport is the first planned consumer).
const FrameType = {
  JSON: 0x00,
  RAW: 0x01
}

const HandshakeField = {
  // attach.info response payload fields.
  NONCE: 'nonce',
  BUNDLE_VERSION: 'bundleVersion',
  // Envelope-level field (sibling of id/ev/ok/err/p, NOT inside p) stamped
  // on EVERY frame this side sends, so Dart can drop a frame from a
  // generation it has since killed or replaced -- including one already in
  // flight when the kill happened.
  ENVELOPE_NONCE: 'n'
}

module.exports = { Method, EventName, ErrorCode, SwarmState, FrameType, HandshakeField }
