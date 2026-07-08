#!/usr/bin/env bash
# test-governance-profiles.sh — hermetic tests for HERD-126 GOVERNANCE PROFILES: export/apply a
# project's governance as a portable, versioned artifact.
#
# What's under test:
#   (1) ROUND-TRIP — export from a configured fixture, apply --yes to a blank fixture; the effective
#       governance keys are EQUAL, and secrets / machine-scoped keys are ABSENT from the profile and
#       never written to the target.
#   (2) STRUCTURAL EXCLUSION — a MACHINE-scoped or SECRET-shaped key never travels, even when the
#       capabilities manifest MIS-TAGS it `governance` (exclusion is enforced in code, not trusted).
#   (3) MALFORMED PROFILE → LOUD REFUSAL, ZERO PARTIAL WRITES — missing/unsupported version marker, a
#       non-governance key, and a shell-active value each abort apply with the target config untouched;
#       critically, a profile whose FIRST key is valid but a LATER line is bad writes NOTHING.
#   (4) COMPOSE — decline-all (interactive) leaves .herd/config byte-identical; `herd init --governance`
#       seeds a fresh install, and a malformed --governance profile aborts init before any write.
#
# Fully hermetic: local temp only, NO herdr, NO gh, NO network, NO model. `herd governance apply`
# defers the watcher-restart/re-render (HERD_INIT_DEFER_APPLY, applied internally) so no control room
# is needed. The interactive decline is driven via the HERD_GROUND_ASSUME_TTY seam. python3 is a herd
# hard dep (herd doctor verifies it), the same reliance as the sibling config-docs tests.
# Run:  bash tests/test-governance-profiles.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERDKIT_HOME="$REPO"

command -v git >/dev/null 2>&1 || { echo "FAIL: git required" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
REAL_BASH="$(command -v bash)"
# Restricted PATH so the grounding interview (init test) is deterministic and claude/graphify are absent.
SAFE="/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { PASS=$((PASS+1)); }

# mkcfg <dir> — a throwaway project with a minimal .herd/config (no full init needed for export/apply).
mkcfg() {
  local d="$1"; rm -rf "$d"; mkdir -p "$d/.herd"; git -C "$d" init -q
  cat > "$d/.herd/config" <<EOF
PROJECT_ROOT="$d"
WORKTREES_DIR="$d-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="$(basename "$d")"
MERGE_POLICY="auto"
EOF
}

# ── (1) ROUND-TRIP: export configured → apply blank → effective governance keys equal ─────────────
SRC="$T/src"; rm -rf "$SRC"; mkdir -p "$SRC/.herd"; git -C "$SRC" init -q
cat > "$SRC/.herd/config" <<EOF
PROJECT_ROOT="$SRC"
WORKTREES_DIR="$SRC-trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="src"
MERGE_POLICY="approve"
MERGE_METHOD="squash"
PUSH_GATE="human"
COMMIT_CONVENTION="^(feat|fix|docs): .+"
EOF
# a machine-scoped key lands in the per-user overlay — it must NOT travel in the profile.
printf 'MODEL_FEATURE="claude-opus-4-8"\n' > "$SRC/.herd/config.local"

PROF="$T/profile.txt"
( cd "$SRC" && "$HERD" governance export --file "$PROF" ) >/dev/null 2>&1 || fail "(1) export failed"
[ -f "$PROF" ] || fail "(1) export did not write the profile file"
grep -qx 'HERD_GOVERNANCE_PROFILE=1' "$PROF"          || fail "(1) profile missing the version marker"
grep -qE '^MERGE_METHOD="squash"$'   "$PROF"          || fail "(1) MERGE_METHOD not exported"
grep -qE '^PUSH_GATE="human"$'       "$PROF"          || fail "(1) PUSH_GATE not exported"
grep -qE '^COMMIT_CONVENTION='       "$PROF"          || fail "(1) COMMIT_CONVENTION not exported"
# Scope the exclusion checks to KEY=VALUE assignment lines — the header prose legitimately says "secrets".
grep -E '^[A-Za-z_]+=' "$PROF" | grep -q 'MODEL_FEATURE'           && fail "(1) machine-scoped MODEL_FEATURE must NOT travel"
grep -E '^[A-Za-z_]+=' "$PROF" | grep -qiE 'SECRET|TOKEN|API_?KEY' && fail "(1) no secret-shaped key may appear in a profile"

DST="$T/dst"; mkcfg "$DST"
( cd "$DST" && "$HERD" governance apply --yes "$PROF" ) >/dev/null 2>&1 || fail "(1) apply --yes failed"
dcfg="$DST/.herd/config"
grep -qE '^MERGE_POLICY="approve"$'      "$dcfg" || fail "(1) MERGE_POLICY not applied (got: $(grep MERGE_POLICY "$dcfg"))"
grep -qE '^MERGE_METHOD="squash"$'       "$dcfg" || fail "(1) MERGE_METHOD not applied"
grep -qE '^PUSH_GATE="human"$'           "$dcfg" || fail "(1) PUSH_GATE not applied"
grep -qE '^COMMIT_CONVENTION="\^\(feat\|fix\|docs\): \.\+"$' "$dcfg" || fail "(1) COMMIT_CONVENTION not applied verbatim"
grep -q 'MODEL_FEATURE' "$dcfg" "$DST/.herd/config.local" 2>/dev/null && fail "(1) machine key must never reach the target"
ok
echo "PASS (1) round-trip: export → apply, effective governance keys equal; secrets/machine keys absent"

# ── (2) STRUCTURAL EXCLUSION: machine/secret keys never travel even if MIS-TAGGED governance ───────
MISTAG="$T/caps-mistag.tsv"
python3 - "$REPO/templates/capabilities.tsv" "$MISTAG" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
rows = open(src, encoding="utf-8").read().split("\n")
out = []
for r in rows:
    f = r.split("\t")
    if len(f) >= 2 and f[1] == "config" and f[0] == "MODEL_FEATURE":
        while len(f) < 7: f.append("")
        f[6] = "governance"          # MIS-TAG a machine-scoped key
        r = "\t".join(f)
    out.append(r)
out.append("MY_API_KEY\tconfig\tbogus\twhen\twatcher\t\tgovernance")   # MIS-TAG a secret-shaped key
open(dst, "w", encoding="utf-8").write("\n".join(out))
PY
printf 'MODEL_FEATURE="claude-x"\n' >> "$SRC/.herd/config"   # set it in the baseline so it COULD leak
mtout="$( cd "$SRC" && HERD_CAPABILITIES_FILE="$MISTAG" "$HERD" governance export 2>/dev/null )" || fail "(2) export failed"
printf '%s\n' "$mtout" | grep -qE '^MODEL_FEATURE=' && fail "(2) machine key leaked despite mis-tag"
printf '%s\n' "$mtout" | grep -qE '^MY_API_KEY='    && fail "(2) secret-shaped key leaked despite mis-tag"
printf '%s\n' "$mtout" | grep -qE '^MERGE_POLICY='  || fail "(2) legit governance key should still export"
ok
echo "PASS (2) machine/secret keys excluded even when the manifest mis-tags them governance"

# ── (3) MALFORMED PROFILE → LOUD REFUSAL, ZERO PARTIAL WRITES ─────────────────────────────────────
REF="$T/ref"; mkcfg "$REF"; refcfg="$REF/.herd/config"
baseline="$(cat "$refcfg")"
assert_untouched() { [ "$(cat "$refcfg")" = "$baseline" ] || fail "$1: config was mutated on a refusal"; }

# (a) missing version marker
printf 'MERGE_POLICY="approve"\n' > "$T/bad-nomarker.txt"
( cd "$REF" && "$HERD" governance apply --yes "$T/bad-nomarker.txt" ) >/dev/null 2>&1 && fail "(3a) missing marker must be refused"
assert_untouched "(3a)"
# (b) valid FIRST key then a non-governance key → the whole profile is refused, NOTHING written
printf 'HERD_GOVERNANCE_PROFILE=1\nMERGE_POLICY="approve"\nWORKSPACE_NAME="hijack"\n' > "$T/bad-nongov.txt"
( cd "$REF" && "$HERD" governance apply --yes "$T/bad-nongov.txt" ) >/dev/null 2>&1 && fail "(3b) non-governance key must be refused"
grep -qE '^MERGE_POLICY="approve"$' "$refcfg" && fail "(3b) a partial write leaked the valid first key"
assert_untouched "(3b)"
# (c) shell-active value
printf 'HERD_GOVERNANCE_PROFILE=1\nMERGE_POLICY="a$(id)"\n' > "$T/bad-shell.txt"
( cd "$REF" && "$HERD" governance apply --yes "$T/bad-shell.txt" ) >/dev/null 2>&1 && fail "(3c) shell-active value must be refused"
assert_untouched "(3c)"
# (d) unsupported version
printf 'HERD_GOVERNANCE_PROFILE=99\nMERGE_POLICY="approve"\n' > "$T/bad-ver.txt"
( cd "$REF" && "$HERD" governance apply --yes "$T/bad-ver.txt" ) >/dev/null 2>&1 && fail "(3d) unsupported version must be refused"
assert_untouched "(3d)"
ok
echo "PASS (3) malformed profiles (no/bad marker, non-gov key, shell-active value) refused with zero writes"

# ── (4a) DECLINE-ALL (interactive) leaves config untouched ────────────────────────────────────────
DEC="$T/decline"; mkcfg "$DEC"; deccfg="$DEC/.herd/config"; decbase="$(cat "$deccfg")"
# 4 governance keys in the profile → 4 'n' answers decline every proposal (no --yes).
out="$( cd "$DEC" && printf 'n\nn\nn\nn\n' \
        | PATH="$SAFE" HERD_GROUND_ASSUME_TTY=1 "$REAL_BASH" "$HERD" governance apply "$PROF" 2>&1 )" \
        || fail "(4a) interactive apply failed: $out"
[ "$(cat "$deccfg")" = "$decbase" ]                     || fail "(4a) decline-all mutated the config"
printf '%s\n' "$out" | grep -q "nothing applied"        || fail "(4a) decline-all should report nothing applied"
ok
echo "PASS (4a) decline-all (interactive) leaves .herd/config byte-identical"

# ── (4b) herd init --governance seeds a fresh install; a malformed --governance aborts init ────────
INITP="$T/initproj"; rm -rf "$INITP"; mkdir -p "$INITP"; git -C "$INITP" init -q
git -C "$INITP" config user.email t@t.t; git -C "$INITP" config user.name t
: > "$INITP/package.json"; git -C "$INITP" add -A 2>/dev/null || true; git -C "$INITP" commit -q --allow-empty -m init
# stdin: grounding interview — codemap=n, mcp=blank (EOF → default). No CLAUDE.md so no adoption offer.
out="$( cd "$INITP" && printf 'n\n' \
        | PATH="$SAFE" HERD_GROUND_ASSUME_TTY=1 HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
          "$REAL_BASH" "$HERD" init --governance "$PROF" 2>&1 )" || fail "(4b) init --governance failed: $out"
icfg="$INITP/.herd/config"
grep -qE '^MERGE_POLICY="approve"$' "$icfg" || fail "(4b) init --governance did not seed MERGE_POLICY: $(grep MERGE_POLICY "$icfg")"
grep -qE '^PUSH_GATE="human"$'      "$icfg" || fail "(4b) init --governance did not seed PUSH_GATE"
printf '%s\n' "$out" | grep -q "Seeding governance from profile" || fail "(4b) init should announce the profile seeding"
# malformed --governance aborts BEFORE writing any config
BADINIT="$T/badinit"; rm -rf "$BADINIT"; mkdir -p "$BADINIT"; git -C "$BADINIT" init -q
( cd "$BADINIT" && PATH="$SAFE" HERD_SKIP_DOCTOR=1 HERD_SKIP_GH_DETECT=1 \
    "$REAL_BASH" "$HERD" init --governance "$T/bad-nomarker.txt" ) >/dev/null 2>&1 \
    && fail "(4b) init --governance with a malformed profile must abort"
[ -e "$BADINIT/.herd/config" ] && fail "(4b) a malformed --governance profile must abort init BEFORE writing config"
ok
echo "PASS (4b) herd init --governance seeds a fresh install; a malformed profile aborts before any write"

echo
echo "ALL PASS ($PASS checks) — governance profiles export/apply round-trip, exclusions, refusals, compose."
