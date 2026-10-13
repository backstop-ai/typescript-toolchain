#!/bin/sh
# typescript-toolchain coverage PRODUCER — the UN-SANDBOXED half of the coverage
# engine (analogous to go-toolchain's coverage-produce.sh). The dispatch runs it
# via the runner (cwd = project root) with full toolchain access IN PLACE of the
# plain engine command. Its job:
#   1. run the Vitest v8 coverage pass, emitting json-summary; and
#   2. fold in the knowledge the sandboxed convert cannot obtain — the
#      project-root absolute prefix (by rewriting coverage-summary.json's ABSOLUTE
#      file keys to repo-relative paths) and the consumer's justified coverage
#      exclusions (.backstop/coverage-exclusions; see below).
# It writes the relativized summary to the declared stdout_artifact
# (.backstop/ts-coverage/backstop-summary.json); the sandboxed convert then parses
# THAT (it runs no tool). This producer/convert split keeps the executor
# language-blind AND the convert toolchain-free. POSIX sh.
#
# COVERAGE SCOPE (ISSUE-221): the --coverage.include / --coverage.exclude globs below
# make v8 report every in-scope file, including files no test loads. Those globs —
# not --coverage.all, which Vitest 4 removed and its CLI silently ignores — are what
# keep an untested file from being silently ABSENT from the summary (absent means no
# record, which core reports as `coverage_unmeasured`). With include set:
#   - an untested runtime module gets a 0/N entry: a real 0% coverage gap; and
#   - a types-only module (no runtime statements; never loaded, since type-only
#     imports are erased) gets a total-0 entry, which core treats as N/A, not 0%.
# The include list mirrors pack.yml classification.source and the exclude list
# mirrors classification.test, plus the build-output/dependency/report directories
# eslint.config.mjs ignores. They must match the ts-test engine command in pack.yml
# (selftest/run.sh checks the agreement). --passWithNoTests keeps a fresh/empty repo
# GREEN (exit 0, empty summary).

out_dir=.backstop/ts-coverage
summary="$out_dir/coverage-summary.json"
artifact="$out_dir/backstop-summary.json"
test_results=.backstop/ts-test-results.json
mkdir -p "$out_dir"

# SINGLE-RUN CONVENTION (reuse-if-fresh): the ts-test engine's command carries the
# coverage flags, so the gate's test dim — which runs BEFORE this coverage dim in
# the sequential gate — already wrote $summary during THIS gate invocation. If the
# summary is FRESH (exists and is not older than the test report the same run
# wrote), skip the redundant second suite run and just relativize below. Anything
# else — a coverage-only invocation, a stale summary from an earlier run, a missing
# report, a future ordering change — falls back to running vitest exactly as
# before: the degraded path is slow-but-correct, never wrong. Stale reuse is
# structurally impossible: an old summary is OLDER than a fresh test report, so
# the check fails and we re-run.
fresh=0
if [ -f "$summary" ] && [ -f "$test_results" ] && [ ! "$summary" -ot "$test_results" ]; then
  fresh=1
fi

if [ "$fresh" -eq 0 ]; then
  # Run the coverage pass. Tolerate a non-zero exit — a failing suite still yields
  # a usable summary; the gate decides the verdict, never this producer.
  # --exclude '**/.backstop/**' keeps installed packs' own test files (this pack's
  # selftest/ among them) out of the consumer's suite — the same exclusion the
  # ts-test and ts-coverage engine commands in pack.yml carry (v1.2.1).
  npx --no-install vitest run \
    --exclude '**/.backstop/**' \
    --passWithNoTests \
    --coverage \
    --coverage.provider=v8 \
    --coverage.reporter=json-summary \
    --coverage.reportOnFailure \
    --coverage.reportsDirectory="$out_dir" \
    '--coverage.include=**/*.ts' \
    '--coverage.include=**/*.tsx' \
    '--coverage.include=**/*.mts' \
    '--coverage.include=**/*.cts' \
    '--coverage.include=**/*.js' \
    '--coverage.include=**/*.jsx' \
    '--coverage.include=**/*.mjs' \
    '--coverage.include=**/*.cjs' \
    '--coverage.exclude=**/*.test.ts' \
    '--coverage.exclude=**/*.test.tsx' \
    '--coverage.exclude=**/*.test.js' \
    '--coverage.exclude=**/*.test.jsx' \
    '--coverage.exclude=**/*.spec.ts' \
    '--coverage.exclude=**/*.spec.tsx' \
    '--coverage.exclude=**/*.spec.js' \
    '--coverage.exclude=**/*.spec.jsx' \
    '--coverage.exclude=**/__tests__/**' \
    '--coverage.exclude=**/tests/**' \
    '--coverage.exclude=**/fixtures/**' \
    '--coverage.exclude=**/__fixtures__/**' \
    '--coverage.exclude=**/*.config.ts' \
    '--coverage.exclude=**/*.config.mts' \
    '--coverage.exclude=**/*.config.cts' \
    '--coverage.exclude=**/*.config.js' \
    '--coverage.exclude=**/*.config.mjs' \
    '--coverage.exclude=**/*.config.cjs' \
    '--coverage.exclude=**/testing/**' \
    '--coverage.exclude=**/app/**/route.ts' \
    '--coverage.exclude=**/app/**/page.tsx' \
    '--coverage.exclude=**/app/**/layout.tsx' \
    '--coverage.exclude=**/testsupport/**' \
    '--coverage.exclude=**/acceptance/**' \
    '--coverage.exclude=**/e2e/**' \
    '--coverage.exclude=**/node_modules/**' \
    '--coverage.exclude=**/dist/**' \
    '--coverage.exclude=**/build/**' \
    '--coverage.exclude=**/out/**' \
    '--coverage.exclude=**/.next/**' \
    '--coverage.exclude=**/coverage/**' \
    '--coverage.exclude=**/.backstop/**' \
    >/dev/null 2>&1 || true
fi

# No summary produced (no coverage tooling, or a hard crash): emit an empty object
# so the convert yields an empty records array rather than failing the run.
if [ ! -f "$summary" ]; then
  echo '{}' > "$artifact"
  exit 0
fi

# Fold in the CONSUMER PROJECT's coverage exclusions (parity with go-toolchain's
# producer; same file, same format, same drop rules).
#
# THE DECLARATION IS THE PROJECT'S, NOT THE PACK'S. An exclusion says "this path
# cannot be measured HERE, for this reason" — a fact about one codebase, such as a
# Temporal workflow module that runs inside Temporal's isolated workflow bundle,
# where v8 coverage cannot see it. A list shipped in the pack would impose one
# consumer's exclusions on every consumer of this toolchain.
#
# WHY THE ARTIFACT IS THE CARRIER: the convert (coverage-to-records.sh) is parse-only
# and runs SANDBOXED, so it cannot read this file. The producer folds the accepted
# declarations into the artifact under the reserved key
# "#backstop-coverage-exclusions" (an array of {path, justification}); only a
# root-level source file with exactly that name could collide with it. The key is
# written only when at least one declaration is accepted, so a project without the
# file gets a byte-identical artifact. Both the single-run reuse path and the
# fallback run reach this point, so both carry the exclusions.
#
# FORMAT: <repo-relative-path><TAB><justification>. Blank lines and # comments are
# ignored. The file is TRACKED in the consumer repo on purpose — a gitignored
# declaration is invisible config that shapes the gate's verdict without appearing
# in review.
#
# A DECLARATION WITH NO JUSTIFICATION IS DROPPED, NOT HONOURED, AND NOT FATAL. That
# is the fail-closed choice: an unjustified exclusion never takes effect, so the
# path stays measured and the threshold still applies. Honouring it would let a bare
# path silently switch coverage off; exiting non-zero would turn one typo into an
# outage of the whole coverage dimension. The same applies to a malformed path
# (absolute, trailing "/", empty/"."/".." segment) and to control characters: none
# is allowed in the path, and only TAB/VT/FF/CR are allowed in the justification.
exclusions=".backstop/coverage-exclusions"
accepted="$out_dir/coverage-exclusions.accepted"
: > "$accepted"
if [ -f "$exclusions" ]; then
  awk '
    function has_forbidden(s, path_value,   i, c, code) {
      for (i = 1; i <= length(s); i++) {
        c = substr(s, i, 1)
        for (code = 1; code < 32; code++) {
          if (c != sprintf("%c", code)) continue
          if (!path_value && (code == 9 || code == 11 || code == 12 || code == 13)) break
          return 1
        }
      }
      return 0
    }
    function valid_path(path,   count, i, part) {
      if (path == "" || substr(path, 1, 1) == "/" || substr(path, length(path), 1) == "/" || has_forbidden(path, 1)) return 0
      count = split(path, parts, "/")
      for (i = 1; i <= count; i++) {
        part = parts[i]
        if (part == "" || part == "." || part == "..") return 0
      }
      return 1
    }
    function valid_reason(reason,   substantive) {
      if (reason == "" || has_forbidden(reason, 0)) return 0
      substantive = reason
      gsub(/ /, "", substantive)
      gsub(tab, "", substantive)
      gsub(cr, "", substantive)
      gsub(ff, "", substantive)
      gsub(vt, "", substantive)
      return substantive != ""
    }
    BEGIN { tab = sprintf("%c", 9); vt = sprintf("%c", 11); ff = sprintf("%c", 12); cr = sprintf("%c", 13) }
    $0 == "" || substr($0, 1, 1) == "#" { next }
    {
      delimiter = index($0, tab)
      path = delimiter ? substr($0, 1, delimiter - 1) : ""
      reason = delimiter ? substr($0, delimiter + 1) : ""
      if (!delimiter || !valid_path(path) || !valid_reason(reason)) {
        printf "backstop typescript-toolchain: dropping malformed coverage exclusion; the path stays measured\n" > "/dev/stderr"
        next
      }
      printf "%s\t%s\n", path, reason
    }
  ' "$exclusions" > "$accepted"
fi

# Rewrite absolute file keys to repo-relative by stripping the "$PWD/" prefix. The
# `total` aggregate key carries no prefix and passes through unchanged (the convert
# drops it). Then attach the accepted exclusions (one "<path><TAB><reason>" line
# each; the reason may itself hold a TAB, so only the FIRST tab splits). jq is
# present in the un-sandboxed producer environment.
jq --arg pfx "$PWD/" --rawfile accepted "$accepted" '
  (to_entries
   | map(.key |= (if startswith($pfx) then .[($pfx | length):] else . end))
   | from_entries)
  + ([$accepted | split("\n")[] | select(. != "")
      | split("\t") | {path: .[0], justification: (.[1:] | join("\t"))}]
     | if length > 0 then {"#backstop-coverage-exclusions": .} else {} end)
' "$summary" > "$artifact"
rm -f "$accepted"

exit 0
