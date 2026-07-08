#!/usr/bin/env node
/*
 * postinstall.cjs — bootstrap the herdkit bash engine after `npm i -g herdkit`.
 *
 * herdkit IS a bash engine; this npm package is a thin bootstrapper, NOT a re-implementation.
 * On install we ensure a managed engine checkout at HERDKIT_HOME (default ~/.herdkit) pinned to
 * this package's version tag, reusing the repo's own idempotent install.sh where possible.
 *
 * FAIL-SOFT by design: a machine without git/bash (or offline) must not hard-fail `npm install`.
 * We print actionable guidance and exit 0; the `herd` shim re-checks and guides again at run time.
 */
'use strict';
const { execFileSync } = require('node:child_process');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');

const VERSION = require('../package.json').version;
const REPO_URL = process.env.HERDKIT_REPO_URL || 'https://github.com/briankeegan1/herdkit.git';
const HOME = process.env.HERDKIT_HOME || path.join(os.homedir(), '.herdkit');
// Publish flow (docs/releasing.md) tags releases `v<version>`; pin the checkout to this tag.
const TAG = process.env.HERDKIT_REF || `v${VERSION}`;

function have(cmd) {
  const probe = process.platform === 'win32' ? `where ${cmd}` : `command -v ${cmd}`;
  try {
    execFileSync(probe, { stdio: 'ignore', shell: true });
    return true;
  } catch { return false; }
}

function run(cmd, args, opts) {
  return execFileSync(cmd, args, { stdio: 'inherit', ...opts });
}

function guide(msg) {
  console.warn(`\n[herdkit] ${msg}`);
  console.warn('[herdkit] Manual install:  curl -fsSL https://raw.githubusercontent.com/briankeegan1/herdkit/main/install.sh | bash');
  console.warn('[herdkit] Docs:            https://github.com/briankeegan1/herdkit#readme\n');
}

try {
  if (!have('git')) { guide('git not found — cannot bootstrap the engine.'); process.exit(0); }
  if (!have('bash')) { guide('bash not found — herdkit needs bash (on Windows use Git Bash or WSL2; see docs/windows.md).'); process.exit(0); }

  if (fs.existsSync(path.join(HOME, '.git'))) {
    console.log(`[herdkit] Updating engine checkout at ${HOME} …`);
    run('git', ['-C', HOME, 'fetch', '--tags', '--quiet', 'origin']);
    // Best-effort pin to this package's tag; fall back to a plain ff-update if the tag isn't published yet.
    try { run('git', ['-C', HOME, 'checkout', '--quiet', TAG]); }
    catch { run('git', ['-C', HOME, 'pull', '--ff-only', '--quiet']); }
  } else {
    console.log(`[herdkit] Cloning engine to ${HOME} …`);
    fs.mkdirSync(path.dirname(HOME), { recursive: true });
    run('git', ['clone', '--quiet', REPO_URL, HOME]);
    try { run('git', ['-C', HOME, 'checkout', '--quiet', TAG]); }
    catch { console.warn(`[herdkit] tag ${TAG} not found — staying on default branch.`); }
  }
  console.log(`[herdkit] Engine ready at ${HOME}. Run \`herd doctor\` to verify dependencies.`);
} catch (e) {
  guide(`bootstrap failed: ${e && e.message ? e.message : e}`);
  process.exit(0); // never fail the npm install over an environment gap.
}
