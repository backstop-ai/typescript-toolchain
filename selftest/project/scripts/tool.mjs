// A plain ESM Node script: the Node globals must be defined for no-undef.
import { readFileSync } from 'node:fs'

const started = performance.now()
const url = new URL('file:///tmp/x')
setTimeout(() => {
  console.log(process.argv.length, typeof readFileSync, url.protocol, structuredClone({ started }))
}, 0)
