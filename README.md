# backstop/typescript-toolchain

Reusable **TypeScript/JavaScript native-toolchain** enforcement pack for
[backstop](https://github.com/backstop-ai). It routes the ESLint / `tsc` / Vitest
passes through backstop's engine-dispatch substrate and normalizes their output to
SARIF (findings) and coverage-records — so `backstop gate` goes **RED on real lint,
type, and test failures**, entirely from pack data. Backstop bakes in zero
TypeScript knowledge; this pack is the whole TS toolchain.

## Engines

| Engine | Tool | Gate type | Notes |
|---|---|---|---|
| `ts-lint` | `eslint --format json` | lint | Pack-shipped opinionated flat config (`eslint.config.mjs`), authoritative via `--no-config-lookup`. |
| `ts-typecheck` | `tsc --noEmit` | build | Reads the consumer's `tsconfig.json`. Type errors are project-wide (an unchanged-file break still REDs). |
| `ts-test` | `vitest run` | test | Jest-compatible JSON reporter; failed assertions → findings on their test file. |
| `ts-coverage` | `vitest run --coverage` (v8) | coverage | Per-file statement coverage → coverage records. |

Every tool is invoked via `npx --no-install`, so it resolves the consumer repo's
own `node_modules/.bin` — the pack is package-manager-agnostic for lint/typecheck
(npm, pnpm, yarn, bun). The test/coverage engines assume Vitest.

## Onboarding (what the consumer repo must provide)

Install these as devDependencies:

```
eslint  @eslint/js  typescript-eslint  typescript  vitest  @vitest/coverage-v8
```

The pack ships the ESLint **rules**; the consumer supplies the ESLint **packages**
(they resolve from the consumer's `node_modules` because the pack config is loaded
from inside the consumer repo at `.backstop/packs/…`). The consumer must also have
a `tsconfig.json` (structural — cannot be pack-owned).

Install and gate:

```sh
backstop pack add backstop/typescript-toolchain   # (or a local path while developing)
backstop gate
```

### Minimal moment-zero `backstop.yml`

A pack-only consumer (no backstop SDLC artifacts) turns the artifact dimensions
OFF and keeps `pack_engines` blocking:

```yaml
project: my-app
packs:
    backstop/typescript-toolchain: local
enforcement:
    policy:
        pack_engines:
            applies-to: new-code
            level: block
        test_verification: { level: off }
        coverage_threshold: { level: off }
        contract_signature: { level: off }
        test_substantiveness: { level: off }
        artifact_status_drift: { level: off }
```

And `.gitignore`:

```
node_modules/
coverage/
.backstop/packs/
.backstop/baseline.json
.backstop/ts-coverage/
.backstop/ts-test-results.json
```

## Known limitations (v1)

- **Coverage enforcement is produced but not yet threshold-gated for pack-only
  consumers.** The `ts-coverage` engine emits per-file records, but the
  `coverage_threshold` dimension currently sources its thresholds from backstop
  SDLC specs — there is no simple global "fail under N%" knob yet.
- **Empty repo + `tsc`:** a repo with a `tsconfig.json` whose `include` matches no
  files makes `tsc` emit `TS18003 (No inputs found)` and CrashGuard REDs. Ship at
  least one source file (or a tolerant tsconfig) at moment zero.
- Vitest's JSON reporter does not emit per-assertion line numbers by default, so
  test findings are file-scoped (startLine 1).
