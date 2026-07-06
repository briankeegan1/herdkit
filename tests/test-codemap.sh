#!/usr/bin/env bash
# test-codemap.sh — hermetic test for the `herd codemap` subcommand (scripts/herd/codemap.sh).
#
# Drives the REAL CLI against the REAL engine tree but redirects the output to a temp file via
# HERD_CODEMAP_OUT, so the committed docs/codemap.md is never touched. Asserts the contract from
# HERD-36:
#   • the subcommand runs (exit 0) and emits the map file
#   • DETERMINISTIC + idempotent: a second run reports "up to date" and leaves the file byte-identical
#   • the map covers a known module (agent-watch.sh) and a known config-key → consumer mapping
#     (MERGE_POLICY is consumed by agent-watch.sh)
#   • the output carries no absolute path and no obvious timestamp (the determinism guardrails)
#
# Run:  bash tests/test-codemap.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"
CODEMAP="$HERE/../scripts/herd/codemap.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; ok(){ pass=$((pass+1)); }

[ -f "$HERD" ]    || fail "bin/herd not found at $HERD"
[ -f "$CODEMAP" ] || fail "codemap.sh not found at $CODEMAP"

OUT="$T/codemap.md"
export HERD_CODEMAP_OUT="$OUT"

# ── 1. The subcommand runs and emits the map ─────────────────────────────────────────────────────
out1="$(bash "$HERD" codemap </dev/null 2>&1)" || fail "herd codemap exited non-zero: $out1"
[ -f "$OUT" ]                                   || fail "herd codemap did not emit $OUT"
[ -s "$OUT" ]                                   || fail "emitted codemap is empty"
case "$out1" in *created*|*updated*|*"up to date"*) ;; *) fail "unexpected first-run message: $out1" ;; esac
ok

# ── 2. Idempotent + deterministic: a second run changes nothing ──────────────────────────────────
# Re-run via codemap.sh directly (the exact script cmd_codemap execs) to skip the CLI startup cost.
cp "$OUT" "$T/first.md"
out2="$(bash "$CODEMAP" </dev/null 2>&1)" || fail "second codemap run exited non-zero: $out2"
case "$out2" in *"up to date"*) ;; *) fail "second run should report 'up to date', got: $out2" ;; esac
cmp -s "$T/first.md" "$OUT" || fail "codemap is not idempotent — second run changed the file"
ok

# A fresh regeneration from scratch (no prior file) must byte-match the first run — the hard
# DETERMINISM contract, independent of the write-skip optimization.
OUT2="$T/fresh.md"
HERD_CODEMAP_OUT="$OUT2" bash "$CODEMAP" </dev/null >/dev/null 2>&1 || fail "fresh codemap run failed"
cmp -s "$T/first.md" "$OUT2" || fail "two independent generations differ — output is not deterministic"
ok

# ── 3. Covers a known module ─────────────────────────────────────────────────────────────────────
grep -qE '^- `agent-watch\.sh` —' "$OUT" || fail "modules section missing the known module agent-watch.sh"
grep -qF '`bin/herd`'            "$OUT" || fail "modules section missing bin/herd"
grep -qF 'Who sources whom'      "$OUT" || fail "missing the who-sources-whom section"
ok

# ── 4. Covers a known config-key → consumer mapping ──────────────────────────────────────────────
# MERGE_POLICY is a kind=config key genuinely consumed by the watcher (agent-watch.sh).
mp_line="$(grep -E '^- `MERGE_POLICY` →' "$OUT" || true)"
[ -n "$mp_line" ]                          || fail "config section missing the MERGE_POLICY key"
case "$mp_line" in *'`agent-watch.sh`'*) ;; *) fail "MERGE_POLICY should map to agent-watch.sh; got: $mp_line" ;; esac
ok

# ── 5. Determinism guardrails: no absolute path, no timestamp leaked into the map ────────────────
# No absolute path token (a leading-slash path segment or a Windows drive letter) — the map is
# meant to be identical across machines and checkouts.
if grep -qE '(^|[^a-zA-Z0-9_])/(Users|home|c/|tmp)/' "$OUT"; then
  fail "codemap leaked an absolute path (breaks determinism across machines)"
fi
grep -qiE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$OUT" && fail "codemap leaked a date/timestamp (breaks determinism)"
ok

echo "PASS ($pass assertions)"
