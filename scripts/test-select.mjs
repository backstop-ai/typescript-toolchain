// typescript-toolchain test SELECTION — the decision half of the ts-test producer
// (scripts/test-produce.sh). It runs no test and no build tool, only one read-only
// git query (is the opt-in file tracked?). Given the gate scope core handed over,
// it decides whether the run is FULL (the whole suite, exactly as before), SCOPED
// (only the tests the scope can reach, handed to `vitest related`) or NONE
// (nothing in scope can change a test result).
//
// Usage: node test-select.mjs <project-root> <scope-mode> [<scope-file>]
//   <scope-mode> is core's BACKSTOP_SCOPE_MODE (empty when core set none);
//   <scope-file> is core's BACKSTOP_SCOPE_FILE: NUL-terminated scope paths,
//   relative to the project root, unfiltered (deleted and testdata paths included,
//   both sides of a rename).
// Output (stdout): line 1 is "<full|scoped|none><TAB><reason>"; for "scoped", each
// further line is one repo-relative path to hand to `vitest related`.
//
// WHY A DECISION CAN ONLY EVER WIDEN. `vitest related` follows the static import
// graph. Anything it cannot see — a test that reads a source file as text, a SQL
// or JSON fixture, a config file, a script a test runs in a child process, a
// deleted or renamed module, a __mocks__ file — is invisible to it, and an
// invisible dependency is a test that silently does not run. So every path the
// graph cannot account for falls back to FULL unless the consumer has declared
// what it affects. A bad declaration widens too: a malformed config line makes the
// run FULL, never narrower.
//
// Selection is OPT-IN: it happens only when .backstop/ts-test-scope is TRACKED by
// git (even an empty file). Its declarations use the same line format as
// .backstop/coverage-exclusions:
//
//   # <directive><TAB><glob>[<TAB><test-glob>]
//   always	tests/architecture*.test.ts   run these in every scoped run
//   ignore	docs/**                       a change here can never affect a test
//   full	compose.yml                   a change here runs the whole suite
//   map	db/**/*.sql	tests/db*.test.ts   a change here runs the matching tests
//
// Globs are matched against the whole repo-relative path: `**` matches across
// directories, `*` and `?` stay within one path segment.
//
// Precedence for each scope path: built-in full triggers, then `ignore`, then
// `full`, then `map` (a mapped path is covered by its mapping), then the file's
// own kind: a source/test file goes to `vitest related`, and anything else is
// outside the import graph and makes the run FULL.

import { execFileSync } from 'node:child_process';
import { existsSync, readdirSync, readFileSync, realpathSync, statSync } from 'node:fs';
import { join, posix } from 'node:path';
import { pathToFileURL } from 'node:url';

const CONFIG = '.backstop/ts-test-scope';

// The `vitest related` command line carries the selection as arguments. Past this
// many paths, or bytes, the run is FULL rather than risk the argument limit.
const MAX_SELECTED_PATHS = 2000;
const MAX_SELECTED_BYTES = 256 * 1024;

// Files whose change can alter how EVERY test resolves or runs. These cannot be
// overridden by `ignore`: the import graph itself is built from them. A __mocks__
// module replaces an import with no static edge from the test to the mock.
const BUILTIN_FULL = [
  '**/package.json',
  '**/package-lock.json',
  '**/npm-shrinkwrap.json',
  '**/pnpm-lock.yaml',
  '**/pnpm-workspace.yaml',
  '**/yarn.lock',
  '**/bun.lock',
  '**/bun.lockb',
  '**/.npmrc',
  '**/tsconfig*.json',
  '**/jsconfig*.json',
  '**/vitest.config.*',
  '**/vitest.workspace.*',
  '**/vite.config.*',
  '**/__mocks__/**',
  CONFIG,
];

// Mirrors classification.source in pack.yml (selftest/run.sh checks the agreement).
const SOURCE_EXTENSIONS = ['.ts', '.tsx', '.mts', '.cts', '.js', '.jsx', '.mjs', '.cjs'];

// A test FILE, by its name suffix only. Nothing imports a test file, so deleting
// one strands no other test. A helper in a __tests__ directory is NOT a test file.
const TEST_FILE = /\.(test|spec)\.[cm]?[jt]sx?$/;

export function globToRegExp(glob) {
  let out = '';
  for (let i = 0; i < glob.length; i++) {
    const c = glob[i];
    if (c === '*') {
      if (glob[i + 1] === '*') {
        i++;
        if (glob[i + 1] === '/') {
          i++;
          out += '(?:.*/)?';
        } else {
          out += '.*';
        }
      } else {
        out += '[^/]*';
      }
    } else if (c === '?') {
      out += '[^/]';
    } else {
      out += c.replace(/[.+^${}()|[\]\\]/g, '\\$&');
    }
  }
  return new RegExp(`^${out}$`);
}

const matchesAny = (path, globs) => globs.some((g) => globToRegExp(g).test(path));

// parseConfig returns { always, ignore, full, map } or { error } for a bad line.
export function parseConfig(text) {
  const config = { always: [], ignore: [], full: [], map: [] };
  const lines = text.split('\n');
  for (let n = 0; n < lines.length; n++) {
    const line = lines[n].replace(/\r$/, '');
    if (line.trim() === '' || line.startsWith('#')) continue;
    const fields = line.split('\t');
    const [directive, glob, target] = fields;
    const bad = (why) => ({ error: `${CONFIG} line ${n + 1}: ${why}` });
    if (!glob || glob.startsWith('/') || glob.split('/').includes('..')) return bad('missing or non-relative glob');
    if (directive === 'map') {
      if (fields.length !== 3 || !target) return bad('map needs <glob><TAB><test-glob>');
      config.map.push([glob, target]);
    } else if (directive === 'always' || directive === 'ignore' || directive === 'full') {
      if (fields.length !== 2) return bad(`${directive} takes exactly one glob`);
      config[directive].push(glob);
    } else {
      return bad(`unknown directive ${JSON.stringify(directive)}`);
    }
  }
  return config;
}

// parseScopeFile splits core's NUL-terminated scope file. A non-empty body that
// does not end in NUL is not core's format.
export function parseScopeFile(body) {
  if (body === '') return { paths: [] };
  if (!body.endsWith('\0')) return { error: 'the scope file is not NUL-terminated' };
  return { paths: body.slice(0, -1).split('\0') };
}

// listFiles walks the project for files matching any of globs, skipping
// dependency and hidden directories, the same places vitest never collects tests
// from.
function listFiles(root, globs) {
  if (globs.length === 0) return [];
  const res = globs.map(globToRegExp);
  const found = [];
  const walk = (dir) => {
    for (const name of readdirSync(join(root, dir))) {
      if (name === 'node_modules' || name.startsWith('.')) continue;
      const rel = dir ? `${dir}/${name}` : name;
      const st = statSync(join(root, rel));
      if (st.isDirectory()) walk(rel);
      else if (res.some((re) => re.test(rel))) found.push(rel);
    }
  };
  walk('');
  return found;
}

// isTracked asks git, read-only, whether the opt-in file is tracked.
export function isTracked(root) {
  try {
    execFileSync('git', ['-C', root, '--literal-pathspecs', 'ls-files', '--error-unmatch', '--', CONFIG], { stdio: 'ignore' });
    return true;
  } catch {
    return false;
  }
}

// decide is the whole selection over (root, scope mode, scope paths or a scope
// read error, config text, whether the config is tracked).
export function decide(root, mode, scope, configText, tracked) {
  // OPT-IN. Without a TRACKED config file the run is FULL, the same suite the
  // engine ran before selection existed — including its guarantee that a failing
  // test in a file the diff never touched still fails a diff-scoped gate. A scoped
  // run gives that guarantee up for unreached tests, so a consumer chooses it, in
  // a file a reviewer can see.
  if (configText === null) return { mode: 'full', reason: `no ${CONFIG}; diff-scoped selection is opt-in` };
  if (!tracked) return { mode: 'full', reason: `${CONFIG} is not tracked by git; diff-scoped selection is opt-in` };
  // An older core, or a caller with no gate scope, hands over nothing: full.
  if (mode === '') return { mode: 'full', reason: 'core handed over no gate scope (BACKSTOP_SCOPE_MODE unset)' };
  if (mode === 'all') return { mode: 'full', reason: 'the gate scope is the whole project (--all)' };
  if (mode !== 'diff' && mode !== 'file') return { mode: 'full', reason: `unknown gate scope mode ${JSON.stringify(mode)}` };
  if (scope.error) return { mode: 'full', reason: scope.error };
  const config = parseConfig(configText);
  if (config.error) return { mode: 'full', reason: config.error };
  if (scope.paths.length === 0) return { mode: 'none', reason: 'the gate scope holds no files' };

  const related = new Set();
  const mapTargets = [];
  let relevant = false;
  for (const raw of new Set(scope.paths)) {
    const path = posix.normalize(raw);
    if (raw === '' || path === '.' || path.startsWith('../') || path.startsWith('/')) return { mode: 'full', reason: `${JSON.stringify(raw)} is not a project-relative file path` };
    // The decision goes back to the producer one path per line.
    if (/[\n\r]/.test(path)) return { mode: 'full', reason: `a scope path contains a line break (${JSON.stringify(path)})` };
    const abs = join(root, path);
    if (existsSync(abs) && statSync(abs).isDirectory()) return { mode: 'full', reason: `the scope holds a directory (${path}), not a file` };
    // Installed dependencies and installed packs are never repo source.
    if (path.startsWith('node_modules/') || path.startsWith('.backstop/packs/')) continue;

    if (matchesAny(path, BUILTIN_FULL)) return { mode: 'full', reason: `${path} changes how every test resolves` };
    if (matchesAny(path, config.ignore)) continue;
    if (matchesAny(path, config.full)) return { mode: 'full', reason: `${path} is declared full in ${CONFIG}` };

    const mapped = config.map.filter(([glob]) => globToRegExp(glob).test(path));
    for (const [, target] of mapped) mapTargets.push(target);

    const exists = existsSync(abs);
    // A deleted test file strands nothing: no other test imports a test file.
    // Core's list is project-root-relative, so absent from disk means deleted.
    if (!exists && TEST_FILE.test(path)) continue;
    relevant = true;
    if (mapped.length > 0) {
      // The mapping is the consumer's account of what this path affects; a mapped
      // source file still reaches its importers too.
      if (SOURCE_EXTENSIONS.some((ext) => path.endsWith(ext)) && exists) related.add(path);
      continue;
    }
    if (!exists) {
      // A deleted module (a rename's old path among them), or a deleted fixture a
      // test read, leaves no edge to trace.
      return { mode: 'full', reason: `${path} does not exist (deleted or renamed); what depended on it cannot be traced` };
    }
    if (SOURCE_EXTENSIONS.some((ext) => path.endsWith(ext))) related.add(path);
    else return { mode: 'full', reason: `${path} is outside the import graph and not declared in ${CONFIG}` };
  }

  // Nothing but ignored paths and deleted test files means nothing can change a
  // result, so the `always` tests are not run for it either.
  if (!relevant) return { mode: 'none', reason: 'no file in scope can change a test result' };
  // A declared glob that matches no file is a stale declaration; it narrows nothing.
  for (const glob of new Set([...config.always, ...mapTargets])) {
    const files = listFiles(root, [glob]);
    if (files.length === 0) return { mode: 'full', reason: `${CONFIG} glob ${glob} matches no file` };
    for (const file of files) {
      if (/[\n\r]/.test(file)) return { mode: 'full', reason: `a declared test path contains a line break (${JSON.stringify(file)})` };
      related.add(file);
    }
  }
  if (related.size === 0) return { mode: 'none', reason: 'no file in scope can change a test result' };
  const bytes = [...related].reduce((n, p) => n + Buffer.byteLength(p) + 3, 0);
  if (related.size > MAX_SELECTED_PATHS || bytes > MAX_SELECTED_BYTES) {
    return { mode: 'full', reason: `${related.size} selected paths are too many to pass to vitest related` };
  }
  return { mode: 'scoped', reason: `${related.size} path(s) handed to vitest related`, paths: [...related].sort() };
}

if (process.argv[1] && import.meta.url === pathToFileURL(realpathSync(process.argv[1])).href) {
  const [root, mode = '', scopeFile = ''] = process.argv.slice(2);
  const configPath = join(root, CONFIG);
  const configText = existsSync(configPath) ? readFileSync(configPath, 'utf8') : null;
  let scope = { paths: [] };
  if (mode === 'diff' || mode === 'file') {
    if (scopeFile === '') scope = { error: `core set BACKSTOP_SCOPE_MODE=${mode} but no BACKSTOP_SCOPE_FILE` };
    else {
      try {
        // fatal: a path that is not valid UTF-8 would otherwise decode to U+FFFD,
        // name no file on disk, and read as deleted. Undecodable means full.
        scope = parseScopeFile(new TextDecoder('utf-8', { fatal: true }).decode(readFileSync(scopeFile)));
      } catch (err) {
        scope = { error: `reading the scope file failed (${String(err.message).split('\n')[0]})` };
      }
    }
  }
  const decision = decide(root, mode, scope, configText, configText === null ? false : isTracked(root));
  process.stdout.write(`${decision.mode}\t${decision.reason}\n`);
  for (const p of decision.paths ?? []) process.stdout.write(`${p}\n`);
}
