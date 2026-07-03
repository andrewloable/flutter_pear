// pear-end — the JavaScript that runs inside the Bare worklet.
//
// Dart never sees this: it ships prebuilt (via `dart run flutter_pear:pack`,
// which wraps bare-pack) and is driven entirely over the RPC schema below.
// This M0/M1 stub sketches the swarm RPC surface; the real Hyperswarm /
// Corestore wiring lands in M1/M2. (The M0 echo currently lives on the native
// side — this bundle isn't loaded yet.)
//
// RPC frame = one UTF-8 JSON object (mirrors flutter_pear/lib/src/rpc.dart):
//   in : {"id","m","p"}                 request
//   out: {"id","ok"} | {"id","err"}     response
//   out: {"ev","p"}                     event
/* global BareKit */

const { IPC } = BareKit

function send (obj) {
  IPC.write(Buffer.from(JSON.stringify(obj)))
}

IPC.on('data', (buf) => {
  let frame
  try { frame = JSON.parse(buf.toString()) } catch { return }
  if (typeof frame.id !== 'number') return
  Promise.resolve()
    .then(() => handle(frame))
    .then(
      (ok) => send({ id: frame.id, ok: ok ?? null }),
      (err) => send({
        id: frame.id,
        err: { message: String((err && err.message) || err), stack: err && err.stack }
      })
    )
})

async function handle ({ m, p }) {
  switch (m) {
    // TODO(M1): real Hyperswarm — join the topic, emit `swarm.connection` /
    // `connection.data` / `connection.close` events, and write on
    // `connection.write`.
    case 'swarm.join': return { joined: p.topic }
    case 'swarm.leave': return { left: p.topic }
    case 'connection.write': return null
    default: throw new Error('unknown method: ' + m)
  }
}
