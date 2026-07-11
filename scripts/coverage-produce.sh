#!/bin/sh
# typescript-toolchain coverage PRODUCER — the UN-SANDBOXED half of the coverage
# engine (analogous to go-toolchain's coverage-produce.sh). The dispatch runs it
# via the runner (cwd = project root) with full toolchain access IN PLACE of the
# plain engine command. Its job:
#   1. run the Vitest v8 coverage pass, emitting json-summary; and
#   2. fold in the one piece of knowledge the sandboxed convert cannot obtain —
#      the project-root absolute prefix — by rewriting coverage-summary.json's
#      ABSOLUTE file keys to repo-relative paths.
# It writes the relativized summary to the declared stdout_artifact
# (.backstop/ts-coverage/backstop-summary.json); the sandboxed convert then parses
# THAT (it runs no tool). This producer/convert split keeps the executor
# language-blind AND the convert toolchain-free. POSIX sh.
#
# --coverage.all instruments every source file (even untested ones) so a file with
# NO tests surfaces as 0%-covered (a real coverage gap) instead of being silently
# absent. --passWithNoTests keeps a fresh/empty repo GREEN (exit 0, empty summary).

out_dir=.backstop/ts-coverage
summary="$out_dir/coverage-summary.json"
artifact="$out_dir/backstop-summary.json"
mkdir -p "$out_dir"

# Run the coverage pass. Tolerate a non-zero exit — a failing suite still yields a
# usable summary; the gate decides the verdict, never this producer.
npx --no-install vitest run \
  --passWithNoTests \
  --coverage \
  --coverage.provider=v8 \
  --coverage.reporter=json-summary \
  --coverage.reportsDirectory="$out_dir" \
  --coverage.all \
  >/dev/null 2>&1 || true

# No summary produced (no coverage tooling, or a hard crash): emit an empty object
# so the convert yields an empty records array rather than failing the run.
if [ ! -f "$summary" ]; then
  echo '{}' > "$artifact"
  exit 0
fi

# Rewrite absolute file keys to repo-relative by stripping the "$PWD/" prefix. The
# `total` aggregate key carries no prefix and passes through unchanged (the convert
# drops it). jq is present in the un-sandboxed producer environment.
jq --arg pfx "$PWD/" '
  to_entries
  | map(.key |= (if startswith($pfx) then .[($pfx | length):] else . end))
  | from_entries
' "$summary" > "$artifact"

exit 0
