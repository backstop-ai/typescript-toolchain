// Real runtime code that NO test imports. Under --coverage.include it must get a
// 0/N summary entry (a real 0% gap), never be silently absent.
export function snakeSlot(teams: number, overallPick: number): number {
  const round = Math.floor((overallPick - 1) / teams)
  const index = (overallPick - 1) % teams
  if (round % 2 === 0) {
    return index + 1
  }
  return teams - index
}
