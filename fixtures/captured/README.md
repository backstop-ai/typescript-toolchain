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

```sh
cd ../_harness
rm -rf .backstop/ts-coverage .backstop/ts-test-results.json
npx --no-install vitest run --passWithNoTests \
  --reporter=json --outputFile=.backstop/ts-test-results.json \
  --coverage --coverage.provider=v8 --coverage.reporter=json-summary \
  --coverage.reportsDirectory=.backstop/ts-coverage --coverage.all
sh ../typescript-toolchain/scripts/coverage-produce.sh
cp .backstop/ts-test-results.json \
   .backstop/ts-coverage/coverage-summary.json \
   .backstop/ts-coverage/backstop-summary.json \
   ../typescript-toolchain/fixtures/captured/
```

Captured 2026-07-18 (vitest 3.x, coverage-v8, `_harness` @ its then-current state).
