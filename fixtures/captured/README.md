# Captured fixtures — real vitest output, never fabricated

These files are **frozen captures of real tool output**, produced by running the
pack's actual engine commands against `_harness` (the pack's own consumer project).
They are the ground truth for what vitest actually emits — regression tests and any
future convert/producer changes must be built against these shapes, not invented
inputs. (Rule: a fixture fabricated to fit already-written code verifies nothing;
a captured fixture forces the code to fit reality.)

## What each file is

- `ts-test-results.json` — the Jest-compatible JSON report vitest writes via
  `--reporter=json --outputFile=…`. Input to `scripts/test-to-sarif.sh`.
  Note: `testResults[].name` are ABSOLUTE paths — that is what vitest really emits.
- `coverage-summary.json` — the raw v8 `json-summary` coverage report
  (`--coverage.reporter=json-summary`). Keys are ABSOLUTE file paths plus a `total`
  aggregate — the pre-relativization input `scripts/coverage-produce.sh` reads.
- `backstop-summary.json` — the producer's relativized output (absolute keys
  rewritten repo-relative). Input to `scripts/coverage-to-records.sh`.

Both artifacts come from ONE combined invocation — that fact is load-bearing: it is
the basis of the single-run convention (the ts-test command carries the coverage
flags; the coverage producer reuses the summary when fresh instead of re-running
the suite).

## Re-capture (regenerate from reality; do not hand-edit)

Run the `ts-test` engine `command:` exactly as `pack.yml` declares it (it carries
the coverage flags, including the `--coverage.include`/`--coverage.exclude` scope),
then the producer:

```sh
cd ../_harness
rm -rf .backstop/ts-coverage .backstop/ts-test-results.json
# <the ts-test command from pack.yml, verbatim>
sh ../typescript-toolchain/scripts/coverage-produce.sh
cp .backstop/ts-test-results.json \
   .backstop/ts-coverage/coverage-summary.json \
   .backstop/ts-coverage/backstop-summary.json \
   ../typescript-toolchain/fixtures/captured/
```

Captured 2026-07-18 (vitest 3.x, coverage-v8, `_harness` @ its then-current state),
when the command still passed `--coverage.all`. 1.3.2 replaced that flag with
explicit include/exclude globs (ISSUE-221); the output SHAPE these files pin is
unchanged. The behavior the new globs add (a total-0 entry for a types-only module,
a 0/N entry for an untested one) is proven live, on Vitest 3 and 5, by
`selftest/run.sh` rather than by a frozen capture.
