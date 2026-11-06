#!/bin/sh
# typescript-toolchain test PRODUCER — the un-sandboxed half of the ts-test engine.
# The ts-test engine is `scope_kind: project-wide` with `scope_handoff: file`, so
# core runs this script IN PLACE of `npx` with the declared command's own
# arguments, and hands the gate scope over in the environment:
#
#   BACKSTOP_SCOPE_MODE  diff, file or all (unset: an older core, or no gate scope)
#   BACKSTOP_SCOPE_FILE  for diff and file: NUL-terminated, project-root-relative
#                        scope paths, unfiltered
#
# scripts/test-select.mjs (it runs no test) turns that into one of three
# decisions, and this script carries it out:
#
#   full    run the declared command unchanged: the whole suite, as before. This is
#           the decision whenever the consumer has not opted in by tracking a
#           .backstop/ts-test-scope file, whenever core handed over no scope (an
#           older core) or the whole project (`gate --all`), and whenever a scope
#           path is something the import graph cannot account for (see
#           test-select.mjs).
#   scoped  run `vitest related --run <declared --flags...> <paths...>`: the
#           changed test files, the tests that statically import a changed
#           source file, and the consumer's `always` / `map` tests.
#   none    nothing in scope can change a test result: write an empty report
#           (and an empty coverage summary, so the coverage engine reuses it
#           instead of running the whole suite) and run nothing.
#
# The decision is recorded in the report as `backstopScope`, and
# scripts/test-to-sarif.sh turns a scoped or none decision into a WARNING finding,
# so a narrowed run never reads as a full-suite pass. POSIX sh; needs node and jq.

pack_dir=$(cd "$(dirname "$0")/.." && pwd)
results=.backstop/ts-test-results.json
out_dir=.backstop/ts-coverage
summary="$out_dir/coverage-summary.json"

# Every argument is the declared command's (a project-wide engine gets no scope
# paths on its command line). Declared tokens hold no whitespace (core splits the
# command on it), so a plain string carries them safely.
declared=
for arg in "$@"; do
  declared="$declared $arg"
done
case " $declared " in
  *" run "*) ;;
  *)
    echo "typescript-toolchain test-produce: the declared command must contain 'run'; refusing to guess" >&2
    exit 2
    ;;
esac

decision_file=$(mktemp)
trap 'rm -f "$decision_file"' EXIT INT TERM
if ! node "$pack_dir/scripts/test-select.mjs" "$PWD" "${BACKSTOP_SCOPE_MODE:-}" "${BACKSTOP_SCOPE_FILE:-}" > "$decision_file"; then
  echo "typescript-toolchain test-produce: selection failed; running the full suite" >&2
  printf 'full\tselection failed\n' > "$decision_file"
fi
mode=$(head -n 1 "$decision_file" | cut -f 1)
reason=$(head -n 1 "$decision_file" | cut -f 2-)
echo "typescript-toolchain test-produce: $mode ($reason)" >&2
# The scope is the selector's alone; vitest and anything it spawns never see it.
unset BACKSTOP_SCOPE_MODE BACKSTOP_SCOPE_FILE

# Any report or coverage summary present after this point was written by THIS
# run: a run that dies before writing its report leaves none, and core then fails
# loud on the missing stdout_artifact instead of reading the previous run's
# results. The touch below keeps the coverage engine's reuse-if-fresh check honest.
mkdir -p "$out_dir" .backstop
rm -f "$summary" "$results"

status=0
set -f
case $mode in
  scoped)
    scoped_declared=$(echo "$declared" | sed 's/ run / related --run /')
    set --
    while IFS= read -r path; do
      # ./ keeps a path that starts with `-` from reading as a vitest flag.
      [ -n "$path" ] && set -- "$@" "./$path"
    done <<EOF
$(tail -n +2 "$decision_file")
EOF
    # shellcheck disable=SC2086 # declared tokens are split on whitespace on purpose.
    npx $scoped_declared "$@"
    status=$?
    ;;
  none)
    echo '{"numTotalTestSuites":0,"numTotalTests":0,"success":true,"testResults":[]}' > "$results"
    echo '{}' > "$summary"
    ;;
  *)
    mode=full
    # shellcheck disable=SC2086
    npx $declared
    status=$?
    ;;
esac
set +f

# A narrowed run's warning finding must never stand in for a crash. CrashGuard
# reads "non-zero exit with no parseable findings" as a crash; if a scoped or
# none run exited non-zero (an unhandled error, a worker crash) while every test
# in its report passed, the warning would be the only finding and the gate would
# pass. So annotate only a clean exit, or a report that already holds a failure.
annotate=1
if [ "$mode" != full ] && [ "$status" -ne 0 ]; then
  failed=$(jq '[(.testResults // [])[] | select(.status == "failed")] | length' "$results" 2>/dev/null || echo 0)
  if [ "${failed:-0}" -eq 0 ]; then
    annotate=0
    echo "typescript-toolchain test-produce: vitest exited $status with no failed test in its report; leaving it unannotated so the crash is reported" >&2
  fi
fi

if [ -f "$results" ] && [ "$annotate" -eq 1 ]; then
  selected=$(jq '(.testResults // []) | length' "$results" 2>/dev/null || echo 0)
  if jq --arg mode "$mode" --arg reason "$reason" --argjson selected "${selected:-0}" \
    '. + {backstopScope: {mode: $mode, reason: $reason, testFiles: $selected}}' "$results" > "$results.tmp"; then
    mv "$results.tmp" "$results"
  else
    rm -f "$results.tmp"
  fi
  # Annotating rewrote the report, so it is now newer than the summary the same run
  # wrote; restore the order the coverage engine's freshness check relies on.
  [ -f "$summary" ] && touch "$summary"
fi
exit "$status"
