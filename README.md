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
| `ts-audit` | `pnpm audit --json` | findings | Known-vuln dependencies → findings on `package.json` (critical/high = error). **pnpm-specific** — bun/npm variants swap this engine. |

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

**pnpm note:** pnpm 10+ blocks dependencies' build scripts by default, which breaks
Vitest (esbuild). Allow it in `pnpm-workspace.yaml` (NOT `package.json` — pnpm 11
no longer reads `pnpm.onlyBuiltDependencies` there):

```yaml
onlyBuiltDependencies:
  - esbuild
```

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

## File classification

`classification.source` is every TS/JS extension. `classification.test` marks what
is **not measurable application source**: test-named files (`*.test.*`,
`*.spec.*`), `__tests__/`, `tests/`, `fixtures/`, `__fixtures__/`, build/tool
config (`*.config.*`), test-support and gated-tier directories (`testing/`,
`testsupport/`, `acceptance/`, `e2e/`) and the Next.js `route.ts` / `page.tsx` /
`layout.tsx` entrypoints. A helper under `tests/` or a fixture script under
`fixtures/` (for example a `.cjs` a test runs in a child process) therefore needs
no coverage record. Classifying them as `test` does not make them hollow tests:
test-name discovery only reads `it()`/`test()`/`describe()` names, and the
substantiveness pack's hollow-test rule matches `it()`/`test()` calls wherever they
are.

## Coverage scope

The coverage run passes `--coverage.include` globs equal to `classification.source`
and `--coverage.exclude` globs covering `classification.test` (plus `node_modules`,
`dist`, `build`, `out`, `.next`, `coverage` and `.backstop`). v8 then reports every
in-scope file, including files no test loads:

- an **untested** module gets a `0/N` record, a real 0% gap below the floor;
- a **types-only** module (no runtime statements, and never loaded because
  type-only imports are erased) gets a `total: 0` record, which the gate treats as
  N/A rather than 0%.

Without these globs, Vitest 4+ reports only the modules tests actually load (it
removed `--coverage.all`, which earlier pack versions relied on), so such files had
no record at all and failed as `coverage_unmeasured`. The globs work the same on
Vitest 3.

## Linting plain JavaScript

The shipped ESLint config declares Node's runtime globals (`console`, `process`,
`Buffer`, timers, `URL`, `fetch`, `structuredClone`, …) for `.js`/`.jsx`/`.mjs`/
`.cjs`, as an inline list so the onboarding contract above stays unchanged. `.cjs`
files are linted as CommonJS: `require`, `module`, `exports`, `__dirname` and
`__filename` are defined and `@typescript-eslint/no-require-imports` is off there.
Real undefined names still fail `no-undef`, and `require()` outside `.cjs` still
fails `no-require-imports`.

## Self-test

`backstop pack test` cannot run this pack's engines: they resolve ESLint and Vitest
from a consumer's `node_modules`, which a pack checkout does not have. Instead,
`selftest/run.sh` builds a throwaway consumer from `selftest/project/`, links a
`node_modules` you supply, and runs the engines exactly as `pack.yml` declares
them:

```sh
sh selftest/run.sh <dir-containing-node_modules> [path/to/backstop]
```

It checks that the coverage globs match `classification`, that fixture `.cjs`
files and Node ESM scripts lint clean (and that real mistakes still fail), and that
a types-only module yields a `total: 0` record, an untested one `0/N`, and test
helpers and fixtures none. With a `backstop` binary (and `pnpm` on `PATH`) it also
gates the throwaway consumer end to end. Run it once per Vitest generation you
support.

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
