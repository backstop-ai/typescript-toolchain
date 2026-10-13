// CommonJS check script: require, __dirname, console and process must all be defined
// and require() must not trip @typescript-eslint/no-require-imports in a .cjs file.
const path = require('path')
const draft = require(path.join(__dirname, '..', 'draft.cjs'))

if (draft.slot(4, 5) !== 1) {
  console.error('slot check failed')
  process.exit(1)
}
console.log('slot check ok', __filename)
