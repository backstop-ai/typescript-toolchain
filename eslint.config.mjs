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
//
// Plain JavaScript (.js/.jsx/.mjs/.cjs) is linted too, and for it `no-undef` stays
// ON (typescript-eslint only switches it off for TS extensions, where tsc owns
// undefined names). The blocks after the presets therefore declare the Node
// runtime's globals for plain JS, and give .cjs files their CommonJS module
// system. NODE_GLOBALS is an INLINE literal on purpose: importing the `globals`
// package would add a fifth required devDependency to the onboarding contract
// above (and under pnpm's strict layout it is not resolvable from the consumer
// root unless installed directly), turning a patch release into a breaking one.
import js from '@eslint/js'
import tseslint from 'typescript-eslint'

// Node.js runtime globals available to every plain-JS module (ESM or CommonJS).
// The CommonJS-only module-scope names (require, module, exports, __dirname,
// __filename) are NOT here: they exist only in .cjs scope, declared below.
const NODE_GLOBALS = {
  console: 'readonly',
  process: 'readonly',
  Buffer: 'readonly',
  global: 'readonly',
  globalThis: 'readonly',
  setTimeout: 'readonly',
  clearTimeout: 'readonly',
  setInterval: 'readonly',
  clearInterval: 'readonly',
  setImmediate: 'readonly',
  clearImmediate: 'readonly',
  queueMicrotask: 'readonly',
  structuredClone: 'readonly',
  URL: 'readonly',
  URLSearchParams: 'readonly',
  TextEncoder: 'readonly',
  TextDecoder: 'readonly',
  AbortController: 'readonly',
  AbortSignal: 'readonly',
  EventTarget: 'readonly',
  Event: 'readonly',
  fetch: 'readonly',
  Request: 'readonly',
  Response: 'readonly',
  Headers: 'readonly',
  FormData: 'readonly',
  Blob: 'readonly',
  atob: 'readonly',
  btoa: 'readonly',
  performance: 'readonly',
  crypto: 'readonly',
  WebAssembly: 'readonly',
}

// CommonJS module-scope bindings: in a .cjs file `require` IS the module system.
const COMMONJS_GLOBALS = {
  require: 'readonly',
  module: 'writable',
  exports: 'writable',
  __dirname: 'readonly',
  __filename: 'readonly',
}

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
  {
    // Plain JS runs on Node: declare its globals (tsc covers the TS extensions).
    files: ['**/*.js', '**/*.jsx', '**/*.mjs', '**/*.cjs'],
    languageOptions: { globals: NODE_GLOBALS },
  },
  {
    // CommonJS. typescript-eslint's base config sets `sourceType: 'module'` with no
    // `files` scope, overriding ESLint's own commonjs default for .cjs — restore it,
    // declare the CommonJS bindings, and turn off no-require-imports, which forbids
    // the very module system a .cjs file is written in.
    files: ['**/*.cjs'],
    languageOptions: { sourceType: 'commonjs', globals: COMMONJS_GLOBALS },
    rules: { '@typescript-eslint/no-require-imports': 'off' },
  },
)
