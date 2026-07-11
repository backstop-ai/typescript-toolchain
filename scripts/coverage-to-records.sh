#!/bin/sh
# typescript-toolchain coverage convert script — the SANDBOXED parse-only half.
# Reads the PRODUCER's relativized coverage-summary JSON on stdin and emits
# per-FILE coverage-records JSON on stdout (NOT SARIF). It runs with no toolchain
# or project access: all knowledge it needs (repo-relative paths) was folded in by
# the producer. Shape in:
#   { "total": {...}, "<repo-rel path>": { "statements": {"total","covered",...}, ... } }
# Shape out (one record per source file, `total` aggregate dropped):
#   [ { "path", "covered", "total", "measured": true, "excluded": false,
#       "metric": "statement" } ]
# Statement coverage is the metric (v8/istanbul's statement granularity). A file
# with total:0 is the N/A cell — the gate's `Total==0 => N/A` guard handles it and
# it is never coerced to 0%. An empty summary ({} — no tests) yields []. Uses jq.
echo "typescript-toolchain coverage-to-records: aggregating per-file statement coverage" >&2

jq -c -s '
  (.[0] // {})
  | to_entries
  | map(select(.key != "total"))
  | map({
      path: .key,
      covered: (.value.statements.covered // 0),
      total: (.value.statements.total // 0),
      measured: true,
      excluded: false,
      metric: "statement"
    })
'
