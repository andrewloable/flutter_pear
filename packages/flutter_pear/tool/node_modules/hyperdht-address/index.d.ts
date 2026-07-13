declare module 'hyperdht-address' {
  interface Node {
    host: string
    port: number
    family?: number
  }

  interface Address {
    key: Buffer
    nodes: Node[]
  }

  export function encode(key: Buffer, nodes?: Node[]): Buffer
  export function decode(buf: Buffer): Address
}
