#!/usr/bin/env bash
# hermetic-env-scrub.sh — HERD-458: seal off herd-config.sh's own EXPORTED keys before a hermetic
# test runs, so a CONFIGURED project's live values never leak past the harness process into a test
# asserting the shell DEFAULT.
#
# MECHANISM (grounded live, HERD-458): scripts/herd/healthcheck.sh sources herd-config.sh in ITS OWN
# process (so the light-profile lints can read the project's config), which — since HERD-449 —
# `export`s the engine-core config keys. The heavy profile then execs the project's HEALTHCHECK_CMD as
# a CHILD of that same process, and every EXPORTED var crosses that boundary: a hermetic test's own
# `: "${KEY:=default}"` line becomes a no-op because the key already has a value, so a test asserting
# the DEFAULT reds the instant a project's config differs from it. Not just missing defaults either —
# `env -u SOMEVAR bash -c '…'` (the isolated-child idiom env-export-lint.sh itself uses) only unsets
# the ONE named var; every OTHER inherited exported var, including one a mutated herd-config.sh copy
# no longer exports itself, stays exported because bash's export attribute survives inheritance
# regardless of whether the child's own script re-asserts it — an already-exported ambient value can't
# be un-exported by deleting the `export` line downstream. Six tests reproduced this on this repo's own
# CONFIGURED .herd/config (HEALTH_CONCURRENCY=2, WATCHER_AUTOMERGE=true, MAIN_HEALTH_TICK=on, …):
# test-cli-reload, test-env-export-lint, test-health-autofix, test-healthcheck-gate,
# test-main-health-invariant, test-main-health-slot-priority.
#
# THE FIX: `unset` every key herd-config.sh exports, in the harness process, BEFORE it spawns the
# first hermetic-test child — mirrors the JOURNAL_FILE pin (HERD-363), generalized so the key set can
# never drift out of sync with herd-config.sh's own export surface.
#
# herd_hermetic_scrub_keys [<herd-config.sh path>]
#   TEXT-scans (never sources — a project's real .herd/config runs arbitrary shell) herd-config.sh for
#   every name named in an `export …` statement anywhere in the file: a plain leading `export A B`, a
#   backslash-continued `export A B \` + next-line names, an `export A=val`, or a guarded
#   `cond && export A`. Comments are stripped before matching (the file's prose repeatedly uses the
#   word "export" in English, e.g. "must be exported" — only a REAL export statement, in command
#   position after a line start or a `;`/`&&`/`||`/`|`, counts). Prints each name once, sorted.
#   ONE SOURCE OF TRUTH: a future PR that adds `export NEWKEY` to herd-config.sh is scrubbed
#   automatically — nothing here needs editing in lockstep.
herd_hermetic_scrub_keys() {
  local _hes_cfg="${1:-scripts/herd/herd-config.sh}"
  [ -f "$_hes_cfg" ] || return 0
  awk '
    {
      line = $0
      while (line ~ /\\[ \t]*$/) {
        sub(/\\[ \t]*$/, "", line)
        if ((getline cont) <= 0) { break }
        line = line " " cont
      }
      hashpos = index(line, "#")
      if (hashpos > 0) line = substr(line, 1, hashpos - 1)
      n = split(line, clauses, /[;&|]+/)
      for (i = 1; i <= n; i++) {
        clause = clauses[i]
        gsub(/^[ \t]+/, "", clause)
        gsub(/[ \t]+$/, "", clause)
        if (clause ~ /^export([ \t]|$)/) {
          rest = clause
          sub(/^export[ \t]*/, "", rest)
          m = split(rest, toks, /[ \t]+/)
          for (j = 1; j <= m; j++) {
            tok = toks[j]
            if (tok == "") continue
            eq = index(tok, "=")
            name = (eq > 0) ? substr(tok, 1, eq - 1) : tok
            if (name ~ /^[A-Za-z_][A-Za-z0-9_]*$/) print name
          }
        }
      }
    }
  ' "$_hes_cfg" | sort -u
}

# herd_hermetic_env_scrub [<herd-config.sh path>]
#   Unsets every key herd_hermetic_scrub_keys names, in THIS shell — so a child process forked after
#   this call (bats, a bare `bash test.sh`, …) never inherits a project's live-configured value for a
#   key a hermetic test asserts the DEFAULT of. Call ONCE per harness process, before the first test
#   executes (same discipline as the JOURNAL_FILE pin): `unset` does not need repeating per test
#   because nothing RE-EXPORTS these keys between tests — only a test that deliberately (re-)exports
#   its own value re-arms it, scoped to that one test's own child process tree.
herd_hermetic_env_scrub() {
  local _hes_cfg="${1:-scripts/herd/herd-config.sh}" _hes_key
  while IFS= read -r _hes_key; do
    [ -n "$_hes_key" ] || continue
    unset "$_hes_key"
  done < <(herd_hermetic_scrub_keys "$_hes_cfg")
}
