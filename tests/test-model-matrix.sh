#!/usr/bin/env bash
# test-model-matrix.sh — hermetic proof for the MODEL MATRIX (HERD-151): any LLM/model settable per
# role via an optionally runtime-qualified MODEL_* ref '<driver>:<model>', a suggestions catalog
# (templates/models.tsv), and a visible 'unpriced' cost line for foreign refs. Covers:
#   (1) ref parsing in driver.sh — bare (byte-identical), qualified-known split, unknown-prefix
#       LOUD-fail, empty-model-after-known-driver fail, empty ref pass-through
#   (2) `herd config set|get` round-trip for a bare AND a runtime-qualified MODEL_* value, and that a
#       ref with an UNKNOWN driver is ALLOWED with a soft note (never refused — coequal-sources rule)
#   (3) `herd config models` catalog lint — the shipped catalog is well-formed; a bad tier / bad date
#       row is caught and exits non-zero (tier + date per row)
#   (4) cost.sh surfaces an unknown/foreign model as an explicit `unpriced=1` field + a model=<id>?
#       flag, never a silent $0
#
# Fully hermetic: local temp dirs + a stub drivers dir. NO herdr, NO gh, NO claude, NO network, NO model.
# Run:  bash tests/test-model-matrix.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
HERD="$ROOT/bin/herd"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"
COST_SH="$ROOT/scripts/herd/cost.sh"
JOURNAL_SH="$ROOT/scripts/herd/journal.sh"
CATALOG="$ROOT/templates/models.tsv"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

for f in "$HERD" "$DRIVER_SH" "$COST_SH" "$JOURNAL_SH" "$CATALOG"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"

# ── A stub drivers dir so the valid-driver set is deterministic (independent of what ships). ───────
DD="$T/drivers"; mkdir -p "$DD"
printf 'DRIVER_LIST_AGENTS=x\n' > "$DD/herdr-claude.driver"
printf 'DRIVER_LIST_AGENTS=x\n' > "$DD/headless.driver"
export HERD_DRIVERS_DIR="$DD"

# ── 1. Ref parsing (driver.sh: herd_model_resolve / herd_model_for_spawn). ────────────────────────
# shellcheck source=/dev/null
. "$DRIVER_SH"

# bare → default driver + whole value as model (BYTE-IDENTICAL back-compat)
out="$(HERD_DRIVER=herdr-claude herd_model_resolve "claude-opus-4-8")" \
  || fail "bare ref should resolve, not fail"
[ "$out" = "$(printf 'herdr-claude\tclaude-opus-4-8')" ] || fail "bare resolve wrong: [$out]"
[ "$(herd_model_for_spawn "claude-opus-4-8")" = "claude-opus-4-8" ] \
  || fail "bare model-for-spawn must echo the model unchanged (byte-identical)"
ok; echo "PASS (1a) bare ref resolves to <default-driver> + unchanged model"

# qualified with a KNOWN driver → split on the first colon
out="$(herd_model_resolve "headless:claude-haiku-4-5")" || fail "known-driver ref should resolve"
[ "$out" = "$(printf 'headless\tclaude-haiku-4-5')" ] || fail "qualified resolve wrong: [$out]"
[ "$(herd_model_for_spawn "headless:claude-haiku-4-5")" = "claude-haiku-4-5" ] \
  || fail "qualified model-for-spawn must echo just the bare model"
# a model id may itself contain colons (split on FIRST colon only)
out="$(herd_model_resolve "headless:ns:llama3:8b")" || fail "multi-colon model should resolve"
[ "$out" = "$(printf 'headless\tns:llama3:8b')" ] || fail "multi-colon split wrong: [$out]"
ok; echo "PASS (1b) known-driver ref splits on the first colon"

# UNKNOWN driver prefix → LOUD hard error (non-zero + a message), never a silent fallback
if err="$(herd_model_for_spawn "openai:gpt-4o" 2>&1)"; then
  fail "unknown driver prefix must FAIL, not silently resolve (got [$err])"
fi
case "$err" in *unknown*driver*) ok ;; *) fail "unknown-driver error is not loud/clear: [$err]" ;; esac
echo "PASS (1c) unknown driver prefix loud-fails (never a silent claude fallback)"

# empty model after a KNOWN driver prefix → fail; empty ref → pass-through empty (no --model)
herd_model_for_spawn "headless:" >/dev/null 2>&1 && fail "empty model after 'headless:' must fail"
[ "$(herd_model_for_spawn "")" = "" ] || fail "empty ref must pass through empty (no --model)"
ok; echo "PASS (1d) empty-model-after-driver fails; empty ref passes through"

# ── seed a minimal herd repo `herd config` accepts. ───────────────────────────────────────────────
seed_repo() {
  local d="$1"; mkdir -p "$d/.herd"; git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  cat > "$d/.herd/config" <<EOF
HERD_VERSION=1
WORKSPACE_NAME="t"
PROJECT_ROOT="$d"
DEFAULT_BRANCH="origin/main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
MODEL_FEATURE="claude-sonnet-4-6"
MODEL_QUICK="claude-haiku-4-5"
EOF
}

# ── 2. config set|get round-trip: bare, runtime-qualified, and an unknown-driver ref (allowed). ───
R="$T/repo"; seed_repo "$R"
# The real drivers dir must back `herd config set`'s driver-known check, so 'headless' is recognized.
unset HERD_DRIVERS_DIR
# HERMETIC GUARD: MODEL_FEATURE is watcher-affecting, so `herd config set` would restart the watcher —
# `cmd_reload` spawns a REAL `nohup bash agent-watch.sh` daemon against this temp repo. Defer that
# side-effect (the designed knob; the set/get round-trip this test asserts is unchanged) so no real
# watcher launches. Also shadow herdr/claude with benign no-ops (the header promises "NO herdr, NO
# claude") to cover the doctor probe and any residual control-room reach.
export HERD_INIT_DEFER_APPLY=1
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\necho '"'"'{}'"'"'\nexit 0\n'      > "$BIN/herdr";  chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\necho '"'"'claude 0.0.0'"'"'\nexit 0\n' > "$BIN/claude"; chmod +x "$BIN/claude"
export PATH="$BIN:$PATH"
run_herd(){ ( cd "$R" && "$HERD" "$@" ); }

run_herd config set --local MODEL_FEATURE "claude-opus-4-8" >/dev/null 2>&1 \
  || fail "config set (bare) failed"
[ "$(run_herd config get MODEL_FEATURE)" = "claude-opus-4-8" ] || fail "bare set/get round-trip mismatch"

# runtime-qualified value with a KNOWN driver — stored + read back VERBATIM
run_herd config set --local MODEL_QUICK "headless:claude-haiku-4-5" >/dev/null 2>&1 \
  || fail "config set (qualified) failed"
[ "$(run_herd config get MODEL_QUICK)" = "headless:claude-haiku-4-5" ] \
  || fail "qualified set/get round-trip mismatch"
ok; echo "PASS (2a) config set|get round-trips bare AND runtime-qualified MODEL_* values"

# an UNKNOWN driver prefix is ALLOWED with a soft note at set time (loud-fail is a SPAWN concern) —
# never refused, and the value round-trips verbatim
set_out="$(run_herd config set --local MODEL_QUICK "openai:gpt-4o" 2>&1)" \
  || fail "config set must NOT refuse an unknown-driver ref (coequal-sources rule)"
case "$set_out" in *"not a shipped driver"*) ok ;; *) fail "no soft note for unshipped driver: $set_out" ;; esac
[ "$(run_herd config get MODEL_QUICK)" = "openai:gpt-4o" ] || fail "unknown-driver ref did not round-trip"
echo "PASS (2b) an unknown-driver ref is allowed with a soft note (never refused)"

# an uncatalogued bare model is allowed with a soft note; a catalogued one shows its tier
un_out="$(run_herd config set --local MODEL_FEATURE "brand-new-xyz" 2>&1)" || fail "uncatalogued set failed"
case "$un_out" in *"not in the suggestions catalog"*) ok ;; *) fail "no soft note for uncatalogued model: $un_out" ;; esac
cat_out="$(run_herd config set --local MODEL_FEATURE "claude-opus-4-8" 2>&1)" || fail "catalogued set failed"
case "$cat_out" in *"catalog: tier=judgment"*) ok ;; *) fail "no catalog tier note for catalogued model: $cat_out" ;; esac
echo "PASS (2c) config set suggests from the catalog (soft note when uncatalogued)"

# list shows the effective value (provenance-tagged) — round-trip visible in list too
run_herd config list 2>/dev/null | grep -q "MODEL_QUICK" || fail "config list omits MODEL_QUICK"
ok; echo "PASS (2d) config list surfaces the MODEL_* values"

# ── 3. catalog lint (tier + date per row). ────────────────────────────────────────────────────────
run_herd config models lint >/dev/null 2>&1 || fail "shipped models catalog should lint clean"
ok; echo "PASS (3a) the shipped templates/models.tsv lints clean"

BAD="$T/bad.tsv"
printf 'model_ref\ttier\trole_fit\tas_of\n' > "$BAD"
printf 'good-model\tbalanced\tfine\t2026-07-08\n' >> "$BAD"
printf 'bad-tier\tsupreme\tnope\t2026-07-08\n'    >> "$BAD"
printf 'bad-date\tcheap\tnope\t2026-13-99\n'      >> "$BAD"
if ( cd "$R" && HERD_MODELS_CATALOG_FILE="$BAD" "$HERD" config models lint ) >/dev/null 2>&1; then
  fail "catalog lint must FAIL on a bad tier / bad date"
fi
lint_out="$( cd "$R" && HERD_MODELS_CATALOG_FILE="$BAD" "$HERD" config models lint 2>&1 || true )"
case "$lint_out" in *"invalid tier"*) ok ;; *) fail "lint did not flag the bad tier: $lint_out" ;; esac
case "$lint_out" in *"invalid as_of"*) ok ;; *) fail "lint did not flag the bad date: $lint_out" ;; esac
echo "PASS (3b) catalog lint catches a bad tier and a bad date row"

# ── 4. cost.sh surfaces a foreign/unknown model as an explicit unpriced line (not a silent $0). ───
# shellcheck source=/dev/null
. "$JOURNAL_SH"
# shellcheck source=/dev/null
. "$COST_SH"
UDIR="$T/tx"; mkdir -p "$UDIR"
cat > "$UDIR/b.jsonl" <<'JNL'
{"type":"assistant","message":{"role":"assistant","id":"u1","model":"gpt-4o","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL
line="$(cost_report_dir "$UDIR" builder)"
case "$line" in *"unpriced=1"*) ok ;; *) fail "foreign model must report unpriced=1: $line" ;; esac
case "$line" in *"model=gpt-4o?"*) ok ;; *) fail "foreign model must carry the ? flag: $line" ;; esac
case "$line" in *"usd=0.000000"*) ok ;; *) fail "foreign model must price at 0 (never a guess): $line" ;; esac
echo "PASS (4a) cost.sh flags an unknown/foreign model as unpriced (visible, not a silent 0)"

# a fully-priced (all-Claude) component reports unpriced=0 — byte-identical signal for today's operators
PDIR="$T/priced"; mkdir -p "$PDIR"
cat > "$PDIR/b.jsonl" <<'JNL'
{"type":"assistant","message":{"role":"assistant","id":"p1","model":"claude-opus-4-8","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}
JNL
pline="$(cost_report_dir "$PDIR" builder)"
case "$pline" in *"unpriced=0"*) ok ;; *) fail "priced component must report unpriced=0: $pline" ;; esac
echo "PASS (4b) a fully-priced component reports unpriced=0"

echo "ALL PASS ($pass checks)"
