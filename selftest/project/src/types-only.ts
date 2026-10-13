// Types only: no runtime statements. Type-only imports are erased at transpile time,
// so no test ever loads this module. Under --coverage.include it must still get a
// summary entry with statements.total 0 (core: N/A, not 0%, not unmeasured).
export interface Pick {
  round: number
  slot: number
}

export type Side = 'home' | 'away'
