// backstop/typescript-toolchain — pack-owned opinionated ESLint flat config.
//
// This ships WITH the pack and is passed to eslint via `--config <abs path>`
// (with --no-config-lookup, so it is authoritative — the consumer's own config
// is ignored). It provides the RULES; the consumer repo provides the PACKAGES:
// `@eslint/js` and `typescript-eslint` are resolved from the consumer's
// node_modules because Node walks up the directory tree from this file's on-disk
// location, which sits inside the consumer repo at
// .backstop/packs/backstop/typescript-toolchain/eslint.config.mjs.
//
// Onboarding requirement (a `backstop init` input): the consumer must install
//   eslint  @eslint/js  typescript-eslint  typescript
// as devDependencies. The pack does NOT vendor them.
//
// v1 uses the type-AGNOSTIC recommended presets (no project-service wiring) so
// it is robust at moment zero without needing the consumer's tsconfig plumbed
// into ESLint. Type-aware linting and deeper security/correctness rules are the
// job of the backstop/typescript-standards (semgrep) pack.
import js from '@eslint/js'
import tseslint from 'typescript-eslint'

export default tseslint.config(
  {
    // Never lint build output, dependencies, coverage reports, or the installed
    // backstop packs themselves (which include this very config file).
    ignores: [
      '**/node_modules/**',
      '**/dist/**',
      '**/build/**',
      '**/out/**',
      // Next.js build output (gitignored, regenerated every `next build`) — never
      // lint it, exactly like dist/build/out. tsconfig still typechecks the
      // generated `.next/types/**` route validators; eslint must not lint the
      // minified chunks / generated files.
      '**/.next/**',
      '**/coverage/**',
      '**/.backstop/**',
    ],
  },
  js.configs.recommended,
  ...tseslint.configs.recommended,
)
