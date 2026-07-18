#!/usr/bin/env bash
# test-fleet-resolve.sh — hermetic tests for `herd fleet resolve` (HERD-387 deterministic NL
# pre-resolver) and the registry `--alias` leg of `herd fleet register` that feeds it.
#
# Design (mirrors test-fleet.sh):
#   • Fully hermetic: a temp HERD_FLEET_FILE registry + temp fake projects each with their own
#     .herd/config (no git remote needed — repo identity is irrelevant to name/alias resolution).
#   • Precedence + ambiguity fixtures are written straight into the registry file where the CLI
#     itself cannot construct them (e.g. two DIFFERENT projects sharing one canonical NAME — the
#     register path dedups by PATH, not name, so an exact-tier collision is a hand-authored row).
#
# Run:  bash tests/test-fleet-resolve.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0
ok(){ pass=$((pass+1)); }

export HOME="$T/home"; mkdir -p "$HOME"

# _make_project <name> — a dir with a minimal .herd/config the registry can read.
_make_project() {
  local name="$1"
  local root="$T/proj/$name"
  mkdir -p "$root/.herd"
  local root_real; root_real="$(cd "$root" && pwd -P)"
  cat > "$root/.herd/config" <<CFG
PROJECT_ROOT="$root_real"
WORKSPACE_NAME="$name"
CFG
  printf '%s' "$root_real"
}

# ── 1. register --alias roundtrip: aliases land in the registry + herd fleet list ────────────
REG1="$T/reg1/fleet"
ALPHA="$(_make_project alpha)"
BETA="$(_make_project beta)"
HERD_FLEET_FILE="$REG1" bash "$HERD" fleet register "$ALPHA" --alias alpha-svc --alias "Alpha Service" >/dev/null
HERD_FLEET_FILE="$REG1" bash "$HERD" fleet register "$BETA" >/dev/null

grep -qE '^alpha\|.*\|alpha-svc,Alpha Service$' "$REG1" \
  || fail "register --alias should store a comma-joined aliases field, got: $(grep '^alpha|' "$REG1")"
beta_row="$(grep '^beta|' "$REG1")"
beta_nf="$(awk -F'|' '{print NF}' <<< "$beta_row")"
[ "$beta_nf" -eq 3 ] || fail "register with no --alias should stay a 3-field row (no aliases field), got: $beta_row"

out="$(HERD_FLEET_FILE="$REG1" bash "$HERD" fleet list)"
printf '%s' "$out" | grep -q "alpha-svc" || fail "fleet list should show alpha's aliases"
printf '%s' "$out" | grep -q "Alpha Service" || fail "fleet list should show alpha's second alias"
ok

# ── 2. re-registering without --alias PRESERVES existing aliases (no silent wipe) ─────────────
HERD_FLEET_FILE="$REG1" bash "$HERD" fleet register "$ALPHA" >/dev/null
grep -qE '^alpha\|.*\|alpha-svc,Alpha Service$' "$REG1" \
  || fail "a plain re-register (no --alias) must preserve the row's existing aliases"
ok

# ── 3. re-registering WITH --alias REPLACES the alias set ────────────────────────────────────
HERD_FLEET_FILE="$REG1" bash "$HERD" fleet register "$ALPHA" --alias only-this >/dev/null
grep -qE '^alpha\|.*\|only-this$' "$REG1" \
  || fail "register --alias should REPLACE the row's aliases, got: $(grep '^alpha|' "$REG1")"
if grep -q "alpha-svc" "$REG1"; then fail "old aliases should be gone after a replacing --alias register"; fi
ok

# ── 4. precedence fixture registry (hand-authored so exact/alias/prefix ties are reachable) ──
REG2="$T/reg2/fleet"
mkdir -p "$(dirname "$REG2")"
A2="$(_make_project svc-alpha)"
B2="$(_make_project svc-beta)"
C2="$(_make_project svc-gamma)"
D2="$(_make_project svc-alpha-two)"   # a name whose PREFIX collides with svc-alpha's alias tier
cat > "$REG2" <<EOF
# herdkit fleet registry — one project per line: name|path|repo|aliases
svc-alpha|$A2||alpha,shared-alias
svc-beta|$B2||beta
svc-gamma|$C2||shared-alias
svc-alpha-two|$D2|
dup-name|$A2||
dup-name|$B2||
EOF

resolve() { HERD_FLEET_FILE="$REG2" bash "$HERD" fleet resolve "$@"; }

# 4a. exact name match wins outright.
out="$(resolve svc-alpha)"; rc=$?
[ "$rc" -eq 0 ] || fail "exact match should exit 0"
[ "$out" = "svc-alpha" ] || fail "exact match should resolve to svc-alpha, got: $out"
ok

# 4b. exact match is case-insensitive.
out="$(resolve SVC-Beta)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "svc-beta" ] || fail "case-insensitive exact match failed, got: $out (rc=$rc)"
ok

# 4c. alias match (no name matches "alpha" exactly; svc-alpha's alias does).
out="$(resolve alpha)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "svc-alpha" ] || fail "alias match failed, got: $out (rc=$rc)"
ok

# 4d. alias tier is AMBIGUOUS when two projects share one alias — never silently falls to prefix.
set +e
err="$(resolve shared-alias 2>&1 1>/dev/null)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "a shared alias across two projects must be refused as ambiguous"
printf '%s' "$err" | grep -qi "ambiguous" || fail "ambiguous alias refusal should say so, got: $err"
printf '%s' "$err" | grep -q "svc-alpha" || fail "ambiguous alias candidates should list svc-alpha"
printf '%s' "$err" | grep -q "svc-gamma" || fail "ambiguous alias candidates should list svc-gamma"
ok

# 4e. unambiguous prefix match (no exact/alias hit anywhere for "svc-be").
out="$(resolve svc-be)"; rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "svc-beta" ] || fail "unambiguous prefix match failed, got: $out (rc=$rc)"
ok

# 4f. a prefix that is unique by NAME alone still resolves (svc-alpha-two only, since "svc-alpha"
# itself does not start with the longer "svc-alpha-").
out2="$(resolve svc-alpha-)"
[ "$out2" = "svc-alpha-two" ] || fail "unique prefix 'svc-alpha-' should resolve to svc-alpha-two, got: $out2"
ok

# 4g. ambiguous prefix: "svc-" ties svc-alpha, svc-beta, svc-gamma, and svc-alpha-two all at once.
set +e
err="$(resolve svc- 2>&1 1>/dev/null)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "prefix 'svc-' ties four names and must be refused as ambiguous"
printf '%s' "$err" | grep -qi "ambiguous" || fail "ambiguous prefix refusal should say so, got: $err"
printf '%s' "$err" | grep -q "svc-alpha-two" || fail "ambiguous prefix candidates should list svc-alpha-two"
ok

# 4h. exact-tier ambiguity (two DIFFERENT projects registered under the identical name) refuses
# WITHOUT ever considering alias/prefix tiers, even though no alias/prefix tie exists for "dup-name".
set +e
err="$(resolve dup-name 2>&1 1>/dev/null)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "an exact-name collision across two rows must be refused as ambiguous"
printf '%s' "$err" | grep -qi "ambiguous" || fail "exact-tier ambiguity should say so, got: $err"
ok

# 4i. no match at any tier: refuses (exit 1) and lists what IS registered.
set +e
err="$(resolve zzz-nope 2>&1 1>/dev/null)"; rc=$?
set -e
[ "$rc" -eq 1 ] || fail "no match should exit 1 (not the ambiguous exit 2), got rc=$rc"
printf '%s' "$err" | grep -q "svc-alpha" || fail "no-match refusal should list registered projects"
ok

# ── 5. usage / empty-registry edges ───────────────────────────────────────────────────────────
set +e
out="$(HERD_FLEET_FILE="$REG2" bash "$HERD" fleet resolve 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "resolve with no argument should fail loudly"
printf '%s' "$out" | grep -qi "usage" || fail "missing-argument error should show usage"
ok

set +e
out="$(HERD_FLEET_FILE="$T/none/fleet" bash "$HERD" fleet resolve anything 2>&1)"; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "resolve against an empty/missing registry should fail"
printf '%s' "$out" | grep -qi "register" || fail "empty-registry refusal should point at 'herd fleet register'"
ok

out="$(HERD_FLEET_FILE="$REG2" bash "$HERD" fleet resolve --help)"
printf '%s' "$out" | grep -qi "precedence\|exact" || fail "--help should describe the precedence"
ok

echo "ALL PASS ($pass checks)"
