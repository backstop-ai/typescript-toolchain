// Negative: the CommonJS block must not switch no-undef off for real typos.
const path = require('path')
module.exports = { joined: path.join(__dirname, definitelyNotDeclaredCjs) }
