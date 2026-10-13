// Stand-in for a module coverage cannot see, such as a Temporal workflow that runs
// inside Temporal's isolated workflow bundle rather than the test process. No test
// imports it, so it is a 0/N gap unless the project declares a justified exclusion
// in .backstop/coverage-exclusions (the selftest writes one).
export function nextStep(step: number, attempts: number): number {
  if (attempts > 3) {
    return -1
  }
  return step + 1
}
