#!/bin/sh
# typescript-toolchain coverage convert script — the SANDBOXED parse-only half.
# Reads the PRODUCER's relativized coverage-summary JSON on stdin and emits
# per-FILE coverage-records JSON on stdout (NOT SARIF). It runs with no toolchain
# or project access: all knowledge it needs (repo-relative paths, the consumer's
# justified coverage exclusions) was folded in by the producer. Shape in:
#   { "total": {...}, "<repo-rel path>": { "statements": {"total","covered",...}, ... },
#     "#backstop-coverage-exclusions": [ {"path", "justification"}, ... ] }   (optional)
# Shape out (one record per source file, `total` aggregate dropped):
#   [ { "path", "covered", "total", "measured": true, "excluded": false,
#       "metric": "statement" } ]
# Statement coverage is the metric (v8/istanbul's statement granularity). A file
# with total:0 is the N/A cell — the gate's `Total==0 => N/A` guard handles it and
# it is never coerced to 0%. An empty summary ({} — no tests) yields []. Uses jq.
#
# COVERAGE EXCLUSIONS (parity with go-toolchain). A summary file whose path has an
# accepted declaration keeps its position and counts but is stamped
# `"excluded": true` with the declaration's text as `"justification"`; the gate then
# skips its threshold and, for a changed file, surfaces a `coverage_exclusion`
# warning carrying that reason. A declared path with NO summary entry gets one
# synthetic record (`covered: 0, total: 0, measured: false, excluded: true`),
# appended in first-declaration order, so a justified exclusion is never dropped for
# want of an inventory entry — but ONLY when the path has one of this pack's source
# extensions (classification.source: .ts/.tsx/.mts/.cts/.js/.jsx/.mjs/.cjs). The
# exclusions file is shared with other toolchain packs (go-toolchain reads the same
# one), so a declared .go path is that pack's to answer for; synthesizing a record
# for it here would collide with go-toolchain's own record for the same (path,
# metric) as `coverage_metric_collision`. Such a path is skipped silently. A path declared twice keeps its first position and its
# LAST justification. Each declaration is re-validated here with the producer's
# rules (path: non-empty, relative, no trailing "/", no empty/"."/".." segment, no
# control character; justification: non-blank, no control character other than
# TAB/VT/FF/CR) — an invalid one is ignored and the path stays measured. Paths
# without a declaration are unchanged.
echo "typescript-toolchain coverage-to-records: aggregating per-file statement coverage" >&2

jq -c -s '
  def bad_path_char: explode | any(. < 32);
  def bad_reason_char: explode | any(. < 32 and . != 9 and . != 11 and . != 12 and . != 13);
  def valid_path:
    type == "string" and . != "" and (startswith("/") | not) and (endswith("/") | not)
    and (bad_path_char | not)
    and (split("/") | all(. != "" and . != "." and . != ".."));
  # Mirrors classification.source in pack.yml (keep in step).
  def own_source: test("\\.(ts|tsx|mts|cts|js|jsx|mjs|cjs)$");
  def valid_reason:
    type == "string" and . != "" and (bad_reason_char | not)
    and (explode | any(. != 32 and . != 9 and . != 11 and . != 12 and . != 13));

  (.[0] // {}) as $summary
  | ($summary["#backstop-coverage-exclusions"] // []) as $declared
  | (if ($declared | type) == "array" then $declared else [] end
     | map(select(type == "object" and (.path | valid_path) and (.justification | valid_reason)))
     | reduce .[] as $d ({order: [], why: {}};
         (if (.why | has($d.path)) then . else .order += [$d.path] end)
         | .why[$d.path] = $d.justification)) as $excl
  | ($summary | to_entries
     | map(select(.key != "total" and .key != "#backstop-coverage-exclusions"))) as $entries
  | ($entries | map({key: .key, value: true}) | from_entries) as $represented
  | [ $entries[]
      | .key as $path
      | {
          path: $path,
          covered: (.value.statements.covered // 0),
          total: (.value.statements.total // 0),
          measured: true
        }
      + (if ($excl.why | has($path))
         then {excluded: true, metric: "statement", justification: $excl.why[$path]}
         else {excluded: false, metric: "statement"} end)
    ]
  + [ $excl.order[] as $path
      | select((($represented | has($path)) | not) and ($path | own_source))
      | {path: $path, covered: 0, total: 0, measured: false, excluded: true,
         metric: "statement", justification: $excl.why[$path]}
    ]
'
