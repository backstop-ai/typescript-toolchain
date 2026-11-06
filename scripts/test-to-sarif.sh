#!/bin/sh
# typescript-toolchain test convert script: reads Vitest's Jest-compatible JSON
# report (from the engine's stdout_artifact) on stdin and emits located SARIF on
# stdout. Shape:
#   { "testResults": [ { "name": "<abs test file>", "status": "failed|passed",
#       "assertionResults": [ { "title", "status", "failureMessages": [ ... ] } ],
#       "message": "<suite-level error, if the file failed to load>" } ] }
# Each FAILED assertion becomes one finding on its test file (Vitest's json
# reporter does not emit per-assertion line numbers by default, so findings are
# file-scoped — startLine 1). A file that FAILED with zero failed assertions
# (import/compile/collection error) yields one finding from its `message`. Passing
# suites and a no-tests run produce an empty, finding-free SARIF (GREEN). Uses jq.
#
# A report whose `backstopScope.mode` (written by scripts/test-produce.sh) is
# `scoped` or `none` also yields ONE warning finding saying the suite was narrowed
# to the diff, so a narrowed run never reads as a full-suite pass. Its message
# carries counts and the selection reason only, never a test title: the gate joins
# test findings to mandated tests by title, and a title here would read as a
# failure.
echo "typescript-toolchain test-to-sarif: normalizing vitest failures" >&2

jq -c -s '
  (.[0] // {}) as $report
  | {
      version: "2.1.0",
      runs: [ { results: [
        ($report.testResults // [])[]
        | select(.status == "failed")
        | .name as $file
        | (.assertionResults // [] | map(select(.status == "failed"))) as $failed
        | if ($failed | length) > 0
          then
            $failed[]
            | {
                ruleId: "vitest",
                level: "error",
                message: { text: (.title + ": " + ((.failureMessages // [""])[0] | split("\n")[0])) },
                locations: [ { physicalLocation: {
                  artifactLocation: { uri: $file },
                  region: { startLine: 1 }
                } } ]
              }
          else
            {
              ruleId: "vitest",
              level: "error",
              message: { text: ("test file failed: " + ((.message // "unknown error") | split("\n")[0])) },
              locations: [ { physicalLocation: {
                artifactLocation: { uri: $file },
                region: { startLine: 1 }
              } } ]
            }
          end
      ] + (
        ($report.backstopScope // {}) as $scope
        | if ($scope.mode == "scoped" or $scope.mode == "none")
          then [ {
            ruleId: "vitest-diff-scoped",
            level: "warning",
            message: { text: ("vitest ran " + (($scope.testFiles // 0) | tostring) + " test file(s) selected for this diff (" + $scope.mode + ": " + ($scope.reason // "") + "); tests outside the selection did not run. Run the gate with --all for the full suite.") },
            locations: [ { physicalLocation: {
              artifactLocation: { uri: "package.json" },
              region: { startLine: 1 }
            } } ]
          } ]
          else [] end
      ) } ]
    }
'
