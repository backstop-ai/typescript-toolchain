#!/bin/sh
# typescript-toolchain SELFTEST — proves the engines' real behavior against a real
# Node toolchain, which `backstop pack test` cannot: phase-3 fixture execution runs
# an engine from the pack directory, and this pack's engines resolve ESLint/Vitest
# from a CONSUMER's node_modules, which a pack checkout does not have. So this
# script builds a throwaway consumer from selftest/project/, installs this pack
# into its .backstop/packs/, links a node_modules you supply, and runs the engine
# commands exactly as pack.yml declares them (split on whitespace with no shell,
# the way core runs them).
#
# Usage:
#   sh selftest/run.sh <dir-with-node_modules> [backstop-binary]
#
# <dir-with-node_modules> must contain node_modules/ with eslint, @eslint/js,
# typescript-eslint, vitest and @vitest/coverage-v8 (the onboarding contract). Run
# it once per toolchain generation you support (for example Vitest 3 and Vitest 5).
# With [backstop-binary], it also installs the pack with `backstop pack add` and
# runs `backstop gate --file` on the throwaway consumer to prove core's verdicts end
# to end (that step also needs pnpm on PATH, for the ts-audit engine).
#
# What it proves (ISSUE-221 / ISSUE-222 / ISSUE-223, and test-failure scope):
#   1. drift: the coverage include globs equal classification.source, the exclude
#      globs cover classification.test, and the ts-test command and the
#      coverage-produce.sh fallback carry the same lists;
#   2. lint: .cjs fixtures using require/__dirname/module, and an ESM Node script
#      using console/process/timers, lint clean; real undefined names still fire
#      no-undef, and require() outside .cjs still fires no-require-imports;
#   3. coverage (single-run reuse AND the producer's own fallback run): a
#      types-only module yields a total-0 record, an untested module yields 0/N,
#      a tested module yields covered > 0, and nothing under tests/ (helpers,
#      fixtures) yields a record;
#   4. coverage exclusions (single-run reuse AND fallback): a justified line in
#      .backstop/coverage-exclusions marks that path's record excluded with the
#      justification as its reason; a declared path with no summary entry gets a
#      synthetic excluded record (only for this pack's source extensions, so a
#      declared .go path yields no record); a line with no justification, or with a control
#      character in its path or justification, is dropped (with a stderr notice) and
#      the path stays measured; unlisted paths are unchanged;
#   5. gate (optional): a types-only file plus a fixture .cjs pass the coverage
#      step, an untested module fails it as a 0% gap, not as unmeasured, a justified
#      exclusion passes with a coverage_exclusion warning carrying its reason, and
#      an unjustified or control-character declaration leaves the path enforced.
#
# Exit 0 = every check passed. Requires jq. POSIX sh.

set -u

if [ $# -lt 1 ]; then
  echo "usage: sh selftest/run.sh <dir-with-node_modules> [backstop-binary]" >&2
  exit 2
fi

pack_dir=$(cd "$(dirname "$0")/.." && pwd)
toolchain_dir=$(cd "$1" && pwd)
backstop_bin=${2:-}
if [ ! -d "$toolchain_dir/node_modules" ]; then
  echo "selftest: $toolchain_dir has no node_modules/" >&2
  exit 2
fi

failures=0
pass() { echo "ok   - $1"; }
fail() { echo "FAIL - $1" >&2; failures=$((failures + 1)); }

# Physical path: the tools report realpaths, and the producer strips "$PWD/" from
# the summary's absolute keys, so a symlinked temp dir (macOS /var -> /private/var)
# would otherwise make every path comparison below miss.
work=$(cd "$(mktemp -d)" && pwd -P)
trap 'rm -rf "$work"' EXIT INT TERM
proj="$work/project"
cp -R "$pack_dir/selftest/project" "$proj"
ln -s "$toolchain_dir/node_modules" "$proj/node_modules"
installed="$proj/.backstop/packs/backstop-ai/typescript-toolchain"
mkdir -p "$installed"
cp -R "$pack_dir/pack.yml" "$pack_dir/eslint.config.mjs" "$pack_dir/scripts" "$installed/"

# The ts-test engine must be exempt from diff-scope filtering (see pack.yml).
if awk '/^  ts-test:/{f=1;next} f&&/^  [a-z]/{f=0} f&&/exempt_from_scope_filter: true/{found=1} END{exit !found}' "$pack_dir/pack.yml"; then
  pass "drift: ts-test declares exempt_from_scope_filter: true"
else
  fail "drift: ts-test does not declare exempt_from_scope_filter: true"
fi

# --- pack.yml readers --------------------------------------------------------
# classification_list <source|test>: the quoted globs under that classification key.
classification_list() {
  awk -v key="  $1:" '
    $0 == key { on = 1; next }
    on && /^    - "/ { s = $0; sub(/^    - "/, "", s); sub(/"$/, "", s); print s; next }
    on && /^    #/ { next }
    on { exit }
  ' "$pack_dir/pack.yml"
}
# engine_command <engine-id>: the declared command line of that engine.
engine_command() {
  awk -v key="  $1:" '
    $0 == key { on = 1; next }
    on && /^    command: / { s = $0; sub(/^    command: /, "", s); print s; exit }
  ' "$pack_dir/pack.yml"
}
# run_split <cmd> [extra args...]: run a command line the way core does — split on
# whitespace, no shell quote removal, no globbing.
run_split() {
  line=$1
  shift
  (
    set -f
    # shellcheck disable=SC2086 # whitespace splitting is the point.
    set -- $line "$@"
    "$@"
  )
}

# --- 1. drift ------------------------------------------------------------------
classification_list source | sort > "$work/source.txt"
classification_list test | sort > "$work/test.txt"
test_cmd=$(engine_command ts-test)
echo "$test_cmd" | tr ' ' '\n' | sed -n 's/^--coverage\.include=//p' | sort > "$work/cmd-include.txt"
echo "$test_cmd" | tr ' ' '\n' | sed -n 's/^--coverage\.exclude=//p' | sort > "$work/cmd-exclude.txt"
sed -n "s/^ *'--coverage\.include=\(.*\)' \\\\\$/\1/p" "$pack_dir/scripts/coverage-produce.sh" | sort > "$work/prod-include.txt"
sed -n "s/^ *'--coverage\.exclude=\(.*\)' \\\\\$/\1/p" "$pack_dir/scripts/coverage-produce.sh" | sort > "$work/prod-exclude.txt"

if [ -s "$work/source.txt" ] && [ -s "$work/test.txt" ]; then
  pass "drift: read classification.source and classification.test from pack.yml"
else
  fail "drift: could not read classification lists from pack.yml"
fi
if echo "$test_cmd" | grep -q -- '--coverage\.all'; then
  fail "drift: ts-test still passes --coverage.all (ignored by Vitest 4+)"
fi
if grep -v '^ *#' "$pack_dir/scripts/coverage-produce.sh" | grep -q -- '--coverage\.all'; then
  fail "drift: coverage-produce.sh still passes --coverage.all (ignored by Vitest 4+)"
fi
if diff "$work/source.txt" "$work/cmd-include.txt" >/dev/null; then
  pass "drift: ts-test --coverage.include equals classification.source"
else
  fail "drift: ts-test --coverage.include differs from classification.source"
fi
if [ -z "$(comm -23 "$work/test.txt" "$work/cmd-exclude.txt")" ]; then
  pass "drift: ts-test --coverage.exclude covers classification.test"
else
  fail "drift: ts-test --coverage.exclude is missing: $(comm -23 "$work/test.txt" "$work/cmd-exclude.txt" | tr '\n' ' ')"
fi
if diff "$work/cmd-include.txt" "$work/prod-include.txt" >/dev/null && diff "$work/cmd-exclude.txt" "$work/prod-exclude.txt" >/dev/null; then
  pass "drift: coverage-produce.sh fallback carries the ts-test include/exclude lists"
else
  fail "drift: coverage-produce.sh include/exclude lists differ from the ts-test command"
fi

# --- 2. lint ---------------------------------------------------------------------
lint_cmd=$(engine_command ts-lint)
(cd "$proj" && run_split "$lint_cmd" --config "$installed/eslint.config.mjs" .) > "$work/lint.json" 2> "$work/lint.err"
if jq -e 'type == "array" and length > 0' "$work/lint.json" >/dev/null 2>&1; then
  pass "lint: ts-lint produced an ESLint JSON report"
else
  fail "lint: ts-lint produced no ESLint JSON report ($(head -c 400 "$work/lint.err"))"
fi
# lint_ids <relative-path>: "ruleId" per message for that file, one per line.
lint_ids() {
  jq -r --arg p "$proj/$1" '.[] | select(.filePath == $p) | .messages[] | (.ruleId // "fatal")' "$work/lint.json"
}
for clean in tests/fixtures/standin/draft.cjs tests/fixtures/standin/checks/slot.cjs scripts/tool.mjs src/used.ts src/untested.ts src/types-only.ts src/workflow.ts tests/used.test.ts tests/helpers.ts; do
  found=$(lint_ids "$clean" | tr '\n' ' ')
  if [ -z "$found" ]; then
    pass "lint: $clean is clean"
  else
    fail "lint: $clean has findings: $found"
  fi
done
expect_rule() {
  if lint_ids "$1" | grep -qx "$2"; then
    pass "lint: $1 fires $2"
  else
    fail "lint: $1 should fire $2 (got: $(lint_ids "$1" | tr '\n' ' '))"
  fi
}
expect_rule lint-negative/undefined-name.js no-undef
expect_rule lint-negative/undefined-name.cjs no-undef
expect_rule lint-negative/require-in-esm.mjs @typescript-eslint/no-require-imports
expect_rule lint-negative/require-in-esm.mjs no-undef

# --- 3. coverage -------------------------------------------------------------------
# check_records <label>: assert the per-file records the convert emits.
check_records() {
  label=$1
  summary="$proj/.backstop/ts-coverage/backstop-summary.json"
  if [ ! -f "$summary" ]; then
    fail "coverage ($label): producer wrote no backstop-summary.json"
    return
  fi
  sh "$pack_dir/scripts/coverage-to-records.sh" < "$summary" > "$work/records.json" 2>/dev/null
  rec() { jq -c --arg p "$1" '[.[] | select(.path == $p)] | first // empty' "$work/records.json"; }
  r=$(rec src/types-only.ts)
  if [ -n "$r" ] && echo "$r" | jq -e '.total == 0' >/dev/null; then
    pass "coverage ($label): types-only module has a total-0 record ($r)"
  else
    fail "coverage ($label): types-only module needs a total-0 record (got: ${r:-none})"
  fi
  r=$(rec src/untested.ts)
  if [ -n "$r" ] && echo "$r" | jq -e '.covered == 0 and .total > 0' >/dev/null; then
    pass "coverage ($label): untested module has a 0/N record ($r)"
  else
    fail "coverage ($label): untested module needs a 0/N record (got: ${r:-none})"
  fi
  r=$(rec src/used.ts)
  if [ -n "$r" ] && echo "$r" | jq -e '.covered > 0' >/dev/null; then
    pass "coverage ($label): tested module has covered > 0 ($r)"
  else
    fail "coverage ($label): tested module needs covered > 0 (got: ${r:-none})"
  fi
  stray=$(jq -r '.[] | .path | select(startswith("tests/"))' "$work/records.json" | tr '\n' ' ')
  if [ -z "$stray" ]; then
    pass "coverage ($label): no record for tests/ helpers or fixtures"
  else
    fail "coverage ($label): non-source files got records: $stray"
  fi
  stray=$(jq -r '.[] | .path | select(startswith(".backstop/") or startswith("node_modules/"))' "$work/records.json" | tr '\n' ' ')
  if [ -z "$stray" ]; then
    pass "coverage ($label): no record under .backstop/ or node_modules/"
  else
    fail "coverage ($label): records leaked from installed packs or dependencies: $stray"
  fi
}

# 3a. single-run convention: the ts-test engine writes the summary, the producer reuses it.
(cd "$proj" && run_split "$test_cmd") > "$work/test.out" 2>&1
if jq -e '.success == true and .numPassedTests >= 1' "$proj/.backstop/ts-test-results.json" >/dev/null 2>&1; then
  pass "coverage: ts-test ran the selftest suite green"
else
  fail "coverage: ts-test did not run green ($(tail -c 400 "$work/test.out"))"
fi
(cd "$proj" && sh "$installed/scripts/coverage-produce.sh")
check_records "single-run reuse"

# 3b. producer fallback: no fresh summary, so the producer runs vitest itself.
rm -rf "$proj/.backstop/ts-coverage"
(cd "$proj" && sh "$installed/scripts/coverage-produce.sh")
check_records "producer fallback"

# --- 4. coverage exclusions ------------------------------------------------------------
excl_reason="Runs inside the Temporal workflow bundle; v8 coverage cannot see it"
exclusions="$proj/.backstop/coverage-exclusions"
{
  printf '# selftest coverage exclusions\n\n'
  printf 'src/workflow.ts\t%s\n' "$excl_reason"
  printf 'src/untested.ts\n'
  printf 'src/used.ts\tcontrol\001character in the justification\n'
  printf 'src/ctl\001.ts\tcontrol character in the path\n'
  printf 'src/absent.ts\tdeclared but never in the summary\n'
  printf 'pkg/worker/worker.go\tanother toolchain pack answers for this path\n'
} > "$exclusions"

# check_exclusions <label>: run the producer (stderr captured), convert, assert.
check_exclusions() {
  label=$1
  (cd "$proj" && sh "$installed/scripts/coverage-produce.sh") 2> "$work/produce.err"
  sh "$pack_dir/scripts/coverage-to-records.sh" < "$proj/.backstop/ts-coverage/backstop-summary.json" > "$work/records.json" 2>/dev/null
  rec() { jq -c --arg p "$1" '[.[] | select(.path == $p)] | first // empty' "$work/records.json"; }
  r=$(rec src/workflow.ts)
  if [ -n "$r" ] && echo "$r" | jq -e --arg why "$excl_reason" '.excluded == true and .measured == true and .total > 0 and .justification == $why' >/dev/null; then
    pass "exclusions ($label): justified path is excluded with its reason ($r)"
  else
    fail "exclusions ($label): justified path needs excluded:true + reason (got: ${r:-none})"
  fi
  r=$(rec src/untested.ts)
  if [ -n "$r" ] && echo "$r" | jq -e '.excluded == false and .covered == 0 and .total > 0 and (has("justification") | not)' >/dev/null; then
    pass "exclusions ($label): missing-justification line is dropped; path stays measured ($r)"
  else
    fail "exclusions ($label): missing-justification path must stay a measured 0/N record (got: ${r:-none})"
  fi
  r=$(rec src/used.ts)
  if [ -n "$r" ] && echo "$r" | jq -e '.excluded == false and .covered > 0' >/dev/null; then
    pass "exclusions ($label): control character in justification is rejected ($r)"
  else
    fail "exclusions ($label): control-character justification must not exclude (got: ${r:-none})"
  fi
  if jq -e 'any(.[]; .path | explode | any(. < 32))' "$work/records.json" >/dev/null; then
    fail "exclusions ($label): a control-character path produced a record"
  else
    pass "exclusions ($label): control character in path is rejected"
  fi
  r=$(rec src/absent.ts)
  if [ -n "$r" ] && echo "$r" | jq -e '.excluded == true and .measured == false and .total == 0 and .justification == "declared but never in the summary"' >/dev/null; then
    pass "exclusions ($label): declared path absent from the summary gets a synthetic excluded record"
  else
    fail "exclusions ($label): absent declared path needs a synthetic excluded record (got: ${r:-none})"
  fi
  r=$(rec pkg/worker/worker.go)
  if [ -z "$r" ]; then
    pass "exclusions ($label): declared non-TS/JS path (.go) yields no record"
  else
    fail "exclusions ($label): declared .go path must yield no TS record (got: $r)"
  fi
  r=$(rec src/types-only.ts)
  if [ -n "$r" ] && echo "$r" | jq -e '.excluded == false and .total == 0' >/dev/null; then
    pass "exclusions ($label): unlisted path is unchanged"
  else
    fail "exclusions ($label): unlisted path changed (got: ${r:-none})"
  fi
  dropped=$(grep -c 'dropping malformed coverage exclusion' "$work/produce.err")
  if [ "$dropped" -eq 3 ]; then
    pass "exclusions ($label): producer reported 3 dropped declarations"
  else
    fail "exclusions ($label): producer reported $dropped dropped declarations, want 3"
  fi
}

# 4a. single-run reuse: ts-test writes the summary, the producer folds in the exclusions.
rm -rf "$proj/.backstop/ts-coverage" "$proj/.backstop/ts-test-results.json"
(cd "$proj" && run_split "$test_cmd") > "$work/test.out" 2>&1
check_exclusions "single-run reuse"
# 4b. producer fallback.
rm -rf "$proj/.backstop/ts-coverage"
check_exclusions "producer fallback"
rm -f "$exclusions"

# --- 6. diff-scoped selection --------------------------------------------------------
# The ts-test engine is project-wide with scope_handoff: file and a producer: core
# runs scripts/test-produce.sh with the declared command's arguments and hands the
# gate scope over in BACKSTOP_SCOPE_MODE / BACKSTOP_SCOPE_FILE. These checks drive
# the producer exactly that way.
if echo "$test_cmd" | tr ' ' '\n' | grep -qx run && ! echo "$test_cmd" | tr ' ' '\n' | grep -qx -- '--'; then
  pass "selection: the declared ts-test command contains 'run' and no lone --"
else
  fail "selection: the declared ts-test command must contain 'run' and no lone --"
fi
if awk '/^  ts-test:/{f=1;next} f&&/^  [a-z]/{f=0} f&&/scope_kind: project-wide/{k=1} f&&/scope_handoff: file/{h=1} END{exit !(k&&h)}' "$pack_dir/pack.yml"; then
  pass "selection: ts-test declares scope_kind: project-wide and scope_handoff: file"
else
  fail "selection: ts-test must declare scope_kind: project-wide and scope_handoff: file"
fi
classification_list source | sed 's/^\*\*\/\*//' | sort > "$work/source-ext.txt"
sed -n "s/^const SOURCE_EXTENSIONS = \[\(.*\)\];$/\1/p" "$pack_dir/scripts/test-select.mjs" | tr -d "' " | tr ',' '\n' | sort > "$work/select-ext.txt"
if [ -s "$work/select-ext.txt" ] && diff "$work/source-ext.txt" "$work/select-ext.txt" >/dev/null; then
  pass "selection: test-select.mjs source extensions equal classification.source"
else
  fail "selection: test-select.mjs source extensions differ from classification.source"
fi

# Selection reads git only to check that the opt-in file is tracked.
printf 'node_modules\n.backstop/packs/\n.backstop/ts-coverage/\n.backstop/ts-test-results.json\n' > "$proj/.gitignore"
gitp() { git -C "$proj" -c user.name=selftest -c user.email=selftest@example.invalid "$@"; }
gitp init -q
gitp add -A >/dev/null 2>&1
gitp commit -q -m selftest-base >/dev/null 2>&1
base_sha=$(gitp rev-parse HEAD)
# A test that imports nothing from src/, so no source change can select it.
cat > "$proj/tests/standalone.test.ts" <<'TS'
import { expect, it } from 'vitest'

it('adds without any source module', () => {
  expect(1 + 1).toBe(2)
})
TS
results="$proj/.backstop/ts-test-results.json"
cov_summary="$proj/.backstop/ts-coverage/coverage-summary.json"
handoff="$work/scope-handoff"
# produce_env <mode|-> [scope path...]: run the producer the way core does. Mode -
# sets no variables (an older core); all sets no file; diff and file write the
# paths NUL-terminated to a file outside the project. stdout is discarded.
produce_env() {
  mode=$1
  shift
  rm -f "$results" "$cov_summary"
  : > "$handoff"
  for p in "$@"; do printf '%s\0' "$p" >> "$handoff"; done
  (
    cd "$proj" || exit 2
    set -f
    set -- $(echo "$test_cmd" | cut -d ' ' -f 2-)
    case $mode in
      -) "$installed/scripts/test-produce.sh" "$@" ;;
      all) BACKSTOP_SCOPE_MODE=all "$installed/scripts/test-produce.sh" "$@" ;;
      *) BACKSTOP_SCOPE_MODE=$mode BACKSTOP_SCOPE_FILE=$handoff "$installed/scripts/test-produce.sh" "$@" ;;
    esac
  ) > "$work/produce.out" 2>&1
  produce_status=$?
}
produce() { produce_env diff "$@"; }
ran() { jq -r '[.testResults[].name | sub(".*/tests/"; "tests/")] | sort | join(" ")' "$results"; }
scope_mode() { jq -r '.backstopScope.mode' "$results"; }
scope_reason() { jq -r '.backstopScope.reason' "$results"; }
warnings() { sh "$pack_dir/scripts/test-to-sarif.sh" < "$results" 2>/dev/null | jq '[.runs[0].results[] | select(.level == "warning" and .ruleId == "vitest-diff-scoped")] | length'; }
errors() { sh "$pack_dir/scripts/test-to-sarif.sh" < "$results" 2>/dev/null | jq '[.runs[0].results[] | select(.level == "error")] | length'; }
full_suite="tests/standalone.test.ts tests/used.test.ts"
scope_config="$proj/.backstop/ts-test-scope"
# set_config <printf-format>: write the scope config and track it.
set_config() { printf "$1" > "$scope_config" && gitp add -- .backstop/ts-test-scope; }
# expect_mode <mode> <label> <scope path...> (a diff scope)
expect_mode() {
  want=$1 label=$2
  shift 2
  produce "$@"
  if [ "$(scope_mode)" = "$want" ]; then
    pass "selection: $label"
  else
    fail "selection: $label (got $(scope_mode) over [$(ran)]: $(scope_reason))"
  fi
}

# 6a. opt-in, and a scope core actually handed over.
produce src/used.ts
if [ "$(scope_mode)" = full ] && [ "$(ran)" = "$full_suite" ] && [ "$(warnings)" -eq 0 ]; then
  pass "selection: without .backstop/ts-test-scope the run is full and carries no warning"
else
  fail "selection: opt-out run was $(scope_mode) over [$(ran)] ($(tail -c 300 "$work/produce.out"))"
fi
printf '# selftest\n' > "$scope_config"
expect_mode full "an untracked .backstop/ts-test-scope does not opt in" src/used.ts
set_config '# selftest\nignore\tdocs/**\n'
produce_env - src/used.ts
if [ "$(scope_mode)" = full ] && [ "$(ran)" = "$full_suite" ] && [ "$(warnings)" -eq 0 ]; then
  pass "selection: with no scope handed over (an older core) the run is full"
else
  fail "selection: no-handoff run was $(scope_mode) over [$(ran)]: $(scope_reason)"
fi
produce_env all src/used.ts
if [ "$(scope_mode)" = full ] && [ "$(ran)" = "$full_suite" ]; then
  pass "selection: an --all scope runs the full suite"
else
  fail "selection: all-mode run was $(scope_mode) over [$(ran)]: $(scope_reason)"
fi
(
  cd "$proj" && set -f && set -- $(echo "$test_cmd" | cut -d ' ' -f 2-)
  rm -f "$results"
  BACKSTOP_SCOPE_MODE=diff "$installed/scripts/test-produce.sh" "$@"
) > "$work/produce.out" 2>&1
if [ "$(scope_mode)" = full ]; then
  pass "selection: a diff mode with no scope file falls back to the full suite"
else
  fail "selection: diff mode without a file was $(scope_mode): $(scope_reason)"
fi
printf 'src/used.ts' > "$handoff"
(
  cd "$proj" && set -f && set -- $(echo "$test_cmd" | cut -d ' ' -f 2-)
  rm -f "$results"
  BACKSTOP_SCOPE_MODE=diff BACKSTOP_SCOPE_FILE=$handoff "$installed/scripts/test-produce.sh" "$@"
) > "$work/produce.out" 2>&1
if [ "$(scope_mode)" = full ]; then
  pass "selection: a scope file that is not NUL-terminated falls back to the full suite"
else
  fail "selection: unterminated scope file was $(scope_mode): $(scope_reason)"
fi

# 6b. a changed source file runs only the tests that import it, and says so.
produce src/used.ts
if [ "$(scope_mode)" = scoped ] && [ "$(ran)" = "tests/used.test.ts" ] && [ "$(warnings)" -eq 1 ]; then
  pass "selection: a changed source file runs only its importing tests, with one warning"
else
  fail "selection: scoped run was $(scope_mode) over [$(ran)], $(warnings) warning(s) ($(tail -c 300 "$work/produce.out"))"
fi
if [ -f "$cov_summary" ] && [ ! "$cov_summary" -ot "$results" ]; then
  pass "selection: the scoped run's coverage summary is not older than its report (coverage reuses it)"
else
  fail "selection: coverage summary missing or older than the annotated report"
fi
(cd "$proj" && sh "$installed/scripts/coverage-produce.sh")
check_records "scoped-run reuse"
produce_env file src/used.ts
if [ "$(scope_mode)" = scoped ] && [ "$(ran)" = "tests/used.test.ts" ]; then
  pass "selection: a file-mode scope selects the same way"
else
  fail "selection: file-mode run was $(scope_mode) over [$(ran)]: $(scope_reason)"
fi
# 6c. a changed test file runs itself.
produce tests/standalone.test.ts
if [ "$(scope_mode)" = scoped ] && [ "$(ran)" = "tests/standalone.test.ts" ]; then
  pass "selection: a changed test file runs itself"
else
  fail "selection: changed-test run was $(scope_mode) over [$(ran)]"
fi
# 6d. a failing selected test is still an error finding.
cat > "$proj/tests/used-fails.test.ts" <<'TS'
import { expect, it } from 'vitest'
import { overall } from '../src/used'

it('a selected failing test still fails', () => {
  expect(overall({ round: 1, slot: 1 }, 4)).toBe(-1)
})
TS
produce src/used.ts
if [ "$(scope_mode)" = scoped ] && [ "$(errors)" -ge 1 ] && echo "$(ran)" | grep -q 'tests/used-fails.test.ts'; then
  pass "selection: a failing test the diff selects is still an error finding"
else
  fail "selection: failing selected test produced $(errors) error(s) over [$(ran)]"
fi
rm -f "$proj/tests/used-fails.test.ts"
# 6d2. a narrowed run never lets its warning stand in for a crash.
# (A) every selected test passes, but vitest exits non-zero on an unhandled error.
cat > "$proj/tests/used-unhandled.test.ts" <<'TS'
import { expect, it } from 'vitest'
import { overall } from '../src/used'

it('passes but leaves an unhandled error behind', async () => {
  expect(overall({ round: 1, slot: 1 }, 4)).toBe(1)
  setTimeout(() => {
    throw new Error('unhandled after the test passed')
  }, 0)
  await new Promise((resolve) => setTimeout(resolve, 20))
})
TS
produce src/used.ts
if [ "$produce_status" -ne 0 ] && [ -f "$results" ] && [ "$(jq -r '.backstopScope // "absent"' "$results")" = absent ] && [ "$(warnings)" -eq 0 ]; then
  pass "selection: a scoped run that exits non-zero with every test passing is left unannotated (no warning to mask the crash)"
else
  fail "selection: non-zero scoped run was annotated or exited $produce_status ($(tail -c 300 "$work/produce.out"))"
fi
rm -f "$proj/tests/used-unhandled.test.ts"
# (B) vitest dies before writing a report: no stale report may survive.
echo '{"numTotalTests":1,"success":true,"testResults":[{"name":"stale","status":"passed","assertionResults":[]}]}' > "$results"
printf 'export default {{{ not valid\n' > "$proj/vitest.config.ts"
(
  cd "$proj" || exit 2
  set -f
  set -- $(echo "$test_cmd" | cut -d ' ' -f 2-)
  printf 'src/used.ts\0' > "$handoff"
  BACKSTOP_SCOPE_MODE=diff BACKSTOP_SCOPE_FILE=$handoff "$installed/scripts/test-produce.sh" "$@"
) > "$work/produce.out" 2>&1
crash_status=$?
if [ "$crash_status" -ne 0 ] && [ ! -f "$results" ]; then
  pass "selection: a run that dies before writing its report leaves no report (the stale one is gone)"
else
  fail "selection: crashed run exited $crash_status and left a report: $(head -c 200 "$results" 2>/dev/null)"
fi
rm -f "$proj/vitest.config.ts"
# (C) a scope file that is not valid UTF-8 runs the full suite.
printf 'src/\377bad.ts\0' > "$handoff"
(
  cd "$proj" || exit 2
  set -f
  set -- $(echo "$test_cmd" | cut -d ' ' -f 2-)
  rm -f "$results"
  BACKSTOP_SCOPE_MODE=diff BACKSTOP_SCOPE_FILE=$handoff "$installed/scripts/test-produce.sh" "$@"
) > "$work/produce.out" 2>&1
if [ "$(scope_mode)" = full ] && scope_reason | grep -q 'reading the scope file failed'; then
  pass "selection: a scope file that is not valid UTF-8 falls back to the full suite"
else
  fail "selection: non-UTF-8 scope file gave $(scope_mode): $(scope_reason)"
fi
# 6e. nothing in scope that can change a result.
produce
if [ "$(scope_mode)" = none ] && [ "$(ran)" = "" ] && [ "$(warnings)" -eq 1 ] && [ "$(cat "$cov_summary")" = "{}" ]; then
  pass "selection: an empty scope runs nothing, writes an empty summary, and warns"
else
  fail "selection: empty-scope run was $(scope_mode) over [$(ran)]: $(scope_reason)"
fi
mkdir -p "$proj/docs" && echo notes > "$proj/docs/notes.md"
expect_mode none "an ignored path alone runs nothing" docs/notes.md
expect_mode none "a deleted test file alone runs nothing" tests/gone.test.ts
# 6f. every path the import graph cannot see falls back to the full suite.
echo 'readme' > "$proj/README.md"
for scope in package.json README.md src/deleted.ts tsconfig.json pnpm-lock.yaml vitest.config.ts .backstop/ts-test-scope src/__mocks__/used.ts src/__tests__/helper.ts; do
  produce src/used.ts "$scope"
  if [ "$(scope_mode)" = full ] && [ "$(ran)" = "$full_suite" ] && [ "$(warnings)" -eq 0 ]; then
    pass "selection: $scope in scope falls back to the full suite"
  else
    fail "selection: $scope in scope ran $(scope_mode) over [$(ran)]: $(scope_reason)"
  fi
done
mkdir -p "$proj/src/__mocks__" && echo 'export const overall = () => 0' > "$proj/src/__mocks__/used.ts"
expect_mode full "an existing __mocks__ module falls back to the full suite" src/__mocks__/used.ts
rm -rf "$proj/src/__mocks__"
expect_mode full "a directory in the scope falls back to the full suite" src
set_config 'ignore\t**\n'
expect_mode full "ignore ** cannot hide package.json" package.json
# 6g. a rename: core's scope carries both sides; the old path is gone from disk.
set_config '# selftest\n'
gitp mv src/used.ts src/core.ts
expect_mode full "a renamed source module (both sides in scope) falls back to the full suite" src/core.ts src/used.ts
gitp mv src/core.ts src/used.ts
# 6h. testdata paths reach the selection (core hands the list over unfiltered).
mkdir -p "$proj/testdata" && echo '{}' > "$proj/testdata/input.json"
expect_mode full "a testdata change falls back to the full suite" testdata/input.json
set_config 'map\ttestdata/**\ttests/used.test.ts\n'
produce testdata/input.json
if [ "$(scope_mode)" = scoped ] && [ "$(ran)" = "tests/used.test.ts" ]; then
  pass "selection: map testdata/** fires on a testdata change"
else
  fail "selection: testdata map run was $(scope_mode) over [$(ran)]: $(scope_reason)"
fi
rm -rf "$proj/testdata"
# 6i. non-ASCII and dash-leading paths.
set_config '# selftest\n'
printf "export const accent = () => 'e'\n" > "$proj/src/café.ts"
cat > "$proj/tests/accent.test.ts" <<'TS'
import { expect, it } from 'vitest'
import { accent } from '../src/café'

it('reads a non-ASCII module', () => {
  expect(accent()).toBe('e')
})
TS
produce 'src/café.ts'
if [ "$(scope_mode)" = scoped ] && [ "$(ran)" = "tests/accent.test.ts" ]; then
  pass "selection: a non-ASCII scope path selects its importing test"
else
  fail "selection: non-ASCII path run was $(scope_mode) over [$(ran)]: $(scope_reason)"
fi
rm -f "$proj/src/café.ts" "$proj/tests/accent.test.ts"
printf "export const dash = () => 1\n" > "$proj/-dash.ts"
cat > "$proj/tests/dash.test.ts" <<'TS'
import { expect, it } from 'vitest'
import { dash } from '../-dash'

it('reads a module whose name starts with a dash', () => {
  expect(dash()).toBe(1)
})
TS
produce -dash.ts
if [ "$(scope_mode)" = scoped ] && [ "$(ran)" = "tests/dash.test.ts" ]; then
  pass "selection: scope paths that start with - are paths, not flags"
else
  fail "selection: dash path run was $(scope_mode) over [$(ran)]: $(scope_reason)"
fi
rm -f "$proj/-dash.ts" "$proj/tests/dash.test.ts"
# 6j. declarations.
set_config 'always\ttests/standalone.test.ts\nmap\tdocs/**\ttests/used.test.ts\n'
produce docs/notes.md
if [ "$(scope_mode)" = scoped ] && [ "$(ran)" = "$full_suite" ]; then
  pass "selection: map and always declarations add their tests"
else
  fail "selection: map/always run was $(scope_mode) over [$(ran)]"
fi
set_config 'always\ttests/no-such-*.test.ts\n'
expect_mode full "a declared glob matching no file falls back to the full suite" src/used.ts
set_config 'bogus\tsrc/**\n'
expect_mode full "a malformed .backstop/ts-test-scope falls back to the full suite" src/used.ts
# 6k. a selection too large for the vitest related command line runs full.
set_config '# selftest\n'
mkdir -p "$proj/src/gen"
i=0
while [ $i -le 2000 ]; do
  : > "$proj/src/gen/m$i.ts"
  i=$((i + 1))
done
(cd "$proj" && ls src/gen | sed 's|^|src/gen/|') > "$work/gen.txt"
# shellcheck disable=SC2046 # one argument per generated path, none with spaces.
produce $(cat "$work/gen.txt")
if [ "$(scope_mode)" = full ]; then
  pass "selection: more than 2000 selected paths fall back to the full suite"
else
  fail "selection: oversized selection was $(scope_mode): $(scope_reason)"
fi
rm -rf "$proj/src/gen"
# 6l. the --exclude=<glob> form keeps a test under .backstop/ out of the full run.
mkdir -p "$proj/.backstop/stray"
cat > "$proj/.backstop/stray/stray.test.ts" <<'TS'
import { it } from 'vitest'

it('must never run from .backstop', () => {
  throw new Error('collected from .backstop')
})
TS
(cd "$proj" && run_split "$test_cmd") > "$work/test.out" 2>&1
if jq -e '[.testResults[].name | select(contains("/.backstop/"))] | length == 0' "$results" >/dev/null 2>&1 && jq -e '.testResults | length > 0' "$results" >/dev/null 2>&1; then
  pass "selection: --exclude=**/.backstop/** keeps a test under .backstop/ out of the run"
else
  fail "selection: a test under .backstop/ ran ($(tail -c 300 "$work/test.out"))"
fi
rm -rf "$proj/.backstop/stray"
# 6m. a project in a subdirectory of its repository: core's paths are relative to
# the project root, and the tracked check runs from there.
mono="$work/mono"
mkdir -p "$mono/sub/.backstop" "$mono/sub/tests"
printf '# selftest\n' > "$mono/sub/.backstop/ts-test-scope"
printf "import { it } from 'vitest'\n\nit('x', () => {})\n" > "$mono/sub/tests/x.test.ts"
git -C "$mono" init -q
git -C "$mono" add -A >/dev/null 2>&1
git -C "$mono" -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m mono >/dev/null 2>&1
printf 'tests/x.test.ts\0' > "$work/mono-scope"
sub_decision=$(node "$installed/scripts/test-select.mjs" "$mono/sub" diff "$work/mono-scope" | tr '\n' ' ')
if [ "$sub_decision" = "$(printf 'scoped\t1 path(s) handed to vitest related tests/x.test.ts ')" ]; then
  pass "selection: a project in a subdirectory of its repository selects from root-relative paths"
else
  fail "selection: subdirectory project gave [$sub_decision]"
fi
gitp reset -q --hard "$base_sha"
rm -rf "$scope_config" "$proj/tests/standalone.test.ts" "$proj/docs" "$proj/README.md" "$results" "$proj/.backstop/ts-coverage" "$proj/.gitignore"

# --- 5. gate (optional) ---------------------------------------------------------------
if [ -n "$backstop_bin" ]; then
  # Install through backstop itself so backstop.lock is real (the copy above has none).
  rm -rf "$proj/.backstop/packs" "$proj/.backstop/ts-coverage" "$proj/.backstop/ts-test-results.json"
  cat > "$proj/backstop.yml" <<'YML'
project: typescript-toolchain-selftest
enforcement:
    coverage_floor: 80
    policy:
        pack_engines: { level: off }
        artifact_validation: { level: off }
        artifact_status_drift: { level: off }
        test_verification: { level: off }
        contract_signature: { level: off }
        test_substantiveness: { level: off }
YML
  if ! (cd "$proj" && "$backstop_bin" pack add "$pack_dir") > "$work/pack-add.txt" 2>&1; then
    fail "gate: backstop pack add failed: $(tail -3 "$work/pack-add.txt" | tr '\n' ' ')"
  fi
  # The gate's coverage step reads spec verifications from specs/; none are needed.
  mkdir -p "$proj/specs"
  (cd "$proj" && git init -q && git add -A >/dev/null 2>&1 && git -c user.name=selftest -c user.email=selftest@example.invalid commit -q -m selftest >/dev/null 2>&1)
  (cd "$proj" && "$backstop_bin" gate --file src/types-only.ts --file tests/fixtures/standin/draft.cjs --file tests/fixtures/standin/checks/slot.cjs) > "$work/gate-pass.txt" 2>&1
  status=$?
  if [ "$status" -eq 0 ] && ! grep -q 'coverage_unmeasured' "$work/gate-pass.txt"; then
    pass "gate: types-only module and fixture .cjs pass the coverage step"
  else
    fail "gate: types-only + fixture run exited $status: $(grep -i 'cover\|fail' "$work/gate-pass.txt" | head -5 | tr '\n' ' ')"
  fi
  (cd "$proj" && "$backstop_bin" gate --file src/untested.ts) > "$work/gate-fail.txt" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -q 'src/untested.ts coverage 0/[1-9][0-9]* (statement) below threshold' "$work/gate-fail.txt" && ! grep -q 'coverage_unmeasured' "$work/gate-fail.txt"; then
    pass "gate: untested module fails coverage as a measured 0% gap"
  else
    fail "gate: untested module run exited $status: $(grep -i 'cover' "$work/gate-fail.txt" | head -5 | tr '\n' ' ')"
  fi
  # Exclusions end to end: one justified line, one bare line, one with a control character.
  {
    printf 'src/workflow.ts\t%s\n' "$excl_reason"
    printf 'src/untested.ts\n'
    printf 'src/untested.ts\tcontrol\001character\n'
  } > "$proj/.backstop/coverage-exclusions"
  (cd "$proj" && "$backstop_bin" gate --file src/workflow.ts) > "$work/gate-excl.txt" 2>&1
  status=$?
  if [ "$status" -eq 0 ] && grep -q 'coverage_exclusion' "$work/gate-excl.txt" && grep -qF "src/workflow.ts (metric statement) is suppressed by a pack-declared exclusion: $excl_reason" "$work/gate-excl.txt"; then
    pass "gate: justified exclusion passes with a coverage_exclusion warning carrying its reason"
  else
    fail "gate: justified exclusion run exited $status: $(grep -i 'cover\|exclu' "$work/gate-excl.txt" | head -5 | tr '\n' ' ')"
  fi
  (cd "$proj" && "$backstop_bin" gate --file src/untested.ts) > "$work/gate-unjustified.txt" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -q 'src/untested.ts coverage 0/[1-9][0-9]* (statement) below threshold' "$work/gate-unjustified.txt" && ! grep -q 'coverage_exclusion' "$work/gate-unjustified.txt"; then
    pass "gate: unjustified and control-character declarations leave the path enforced"
  else
    fail "gate: unjustified declaration run exited $status: $(grep -i 'cover\|exclu' "$work/gate-unjustified.txt" | head -5 | tr '\n' ' ')"
  fi
  # Test failures survive diff-scope filtering: a failing test in a file the
  # scoped change never touched must still RED the gate (exempt_from_scope_filter).
  cat > "$proj/tests/out-of-scope.test.ts" <<'TS'
import { expect, it } from 'vitest'

it('an out-of-scope test failure still reds a scoped gate', () => {
  expect(1).toBe(2)
})
TS
  # pack_engines is off above (other engines are not under test there); enable it here.
  # `pack add` rewrites backstop.yml, so drop the pack_engines policy entry in either form.
  awk '/^ *pack_engines: *\{ *level: *"?off"? *\} *$/ {next}
       /^ *pack_engines: *$/ {skip=1; next}
       skip && /^ *level:/ {skip=0; next}
       {skip=0; print}' "$proj/backstop.yml" > "$work/backstop-oos.yml"
  cp "$proj/backstop.yml" "$work/backstop-saved.yml"
  cp "$work/backstop-oos.yml" "$proj/backstop.yml"
  (cd "$proj" && "$backstop_bin" gate --file src/types-only.ts) > "$work/gate-oos.txt" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -q 'an out-of-scope test failure still reds a scoped gate' "$work/gate-oos.txt"; then
    pass "gate: a failing test outside the scoped files still fails the gate"
  else
    fail "gate: out-of-scope test failure run exited $status: $(grep -i 'fail\|vitest' "$work/gate-oos.txt" | head -5 | tr '\n' ' ')"
  fi
  rm -f "$proj/tests/out-of-scope.test.ts"
  # With selection opted in, the same out-of-scope failure is NOT run by a scoped
  # gate on a core that hands the scope over (the documented trade; `gate --all`
  # still runs it), and the gate carries the selection warning instead of a silent
  # pass. On a core that does not know scope_handoff, no scope is handed over and
  # the run must be the full suite, so the failure still REDs the gate. Which core
  # this is shows in the report's own selection reason. A failure the scope selects
  # REDs either way.
  printf '# selftest\n' > "$proj/.backstop/ts-test-scope"
  git -C "$proj" add -- .backstop/ts-test-scope
  cat > "$proj/tests/out-of-scope.test.ts" <<'TS'
import { expect, it } from 'vitest'

it('an out-of-scope test failure still reds a scoped gate', () => {
  expect(1).toBe(2)
})
TS
  (cd "$proj" && "$backstop_bin" gate --file src/types-only.ts) > "$work/gate-scoped.txt" 2>&1
  status=$?
  gate_mode=$(jq -r '.backstopScope.mode // "missing"' "$proj/.backstop/ts-test-results.json" 2>/dev/null)
  gate_reason=$(jq -r '.backstopScope.reason // ""' "$proj/.backstop/ts-test-results.json" 2>/dev/null)
  # Which core is this? Decided independently of the run under test: a core that
  # knows scope_handoff rejects an unknown value in pack check, an older one
  # ignores the key. A manifest without the key must pass on both.
  probe="$work/handoff-probe"
  mkdir -p "$probe/ok" "$probe/bogus"
  for v in ok bogus; do
    line=""
    [ "$v" = bogus ] && line="    scope_handoff: bogus"
    cat > "$probe/$v/pack.yml" <<YML
name: acme/handoff-probe
version: 1.0.0
language: generic
archetype: enforcement
description: probe for scope_handoff support
engines:
  tool:
    command: true
    input_mode: none
    scope_kind: project-wide
    gate_type: findings
    exempt_from_scope_filter: true
$line
content:
  ruleset:
    version: 1.0.0
    rules:
      - id: marker
        engine: tool
        risk_class: correctness
YML
  done
  # pack check reports its verdict on its status line (it exits 0 either way).
  if "$backstop_bin" pack check "$probe/ok" 2>&1 | grep -qx 'status: pass' && "$backstop_bin" pack check "$probe/bogus" 2>&1 | grep -qx 'status: fail'; then
    core_supports_handoff=1
  else
    core_supports_handoff=0
  fi
  if [ "$core_supports_handoff" -eq 0 ]; then
    if [ "$gate_mode" = full ] && [ "$status" -ne 0 ] && grep -q 'an out-of-scope test failure still reds a scoped gate' "$work/gate-scoped.txt" && ! grep -q 'vitest-diff-scoped' "$work/gate-scoped.txt"; then
      pass "gate: on a core without scope_handoff, an opted-in gate runs the full suite and fails on the unreached test"
    else
      fail "gate: older-core opted-in gate exited $status in mode $gate_mode: $(grep -i 'vitest\|fail' "$work/gate-scoped.txt" | head -5 | tr '\n' ' ')"
    fi
  else
    case $gate_reason in
      *"handed over no gate scope"*)
        fail "gate: a core that supports scope_handoff handed over no gate scope ($gate_reason)"
        ;;
      *)
        if [ "$gate_mode" = scoped ] && [ "$status" -eq 0 ] && grep -q 'vitest-diff-scoped' "$work/gate-scoped.txt"; then
          pass "gate: an opted-in scoped gate skips an unreached test and reports the selection warning"
        else
          fail "gate: opted-in scoped gate exited $status in mode $gate_mode ($gate_reason): $(grep -i 'vitest\|fail' "$work/gate-scoped.txt" | head -5 | tr '\n' ' ')"
        fi
        ;;
    esac
  fi
  (cd "$proj" && "$backstop_bin" gate --all) > "$work/gate-all.txt" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -q 'an out-of-scope test failure still reds a scoped gate' "$work/gate-all.txt" && ! grep -q 'vitest-diff-scoped' "$work/gate-all.txt"; then
    pass "gate: --all still runs the full suite (no selection warning) and fails on the unreached test"
  else
    fail "gate: --all with selection opted in exited $status: $(grep -i 'vitest\|fail' "$work/gate-all.txt" | head -5 | tr '\n' ' ')"
  fi
  rm -f "$proj/tests/out-of-scope.test.ts"
  # A crash is never a pass: an unhandled error with every test passing, and a
  # vitest that dies before writing its report, both fail the opted-in gate —
  # for that reason, against a baseline where the same gate passes.
  (cd "$proj" && "$backstop_bin" gate --file src/used.ts) > "$work/gate-crash-baseline.txt" 2>&1
  status=$?
  if [ "$status" -eq 0 ]; then
    pass "gate: baseline — the opted-in gate over src/used.ts passes before any crash is planted"
  else
    fail "gate: baseline opted-in gate over src/used.ts exited $status: $(grep -i 'fail\|vitest\|crash' "$work/gate-crash-baseline.txt" | head -5 | tr '\n' ' ')"
  fi
  cat > "$proj/tests/used-unhandled.test.ts" <<'TS'
import { expect, it } from 'vitest'
import { overall } from '../src/used'

it('passes but leaves an unhandled error behind', async () => {
  expect(overall({ round: 1, slot: 1 }, 4)).toBe(1)
  setTimeout(() => {
    throw new Error('unhandled after the test passed')
  }, 0)
  await new Promise((resolve) => setTimeout(resolve, 20))
})
TS
  (cd "$proj" && "$backstop_bin" gate --file src/used.ts) > "$work/gate-unhandled.txt" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -q 'crashed: non-zero exit with no parseable findings' "$work/gate-unhandled.txt"; then
    pass "gate: a run that exits non-zero with every test passing fails the opted-in gate as a crash"
  else
    fail "gate: an unhandled vitest error passed the opted-in gate: $(grep -i 'vitest\|crash\|warning' "$work/gate-unhandled.txt" | head -5 | tr '\n' ' ')"
  fi
  rm -f "$proj/tests/used-unhandled.test.ts"
  printf 'export default {{{ not valid\n' > "$proj/vitest.config.ts"
  (cd "$proj" && "$backstop_bin" gate --file src/used.ts) > "$work/gate-crash.txt" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -q 'stdout_artifact' "$work/gate-crash.txt" && grep -q 'not produced' "$work/gate-crash.txt"; then
    pass "gate: a vitest that dies before writing its report fails the opted-in gate on the missing report"
  else
    fail "gate: a crashed vitest passed the opted-in gate: $(grep -i 'vitest\|artifact' "$work/gate-crash.txt" | head -5 | tr '\n' ' ')"
  fi
  rm -f "$proj/vitest.config.ts"
  cat > "$proj/tests/used-fails.test.ts" <<'TS'
import { expect, it } from 'vitest'
import { overall } from '../src/used'

it('a selected failing test still reds a scoped gate', () => {
  expect(overall({ round: 1, slot: 1 }, 4)).toBe(-1)
})
TS
  (cd "$proj" && "$backstop_bin" gate --file src/used.ts) > "$work/gate-selected.txt" 2>&1
  status=$?
  if [ "$status" -ne 0 ] && grep -q 'a selected failing test still reds a scoped gate' "$work/gate-selected.txt"; then
    pass "gate: a failing test the scope selects still fails an opted-in scoped gate"
  else
    fail "gate: selected failing test run exited $status: $(grep -i 'vitest\|fail' "$work/gate-selected.txt" | head -5 | tr '\n' ' ')"
  fi
  rm -f "$proj/tests/used-fails.test.ts" "$proj/.backstop/ts-test-scope"
  cp "$work/backstop-saved.yml" "$proj/backstop.yml"
fi

if [ "$failures" -eq 0 ]; then
  echo "selftest: all checks passed"
  exit 0
fi
echo "selftest: $failures check(s) failed" >&2
exit 1
