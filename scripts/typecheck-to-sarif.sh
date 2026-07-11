#!/bin/sh
# typescript-toolchain typecheck convert script: reads raw `tsc --noEmit` stdout
# on stdin and emits located SARIF on stdout. tsc's default (non-pretty) diagnostic
# lines look like:
#   src/foo.ts(4,3): error TS2322: Type 'string' is not assignable to type 'number'.
# The file path (which may contain spaces) is everything before the "(line,col):"
# locator; the TS<code> becomes the SARIF ruleId. Lines without that locator
# (multi-line error continuations, global errors with no file) are ignored — a
# genuine tsc crash with zero located diagnostics is caught by the engine's
# CrashGuard, not silently greened. POSIX awk so it runs under macOS system awk in
# the sandbox. A converter banner on stderr exercises clean-stdout capture.
echo "typescript-toolchain typecheck-to-sarif: normalizing tsc diagnostics" >&2

awk '
  BEGIN { printf "{\"version\":\"2.1.0\",\"runs\":[{\"results\":["; sep="" }
  function esc(s) { gsub(/\\/, "\\\\", s); gsub(/"/, "\\\"", s); gsub(/\t/, "\\t", s); return s }
  {
    line = $0
    sub(/\r$/, "", line)
    # Require the distinctive "(<line>,<col>): error|warning TS<code>: " locator.
    if (match(line, /\([0-9]+,[0-9]+\): (error|warning) TS[0-9]+: /) == 0) next
    file = substr(line, 1, RSTART - 1)          # path before the "("
    rest = substr(line, RSTART + 1)             # "<line>,<col>): error TS...: msg"
    # line number
    match(rest, /^[0-9]+/); lno = substr(rest, 1, RLENGTH)
    rest = substr(rest, RLENGTH + 1)            # ",<col>): error ..."
    sub(/^,/, "", rest)
    # column number
    match(rest, /^[0-9]+/); col = substr(rest, 1, RLENGTH)
    rest = substr(rest, RLENGTH + 1)            # "): error TS...: msg"
    sub(/^\): /, "", rest)                       # "error TS...: msg"
    sev = "error"
    if (rest ~ /^warning /) sev = "warning"
    sub(/^(error|warning) /, "", rest)          # "TS2322: msg"
    match(rest, /^TS[0-9]+/); code = substr(rest, 1, RLENGTH)
    rest = substr(rest, RLENGTH + 1)            # ": msg"
    sub(/^: /, "", rest)
    msg = rest
    printf "%s{\"ruleId\":\"%s\",\"level\":\"%s\",\"message\":{\"text\":\"%s\"},\"locations\":[{\"physicalLocation\":{\"artifactLocation\":{\"uri\":\"%s\"},\"region\":{\"startLine\":%s,\"startColumn\":%s}}}]}", \
      sep, esc(code), sev, esc(msg), esc(file), lno, col
    sep=","
  }
  END { printf "]}]}\n" }
'
