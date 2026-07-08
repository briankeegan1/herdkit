#!/usr/bin/env node
/*
 * herd.cjs — the `herd` entrypoint installed by `npm i -g herdkit`.
 *
 * Thin shim: locate the bootstrapped bash engine (HERDKIT_HOME, default ~/.herdkit) and exec
 * its `bin/herd` under bash, forwarding argv and exit code. The engine stays canonical — this
 * never re-implements any command. On Windows this requires Git Bash or WSL2 (docs/windows.md).
 */
'use strict';
const { spawnSync } = require('node:child_process');
const os = require('node:os');
const path = require('node:path');
const fs = require('node:fs');

const HOME = process.env.HERDKIT_HOME || path.join(os.homedir(), '.herdkit');
const ENGINE = path.join(HOME, 'bin', 'herd');

if (!fs.existsSync(ENGINE)) {
  console.error(`[herdkit] engine not found at ${ENGINE}`);
  console.error('[herdkit] Re-run the bootstrap:  npm rebuild -g herdkit');
  console.error('[herdkit] or install directly:   curl -fsSL https://raw.githubusercontent.com/briankeegan1/herdkit/main/install.sh | bash');
  process.exit(127);
}

// Resolve a bash to run the engine (Git Bash / WSL both expose `bash`).
const r = spawnSync('bash', [ENGINE, ...process.argv.slice(2)], { stdio: 'inherit' });
if (r.error) {
  console.error(`[herdkit] failed to launch bash: ${r.error.message}`);
  console.error('[herdkit] On Windows, run under WSL2 (the supported path) — see docs/windows.md.');
  process.exit(127);
}
process.exit(r.status === null ? 1 : r.status);
