#!/bin/sh
# typescript-toolchain lint convert script: reads raw `eslint --format json`
# stdout on stdin and emits located SARIF on stdout. eslint's JSON is an array of
# per-file objects, each with a `messages` array of findings. severity 2 = error,
# 1 = warning. filePath is absolute; the gate rel-ifies it (NormalizePath).
# A converter banner on stderr exercises the clean-stdout capture; it never
# reaches the SARIF bytes. Uses jq (a supported sandboxed convert interpreter).
echo "typescript-toolchain lint-to-sarif: normalizing eslint findings" >&2

# `eslint --format json` always prints a JSON array (possibly empty). `-s` (slurp)
# reads the inherited stdin pipe directly (NOT via a /dev/stdin path — the sandbox
# read-allowlist excludes /dev) into an array of the docs on stdin; `.[0] // []`
# defaults to an empty array when stdin is empty, so jq still emits a finding-free
# SARIF document rather than erroring.
jq -c -s '
  (.[0] // []) as $files
  | {
      version: "2.1.0",
      runs: [ { results: [
        $files[]
        | .filePath as $uri
        | .messages[]
        | {
            ruleId: (.ruleId // "eslint"),
            level: (if .severity == 2 then "error" else "warning" end),
            message: { text: (.message // "eslint finding") },
            locations: [ {
              physicalLocation: {
                artifactLocation: { uri: $uri },
                region: {
                  startLine: (.line // 1),
                  startColumn: (.column // 1)
                }
              }
            } ]
          }
      ] } ]
    }
'
