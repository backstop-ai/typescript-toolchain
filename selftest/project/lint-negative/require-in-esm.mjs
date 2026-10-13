// Negative: no-require-imports stays ON outside .cjs, and require is not an ESM global.
const fs = require('fs')
export const exists = fs.existsSync
