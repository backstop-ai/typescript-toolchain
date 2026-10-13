import type { Pick } from './types-only'

// Loaded and exercised by tests/used.test.ts: must report covered > 0.
export function overall(pick: Pick, teams: number): number {
  return (pick.round - 1) * teams + pick.slot
}
