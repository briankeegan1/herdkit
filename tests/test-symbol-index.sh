#!/usr/bin/env bash
# test-symbol-index.sh — hermetic test for the `herd symbol-index` subcommand
# (scripts/herd/symbol-index.sh, HERD-71).
#
# Drives the REAL CLI against the REAL engine tree but redirects the output to a temp file via
# HERD_SYMBOL_INDEX_OUT, so the committed docs/symbol-index.md is never touched. Asserts the contract:
#   • the subcommand runs (exit 0) and emits the index file
#   • DETERMINISTIC + idempotent: a second run reports "up to date" and leaves the file byte-identical;
#     two independent generations are byte-identical
#   • the index covers a known MULTI-def function (_backend_update_state, defined once per backend) and
#     a known cross-file caller mapping (_backend_add_item is called from scribe-step.sh)
#   • the honest-scope limits note is present (readers must not over-trust the heuristic)
#   • determinism guardrails: no absolute path, no timestamp leaked into the index
#   • --check is a read-only staleness probe (0 fresh / non-zero stale/missing); unknown arg → exit 2
#
# Run:  bash tests/test-symbol-index.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"
SI="$HERE/../scripts/herd/symbol-index.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; ok(){ pass=$((pass+1)); }

[ -f "$HERD" ] || fail "bin/herd not found at $HERD"
[ -f "$SI" ]   || fail "symbol-index.sh not found at $SI"

OUT="$T/symbol-index.md"
export HERD_SYMBOL_INDEX_OUT="$OUT"

# ── 1. The subcommand runs and emits the index ───────────────────────────────────────────────────
out1="$(bash "$HERD" symbol-index </dev/null 2>&1)" || fail "herd symbol-index exited non-zero: $out1"
[ -f "$OUT" ]                                        || fail "herd symbol-index did not emit $OUT"
[ -s "$OUT" ]                                        || fail "emitted index is empty"
case "$out1" in *created*|*updated*|*"up to date"*) ;; *) fail "unexpected first-run message: $out1" ;; esac
ok

# ── 2. Idempotent + deterministic: a second run changes nothing ──────────────────────────────────
cp "$OUT" "$T/first.md"
out2="$(bash "$SI" </dev/null 2>&1)" || fail "second symbol-index run exited non-zero: $out2"
case "$out2" in *"up to date"*) ;; *) fail "second run should report 'up to date', got: $out2" ;; esac
cmp -s "$T/first.md" "$OUT" || fail "symbol-index is not idempotent — second run changed the file"
ok

# A fresh regeneration from scratch (no prior file) must byte-match the first run.
OUT2="$T/fresh.md"
HERD_SYMBOL_INDEX_OUT="$OUT2" bash "$SI" </dev/null >/dev/null 2>&1 || fail "fresh symbol-index run failed"
cmp -s "$T/first.md" "$OUT2" || fail "two independent generations differ — output is not deterministic"
ok

# ── 3. Covers a known MULTI-def function ─────────────────────────────────────────────────────────
# _backend_update_state is defined once per backend — the honest same-name case: every def site is
# listed (line numbers not pinned, so this stays low-churn).
bus_line="$(grep -E '^- `_backend_update_state` —' "$OUT" || true)"
[ -n "$bus_line" ]                                    || fail "index missing the known function _backend_update_state"
case "$bus_line" in *'backends/changelog.sh'*) ;; *) fail "_backend_update_state def sites should include changelog.sh backend: $bus_line" ;; esac
case "$bus_line" in *'backends/linear.sh'*)    ;; *) fail "_backend_update_state def sites should include linear.sh backend: $bus_line" ;; esac
grep -qF 'Functions (def → cross-file callers)' "$OUT" || fail "missing the functions section header"
ok

# ── 4. Covers a known cross-file caller mapping ──────────────────────────────────────────────────
# _backend_add_item is invoked cross-file from the scribe drainer (scribe-step.sh).
ai_line="$(grep -E '^- `_backend_add_item` —' "$OUT" || true)"
[ -n "$ai_line" ]                                     || fail "index missing _backend_add_item"
case "$ai_line" in *'callers:'*'scribe-step.sh'*) ;; *) fail "_backend_add_item should show a cross-file caller in scribe-step.sh: $ai_line" ;; esac
ok

# ── 5. Honest-scope limits note is present ───────────────────────────────────────────────────────
grep -qiF 'Honest scope' "$OUT"        || fail "index missing the honest-scope limits note"
grep -qiF 'command position' "$OUT"    || fail "honest-scope note should explain the command-position heuristic"
ok

# ── 6. Determinism guardrails: no absolute path, no timestamp leaked into the index ──────────────
if grep -qE '(^|[^a-zA-Z0-9_])/(Users|home|c/|tmp)/' "$OUT"; then
  fail "symbol-index leaked an absolute path (breaks determinism across machines)"
fi
grep -qiE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$OUT" && fail "symbol-index leaked a date/timestamp (breaks determinism)"
ok

# ── 7. `--check`: read-only staleness probe ──────────────────────────────────────────────────────
# FRESH: $OUT already matches a fresh scan → exit 0 and touch nothing.
cp "$OUT" "$T/before-check.md"
chk_out="$(bash "$SI" --check </dev/null 2>&1)" || fail "--check reported STALE on an up-to-date index: $chk_out"
case "$chk_out" in *fresh*) ;; *) fail "--check fresh run should say 'fresh', got: $chk_out" ;; esac
cmp -s "$T/before-check.md" "$OUT" || fail "--check must NOT modify the committed index (fresh case)"
ok

# STALE (drifted): corrupt the committed index → --check exits non-zero, says STALE, does NOT rewrite.
printf 'stale sentinel line\n' >> "$OUT"
cp "$OUT" "$T/dirty.md"
if bash "$SI" --check </dev/null >/dev/null 2>&1; then
  fail "--check should exit non-zero on a drifted index"
fi
cmp -s "$T/dirty.md" "$OUT" || fail "--check must NOT rewrite the committed index (stale case)"
ok

# STALE (missing): no committed index at all → --check exits non-zero and creates nothing.
rm -f "$OUT"
if bash "$SI" --check </dev/null >/dev/null 2>&1; then
  fail "--check should exit non-zero when the committed index is missing"
fi
[ -f "$OUT" ] && fail "--check must NOT create the committed index when missing"
ok

# Unknown argument is rejected (exit 2) without writing the index.
bash "$SI" --bogus </dev/null >/dev/null 2>&1; rc=$?
[ "$rc" -eq 2 ] || fail "an unknown argument should exit 2, got $rc"
[ -f "$OUT" ] && fail "a rejected argument must not write the index"
ok

echo "PASS ($pass assertions)"
