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
      ] } ]
    }
'
