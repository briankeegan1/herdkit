#!/usr/bin/env bash
# test-pretrust.sh — hermetic test of herd_pretrust_worktree (herd-config.sh): the pre-trust seeding
# that lets a freshly-spawned builder skip Claude Code's interactive folder-trust gate. Regression
# for the ineffective PR #22 fix, which wrote an empty {} to <worktree>/.claude/settings.json on the
# wrong premise that a project-level settings file marks a folder trusted. The real marker is
# ~/.claude.json → projects["<abs-path>"].hasTrustDialogAccepted, so this verifies the seeding:
#   1. missing ~/.claude.json           → creates a valid file with the trust entry, no stray .bak
#   2. existing unrelated entries       → preserved verbatim; new entry added; one-time .bak taken
#   3. corrupt ~/.claude.json           → recovered to valid JSON with the trust entry; original .bak'd
#   4. pre-existing untrusted entry      → flag flipped true, that entry's other keys preserved
#   5. idempotent re-run (already trusted) → no change
#   6. one-time .bak                     → a later, distinct modification never overwrites the backup
#
# HARD RULE: HOME is pointed at a temp dir for every call — the real ~/.claude.json is NEVER touched
# (asserted unchanged at the end). No claude sessions, no herdr panes.
# Run:  bash tests/test-pretrust.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

# Snapshot the REAL ~/.claude.json so we can prove the test never mutates it. Size+mtime is enough.
REAL_CJ="$HOME/.claude.json"
real_stat(){ [ -f "$REAL_CJ" ] && stat -f '%z-%m' "$REAL_CJ" 2>/dev/null || stat -c '%s-%Y' "$REAL_CJ" 2>/dev/null || echo absent; }
REAL_BEFORE="$(real_stat)"

# Invoke herd_pretrust_worktree with an ISOLATED HOME. $1 = fake home dir, $2 = worktree dir.
# Sourced from a cwd with HERD_CONFIG_FILE pinned at a nonexistent file so config discovery stays
# hermetic (never walks up into the real repo).
run_pretrust() {
  ( cd "$T" && HOME="$1" HERD_CONFIG_FILE="$T/.no-config" \
      bash -c ". '$LOADER' >/dev/null 2>&1; herd_pretrust_worktree \"\$1\"" _ "$2" )
}

# The physical path Claude Code would key on (matches the function's `cd && pwd -P`).
canon(){ ( cd "$1" 2>/dev/null && pwd -P ); }

# python assert helper: assert_trusted <claude.json> <project-path>  → nonzero if not trusted / bad JSON.
assert_trusted() {
  P="$2" python3 - "$1" <<'PY' || fail "assert_trusted failed for $2 in $1"
import json, os, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert isinstance(d, dict), "root not an object"
proj = os.environ["P"]
e = d.get("projects", {}).get(proj)
assert isinstance(e, dict), "no project entry for %s" % proj
assert e.get("hasTrustDialogAccepted") is True, "hasTrustDialogAccepted not True"
PY
}

# ── 1. missing ~/.claude.json → create it; no .bak (nothing existed to back up) ──────────────────
H1="$T/h1"; mkdir -p "$H1"
WT1="$T/trees/watch-pr-display"; mkdir -p "$WT1"
run_pretrust "$H1" "$WT1"
[ -f "$H1/.claude.json" ] || fail "case1: ~/.claude.json not created"
assert_trusted "$H1/.claude.json" "$(canon "$WT1")"
[ -f "$H1/.claude.json.bak" ] && fail "case1: unexpected .bak created for a missing file" || true

# ── 2. existing unrelated entries preserved; new entry added; one-time .bak taken ────────────────
H2="$T/h2"; mkdir -p "$H2"
cat > "$H2/.claude.json" <<'EOF'
{
  "numStartups": 5,
  "oauthAccount": {"keep": "me"},
  "projects": {
    "/some/other/project": {"hasTrustDialogAccepted": true, "lastCost": 0.42}
  }
}
EOF
ORIG2="$(cat "$H2/.claude.json")"
WT2="$T/trees/feature-two"; mkdir -p "$WT2"
run_pretrust "$H2" "$WT2"
assert_trusted "$H2/.claude.json" "$(canon "$WT2")"
# Unrelated top-level keys and the other project entry must survive verbatim.
python3 - "$H2/.claude.json" <<'PY' || fail "case2: unrelated data not preserved"
import json, sys
d = json.load(open(sys.argv[1], encoding="utf-8"))
assert d["numStartups"] == 5, "top-level numStartups clobbered"
assert d["oauthAccount"] == {"keep": "me"}, "top-level oauthAccount clobbered"
o = d["projects"]["/some/other/project"]
assert o["hasTrustDialogAccepted"] is True and o["lastCost"] == 0.42, "other project entry mutated"
PY
[ -f "$H2/.claude.json.bak" ] || fail "case2: one-time .bak not created"
[ "$(cat "$H2/.claude.json.bak")" = "$ORIG2" ] || fail "case2: .bak is not the original file"

# ── 3. corrupt ~/.claude.json → recovered to valid JSON; corrupt original backed up ──────────────
H3="$T/h3"; mkdir -p "$H3"
printf 'this is not { valid json ]][[' > "$H3/.claude.json"
CORRUPT3="$(cat "$H3/.claude.json")"
WT3="$T/trees/feature-three"; mkdir -p "$WT3"
run_pretrust "$H3" "$WT3"
assert_trusted "$H3/.claude.json" "$(canon "$WT3")"   # implicitly asserts the file is valid JSON now
[ "$(cat "$H3/.claude.json.bak")" = "$CORRUPT3" ] || fail "case3: corrupt original not preserved in .bak"

# ── 4. pre-existing UNTRUSTED entry for the target → flag flipped, siblings preserved ────────────
H4="$T/h4"; mkdir -p "$H4"
WT4="$T/trees/feature-four"; mkdir -p "$WT4"
CANON4="$(canon "$WT4")"
PROJ4="$CANON4" python3 - "$H4/.claude.json" <<'PY'
import json, os, sys
json.dump({"projects": {os.environ["PROJ4"]: {"hasTrustDialogAccepted": False, "allowedTools": ["Bash"]}}},
          open(sys.argv[1], "w", encoding="utf-8"))
PY
run_pretrust "$H4" "$WT4"
assert_trusted "$H4/.claude.json" "$CANON4"
PROJ4="$CANON4" python3 - "$H4/.claude.json" <<'PY' || fail "case4: sibling key on flipped entry lost"
import json, os, sys
e = json.load(open(sys.argv[1], encoding="utf-8"))["projects"][os.environ["PROJ4"]]
assert e["allowedTools"] == ["Bash"], "allowedTools not preserved when flipping trust"
PY

# ── 5. idempotent: a second call for an already-trusted path changes nothing ──────────────────────
AFTER4="$(cat "$H4/.claude.json")"
run_pretrust "$H4" "$WT4"
[ "$(cat "$H4/.claude.json")" = "$AFTER4" ] || fail "case5: re-run mutated an already-trusted file"

# ── 6. one-time .bak: a later, DISTINCT modification must not overwrite the first backup ──────────
# Reuse H2 (its .bak == ORIG2). Trust a brand-new worktree in the same HOME → the file is modified
# again, but the backup must still be the very first original, never the post-case-2 content.
WT6="$T/trees/feature-six"; mkdir -p "$WT6"
run_pretrust "$H2" "$WT6"
assert_trusted "$H2/.claude.json" "$(canon "$WT6")"
assert_trusted "$H2/.claude.json" "$(canon "$WT2")"        # earlier seed still trusted
[ "$(cat "$H2/.claude.json.bak")" = "$ORIG2" ] || fail "case6: .bak overwritten by a later modification"

# ── HARD RULE: the real ~/.claude.json was never touched ─────────────────────────────────────────
[ "$(real_stat)" = "$REAL_BEFORE" ] || fail "the real ~/.claude.json was modified — hermeticity breach"

echo "ALL PASS"
