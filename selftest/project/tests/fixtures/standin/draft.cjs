// CommonJS fixture a check runs in a child process. Classified non-source
// (classification.test **/fixtures/**) and must lint clean: module is the module system.
function slot(teams, overallPick) {
  return ((overallPick - 1) % teams) + 1
}

module.exports = { slot }
