# hyperdht-address

Encode and decode HyperDHT addresses.

## Install

```
npm install hyperdht-address
```

## Usage

```js
const { encode, decode } = require('hyperdht-address')

const buf = encode(key, [{ host: '0.0.0.0', port: 12345 }])
const { key, nodes } = decode(buf)
```

## API

#### `const buf = encode(key, [nodes])`

Encode a 32-byte key and optional array of nodes into a buffer.

Each node has the shape `{ host, port }`.

#### `const { key, nodes } = decode(buf)`

Decode a buffer into an address object with `key` (Buffer) and `nodes` (array of `{ host, port, family }`).

## License

Apache-2.0
