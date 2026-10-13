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
# What it proves (ISSUE-221 / ISSUE-222):
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
#   4. gate (optional): a types-only file plus a fixture .cjs pass the coverage
#      step, and an untested module fails it as a 0% gap, not as unmeasured.
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
for clean in tests/fixtures/standin/draft.cjs tests/fixtures/standin/checks/slot.cjs scripts/tool.mjs src/used.ts src/untested.ts src/types-only.ts tests/used.test.ts tests/helpers.ts; do
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

# --- 4. gate (optional) ---------------------------------------------------------------
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
fi

if [ "$failures" -eq 0 ]; then
  echo "selftest: all checks passed"
  exit 0
fi
echo "selftest: $failures check(s) failed" >&2
exit 1
