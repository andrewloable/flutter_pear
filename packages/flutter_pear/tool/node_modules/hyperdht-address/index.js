const c = require('compact-encoding')
const { getEncoding } = require('./spec/hyperschema')

const HyperdhtAddress = getEncoding('@hyperdht/address')

function decode(buf) {
  const addr = c.decode(HyperdhtAddress, buf)
  return addr
}

function encode(key, nodes) {
  return c.encode(HyperdhtAddress, { key, nodes })
}

module.exports = { decode, encode }
