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
| `ts-test` | `vitest run` | test | Jest-compatible JSON reporter; failed assertions → findings on their test file. Test failures are project-wide (a failing test in an unchanged file still REDs a diff-scoped gate). Opt-in diff-scoped selection: see below. |
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

## Coverage exclusions

Some files cannot be measured by the in-process v8 coverage at all. The first case
is a Temporal workflow module: Temporal bundles workflow code and runs it inside an
isolated workflow sandbox, where v8 coverage cannot see it, so it reports as a 0%
gap no matter how well it is tested. A project declares such files in a **tracked**
`.backstop/coverage-exclusions` file, the same file and format the go-toolchain pack
reads:

```text
# <repo-relative-path><TAB><justification>
src/workflows/order.ts	Runs inside the Temporal workflow bundle; v8 coverage cannot see it
```

- Each line is a repo-relative path, a TAB, and a justification. Blank lines and
  lines starting with `#` are ignored.
- A listed path's coverage record is marked `excluded: true` and carries the
  justification. The gate skips its threshold and, when the file is in scope, shows
  a `coverage_exclusion` **warning** with that reason. A listed path with no
  coverage entry at all gets a synthetic excluded record (`total: 0`,
  `measured: false`), so the exclusion still applies. This happens only for this
  pack's source extensions (`.ts`, `.tsx`, `.mts`, `.cts`, `.js`, `.jsx`, `.mjs`,
  `.cjs`). Other listed paths, such as `.go` files for the go-toolchain pack that
  reads the same file, are skipped silently, so the two packs never emit
  duplicate records.
- A line **without a justification is dropped, not honoured**. The path stays
  measured and the threshold still applies, and the producer prints a notice on
  stderr. The same happens to a malformed path (absolute, trailing `/`, or an empty,
  `.` or `..` segment) and to any control character in the path or in the
  justification (TAB, VT, FF and CR are allowed in the justification). A bad line
  never fails the run.
- If a path is listed twice, the record keeps its first position and the last
  justification.
- Unlisted paths are unchanged.

The list belongs to the project, not the pack: the pack ships no exclusions. Keep
the file tracked so every exclusion shows up in review.

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
helpers and fixtures none. It also checks coverage exclusions: a justified line
excludes its path with the reason, and a line with no justification or with a
control character leaves the path measured. With a `backstop` binary (and `pnpm`
on `PATH`) it also gates the throwaway consumer end to end. Run it once per Vitest generation you
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

## Diff-scoped tests (opt-in)

By default `ts-test` runs the whole suite in every gate. A consumer whose suite is
slow can opt in to running only the tests a diff can affect, by **tracking** a
`.backstop/ts-test-scope` file in git (an empty file is enough; an untracked one
does not count). `backstop gate --all` always runs the whole suite, so run it at
milestones.

The engine is `scope_kind: project-wide` with `scope_handoff: file` and a producer,
`scripts/test-produce.sh`. Its command line never carries scope paths. Core hands
the gate scope over in the environment: `BACKSTOP_SCOPE_MODE` (`diff`, `file` or
`all`) and, for `diff` and `file`, `BACKSTOP_SCOPE_FILE`, a file of
project-root-relative paths that includes deleted paths, both sides of a rename,
and `testdata` paths. A Backstop core that does not know `scope_handoff` sets
neither variable, and the run is the full suite, so this pack version is safe on
an older core: it only narrows on a core that hands the scope over. `scripts/test-select.mjs` (which
runs no test, only a read-only `git ls-files` check that the scope file is
tracked) decides:

- **full**: the whole suite, as before. This happens when the scope file is
  missing or untracked, when core hands over no scope or the whole project
  (`gate --all`), when the scope file is malformed, when the selection would be
  too large for one `vitest related` command line, and whenever a scope path is
  something the import graph cannot account for: `package.json`, a lockfile,
  `pnpm-workspace.yaml`, `.npmrc`, `tsconfig*.json`, `jsconfig*.json`, a
  `vitest`/`vite` config, anything under `__mocks__/`, the scope file itself, a
  directory, any path that does not exist (a deleted or renamed module or fixture;
  only a deleted `*.test.*`/`*.spec.*` file is exempt), or any other non-source
  file that is not declared below.
- **scoped**: `vitest related --run` over the changed source and test files, plus
  the declared `always` and `map` tests. `vitest related` follows static imports
  only.
- **none**: the scope is empty, or every scope path is ignored or a deleted test
  file: nothing runs.

A scoped or none run adds one **warning** finding (`vitest-diff-scoped`) that says
how many test files ran, so a narrowed run never reads as a full-suite pass.

```text
# <directive><TAB><glob>[<TAB><test-glob>]
always	tests/architecture*.test.ts
ignore	docs/**
full	compose.yml
map	db/**/*.sql	tests/db*.test.ts
```

- `always`: tests that run in every scoped run. Use it for tests that read source
  files as text (architecture and scan tests): the import graph cannot see that
  dependency.
- `ignore`: paths that can never change a test result. It cannot hide the
  built-in full triggers above.
- `full`: paths that force the whole suite.
- `map`: when a changed path matches the first glob, run the tests matching the
  second. Use it for SQL, JSON and other files that tests read, `testdata`
  included.
- `**` matches across directories; `*` and `?` stay within one path segment. A glob
  that matches no file, or an unknown directive, makes the run full.
- `always` and `map` test globs never match files under `node_modules/` or a hidden
  directory (such as `.backstop/`): those are never collected as tests. A changed
  path under the project's own top-level `node_modules/` is ignored by selection.

**What a scoped run does not cover.** A failing test that the diff does not reach
is not run, so it does not fail that gate; `gate --all` still catches it. The
selection cannot see dependencies outside the static import graph: files read at
runtime, scripts run in a child process, computed `import()` paths, environment
variables and services. The non-source cases fall back to full unless declared,
but a changed **source** file that tests reach only that way (for example a
`.cjs` script a test runs in a child process, or a vitest `globalSetup` module)
selects nothing on its own. Declare those with `full` or `map`. A newly added
module that changes how an existing import resolves (for example a new
`index.ts` beside an existing file of the same name) is not detected.
