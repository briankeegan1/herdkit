#!/usr/bin/env bash
# test-model-review-driver-validate.sh — hermetic proof of HERD-311: driver-qualified MODEL_REVIEW
# validation at BOTH enforcement surfaces.
#
# FIX: operator set MODEL_REVIEW=codex:gpt-5.4 (machine-local); 'herd config set' ACCEPTED it and the
# watcher dispatched a review with an unusable model (incident 2026-07-10, PR #420).
#
# Two surfaces tested:
#   (a) herd config set MODEL_REVIEW — eagerly validates a driver-qualified ref against shipped
#       templates/drivers/*.driver; refuses with a clear message on an unknown driver prefix.
#       Byte-identical for a bare model id (the common case).
#   (b) herd-review.sh dispatch — resolves REVIEW_MODEL at startup; fails loud (non-zero exit) when
#       the ref names an unknown driver, so the watcher receives an INFRA signal rather than silently
#       dispatching against a broken model.
#
# Fully hermetic: fake herd project, stub runtimes on PATH, no network, no real claude.
# Run:  bash tests/test-model-review-driver-validate.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
REVIEW="$ROOT/scripts/herd/herd-review.sh"
CAPS="$ROOT/templates/capabilities.tsv"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASSN=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ PASSN=$((PASSN+1)); }

for f in "$HERD" "$REVIEW" "$CAPS"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# ── Stubs for bin/herd bootstrap ────────────────────────────────────────────────────────────────────
BIN="$T/bin"; mkdir -p "$BIN"
for cmd in pgrep gh git herdr; do printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/$cmd"; chmod +x "$BIN/$cmd"; done
export PATH="$BIN:$PATH"

# ── Minimal herd project fixture ────────────────────────────────────────────────────────────────────
P="$T/proj"; mkdir -p "$P/.herd" "$P/trees"
git -C "$P" init -q
git -C "$P" config user.email t@t.t; git -C "$P" config user.name t
( cd "$P" && git commit -q --allow-empty -m init )
P_REAL="$(cd "$P" && pwd -P)"
cat > "$P/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$P_REAL"
WORKTREES_DIR="$P_REAL/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="testproj"
MODEL_REVIEW="claude-sonnet-4-6"
CFG

# Convenience wrapper: run herd config set in the project; captures combined output + rc.
_herd_set(){
  local key="$1" val="$2"
  set +e
  OUT="$(cd "$P" && HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=1 \
           bash "$HERD" config set "$key" "$val" 2>&1)"
  RC=$?
  set -e
}

################################################################################
# (a) — herd config set MODEL_REVIEW validation
################################################################################

# (a1) A bare model id (no colon) must be ACCEPTED — this is the common case and must remain
# byte-identical (no driver-qualified path triggered). HERD-311 must not regress bare-model sets.
_herd_set MODEL_REVIEW claude-opus-4-8
[ "$RC" -eq 0 ] \
  || fail "(a1) a bare MODEL_REVIEW must be accepted (rc=$RC, out=$OUT)"
grep -qE '^MODEL_REVIEW="claude-opus-4-8"' "$P/.herd/config.local" \
  || grep -qE '^MODEL_REVIEW="claude-opus-4-8"' "$P/.herd/config" \
  || fail "(a1) accepted MODEL_REVIEW was not written to config (config: $(cat "$P/.herd/config"))"
ok; echo "PASS (a1) bare MODEL_REVIEW accepted"

# (a2) A shipped driver-qualified ref (stub:mymodel — templates/drivers/stub.driver exists) must be
# ACCEPTED. This proves the valid-path is open before we test the refusal.
_herd_set MODEL_REVIEW stub:mymodel
[ "$RC" -eq 0 ] \
  || fail "(a2) a shipped driver-qualified MODEL_REVIEW must be accepted (rc=$RC, out=$OUT)"
ok; echo "PASS (a2) shipped driver-qualified MODEL_REVIEW accepted"

# (a3) A BOGUS driver prefix (codx: names no templates/drivers/codx.driver) must be REFUSED with
# a clear, non-zero exit. This is the live-incident scenario from PR #420.
_herd_set MODEL_REVIEW codx:gpt-5.4
[ "$RC" -ne 0 ] \
  || fail "(a3) MODEL_REVIEW with unknown driver prefix must be REFUSED (rc=0, out=$OUT)"
printf '%s\n' "$OUT" | grep -qi 'refusing to set MODEL_REVIEW' \
  || fail "(a3) refusal message must mention 'refusing to set MODEL_REVIEW' (got: $OUT)"
ok; echo "PASS (a3) bogus driver prefix refused at config set with clear message"

# (a4) An empty model after a shipped driver prefix (stub:) must also be REFUSED — the driver name
# alone is not a valid ref.
_herd_set MODEL_REVIEW stub:
[ "$RC" -ne 0 ] \
  || fail "(a4) MODEL_REVIEW with empty model after driver prefix must be REFUSED (rc=0, out=$OUT)"
ok; echo "PASS (a4) empty model after driver prefix refused at config set"

# (a5) The refused value must NOT have been written to any config file.
grep -E '^MODEL_REVIEW="codx:' "$P/.herd/config" 2>/dev/null \
  && fail "(a5) refused codx: value must not appear in .herd/config"
grep -E '^MODEL_REVIEW="codx:' "$P/.herd/config.local" 2>/dev/null \
  && fail "(a5) refused codx: value must not appear in .herd/config.local"
ok; echo "PASS (a5) refused value not written to config"

################################################################################
# (b) — herd-review.sh: resolve REVIEW_MODEL at startup, dispatch correctly
################################################################################
# Wire up stub runtimes for dispatch observation.
# Each runtime logs "<binary> <model>" to $REVIEW_CALLS and emits a PASS verdict.
_runtime(){
  cat > "$BIN/$1" <<STUB
#!/usr/bin/env bash
m=""; prev=""
for a in "\$@"; do [ "\$prev" = "--model" ] && { m="\$a"; break; }; prev="\$a"; done
printf '%s %s\n' "$1" "\$m" >> "\$REVIEW_CALLS"
printf '{"type":"result","subtype":"success","result":"REVIEW: PASS"}\n'
STUB
  chmod +x "$BIN/$1"
}
_runtime claude
_runtime stub-agent
export REVIEW_CALLS="$T/calls"

# _review <env-assignments…> — run the REAL herd-review.sh in pr mode with HERD_NO_PANE=1; captures
# combined stderr+stdout (the verdict is on stdout) and $RC.
_review(){
  : > "$REVIEW_CALLS"
  set +e
  REVIEW_OUT="$(env "$@" \
    HERD_NO_PANE=1 \
    WORKTREES_DIR="$P_REAL/trees" \
    HERD_CONFIG_FILE="$T/no-such-config" \
    JOURNAL_FILE="$T/journal" \
    HERD_REVIEW_RESULT_FILE="$T/res" \
    REVIEW_CALLS="$REVIEW_CALLS" \
    bash "$REVIEW" "42" "slug-42" 2>&1)"
  RC=$?
  set -e
}

# (b1) BARE REVIEW_MODEL → dispatch to claude (the default driver's runtime), model is the bare value.
_review HERD_REVIEW_MODEL="claude-opus-4-8"
# We only assert the correct binary was invoked; the verdict may be non-zero (no real diff) but we
# confirm the dispatch happened to the right binary with the right model.
grep -q '^claude claude-opus-4-8$' "$REVIEW_CALLS" \
  || fail "(b1) bare MODEL_REVIEW must dispatch to 'claude' with the bare model (calls: $(cat "$REVIEW_CALLS"))"
ok; echo "PASS (b1) bare MODEL_REVIEW dispatches to the default claude runtime"

# (b2) DRIVER-QUALIFIED REVIEW_MODEL (stub:mymodel) → dispatch to stub-agent with bare model.
# This proves the driver portion IS honored (not silently discarded) in the single-reviewer path.
_review HERD_REVIEW_MODEL="stub:mymodel"
grep -q '^stub-agent mymodel$' "$REVIEW_CALLS" \
  || fail "(b2) driver-qualified MODEL_REVIEW must dispatch to the named driver binary with the bare model (calls: $(cat "$REVIEW_CALLS"))"
ok; echo "PASS (b2) driver-qualified MODEL_REVIEW dispatches to the named driver binary"

# (b3) BOGUS DRIVER in REVIEW_MODEL → fail loud (non-zero exit) at STARTUP, before any dispatch.
_review HERD_REVIEW_MODEL="codx:gpt-5.4"
[ "$RC" -ne 0 ] \
  || fail "(b3) an unknown driver in REVIEW_MODEL must cause herd-review.sh to exit non-zero (rc=0)"
printf '%s\n' "$REVIEW_OUT" | grep -qi 'does not resolve\|not resolve\|refusing' \
  || fail "(b3) the error message must explain the bad ref (got: $REVIEW_OUT)"
# No dispatch must have occurred — the bogus ref must be caught before any binary is launched.
[ ! -s "$REVIEW_CALLS" ] \
  || fail "(b3) a bad REVIEW_MODEL must abort before dispatching any runtime (calls: $(cat "$REVIEW_CALLS"))"
ok; echo "PASS (b3) bogus driver in REVIEW_MODEL exits non-zero with a clear error, no dispatch"

################################################################################
# Wiring check — the validation MUST be present in both files
################################################################################
grep -q 'herd_model_resolve.*MODEL_REVIEW\|MODEL_REVIEW.*herd_model_resolve' "$HERD" \
  || grep -q 'key.*MODEL_REVIEW.*herd_model_resolve\|MODEL_REVIEW.*die.*refusing' "$HERD" \
  || grep -q 'refusing to set MODEL_REVIEW' "$HERD" \
  || fail "(w1) bin/herd must contain eager MODEL_REVIEW driver validation via herd_model_resolve"
grep -q '_REVIEW_DRV\|herd_model_resolve.*REVIEW_MODEL\|REVIEW_MODEL.*herd_model_resolve' "$REVIEW" \
  || fail "(w2) herd-review.sh must resolve REVIEW_MODEL at startup (_REVIEW_DRV)"
grep -q 'herd_driver_oneshot_exec_as.*_REVIEW_DRV\|_REVIEW_DRV.*herd_driver_oneshot_exec_as' "$REVIEW" \
  || fail "(w3) herd-review.sh single-reviewer dispatch must use herd_driver_oneshot_exec_as with _REVIEW_DRV"
ok; echo "PASS (w) wiring checks"

echo ""
echo "ALL $PASSN tests PASSED — HERD-311 MODEL_REVIEW driver-qualified ref validation"
