#!/bin/sh
# typescript-toolchain dependency-audit convert script: reads `pnpm audit --json`
# stdout on stdin and emits SARIF on stdout. pnpm's audit JSON uses the "advisories"
# shape:
#   { "advisories": { "<id>": { "module_name", "severity", "title", "url",
#                               "vulnerable_versions" } }, "metadata": {...} }
# Each advisory becomes one finding located on package.json (the manifest that
# pulls the vulnerable dependency). critical/high map to SARIF error; moderate/low
# to warning — so a policy blocking on errors gates the serious ones while surfacing
# the rest. An empty/clean audit ({advisories:{}}) yields a finding-free SARIF
# (GREEN). Uses jq (`-s` slurps the inherited stdin pipe, defaulting to {} when
# empty — the sandbox read-allowlist excludes /dev/stdin).
echo "typescript-toolchain audit-to-sarif: normalizing pnpm audit advisories" >&2

jq -c -s '
  (.[0] // {}) as $r
  | {
      version: "2.1.0",
      runs: [ { results: [
        ($r.advisories // {}) | to_entries[] | .value as $a
        | {
            ruleId: ("pnpm-audit/" + ($a.severity // "unknown")),
            level: (if (($a.severity // "") == "critical" or ($a.severity // "") == "high")
                    then "error" else "warning" end),
            message: { text: (
                ($a.module_name // "dependency")
                + " (" + ($a.vulnerable_versions // "*") + "): "
                + ($a.severity // "vulnerability") + " — "
                + ($a.title // "known vulnerability")
                + (if ($a.url // "") != "" then " (" + $a.url + ")" else "" end)
            ) },
            locations: [ { physicalLocation: {
              artifactLocation: { uri: "package.json" },
              region: { startLine: 1 }
            } } ]
          }
      ] } ]
    }
'
