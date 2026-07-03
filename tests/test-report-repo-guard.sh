#!/usr/bin/env bash
# test-report-repo-guard.sh — hermetic, network-free proof of the HERD_REPO fallback guard
# (external-consumer audit, Leak E / bin/herd cmd_report).
#
# Before this fix, `herd report` silently defaulted an unset HERD_REPO to the engine author's own
# repo (briankeegan1/herdkit) and filed a consumer's engine-bug reports against a stranger's repo.
# Now, for the github backend:
#   (1) a NON-herdkit project with HERD_REPO unset → REFUSES with an actionable error, and NEVER
#       attempts a `gh issue create` (least of all against briankeegan1/herdkit);
#   (1b) same when the project has no git remote at all;
#   (2) HERD_REPO set → files there, unchanged;
#   (3) the herdkit engine itself (origin resolves to briankeegan1/herdkit) with HERD_REPO unset →
#       self-targets briankeegan1/herdkit (this dogfood repo still works).
#
# A FAKE `gh` on PATH logs every call so we assert CALL SHAPE without the network. Mirrors the
# throwaway-git + fake-gh conventions of tests/test-cli-report.sh.
# Run:  bash tests/test-report-repo-guard.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v git >/dev/null 2>&1 || fail "git required"

# Fake gh: logs args; `issue list` returns [] (no dups); `issue create` returns a URL.
GHLOG="$T/gh.log"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue create") echo "https://github.com/acme/widgets/issues/99" ;;
  "issue list")   echo '[]' ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"

SYMPTOM="scribe lane drops the receipt"

# make_proj <dir> <origin-url-or-empty> [HERD_REPO_line]
# Builds a git repo with a github backend .herd/config; HERD_REPO omitted unless a line is passed.
make_proj() {
  local dir="$1" origin="$2" repo_line="${3:-}"
  mkdir -p "$dir/.herd"
  ( cd "$dir" && git init -q && git config user.email t@t && git config user.name t )
  if [ -n "$origin" ]; then ( cd "$dir" && git remote add origin "$origin" ); fi
  {
    printf 'PROJECT_ROOT="%s"\n' "$dir"
    printf 'WORKSPACE_NAME="widgets"\n'
    printf 'HERD_REPORT_BACKEND="github"\n'
    if [ -n "$repo_line" ]; then printf '%s\n' "$repo_line"; fi
  } > "$dir/.herd/config"
}

# run_report <dir> [extra env…]
run_report() {
  local dir="$1"; shift
  ( cd "$dir" \
      && PATH="$T/bin:$PATH" \
         HERD_CONFIG_FILE="$dir/.herd/config" \
         HERD_NONINTERACTIVE=1 \
         env HERD_REPO= "$@" bash "$HERD" report "$SYMPTOM" )
}

# ── (1) Non-herdkit consumer, HERD_REPO unset → REFUSE, no gh issue create ───────────────────────
P1="$T/consumer"; make_proj "$P1" "https://github.com/acme/widgets.git"
: > "$GHLOG"
if out="$(run_report "$P1" 2>&1)"; then
  fail "(1) report should REFUSE when HERD_REPO is unset in a non-herdkit repo — ($out)"
fi
echo "$out" | grep -q "HERD_REPO is not set" \
  || fail "(1) refusal missing the actionable 'HERD_REPO is not set' message — ($out)"
grep -q -- "issue create" "$GHLOG" \
  && fail "(1) report filed an issue despite the refusal (leak!) — $(cat "$GHLOG")"
grep -q -- "briankeegan1/herdkit" "$GHLOG" \
  && fail "(1) report touched briankeegan1/herdkit (the exact leak we fixed) — $(cat "$GHLOG")"
[ -s "$GHLOG" ] && fail "(1) refusal must short-circuit BEFORE any gh call — $(cat "$GHLOG")"
pass

# ── (1b) No git remote at all + HERD_REPO unset → same clean refusal ──────────────────────────────
P1b="$T/consumer-noremote"; make_proj "$P1b" ""
: > "$GHLOG"
if out="$(run_report "$P1b" 2>&1)"; then
  fail "(1b) report should REFUSE with no remote and HERD_REPO unset — ($out)"
fi
echo "$out" | grep -q "HERD_REPO is not set" || fail "(1b) refusal message missing — ($out)"
[ -s "$GHLOG" ] && fail "(1b) refusal must not call gh — $(cat "$GHLOG")"
pass

# ── (2) HERD_REPO set → files against it, unchanged behavior ─────────────────────────────────────
P2="$T/consumer-set"; make_proj "$P2" "https://github.com/acme/widgets.git" 'HERD_REPO="acme/widgets"'
: > "$GHLOG"
out="$(run_report "$P2" 2>&1)" || fail "(2) report with HERD_REPO set exited non-zero: $out"
grep -q -- "issue create -R acme/widgets" "$GHLOG" \
  || fail "(2) report did not file against the configured HERD_REPO — ($out) / $(cat "$GHLOG")"
grep -q -- "briankeegan1/herdkit" "$GHLOG" \
  && fail "(2) report leaked to briankeegan1/herdkit despite HERD_REPO being set — $(cat "$GHLOG")"
pass

# ── (3) The herdkit engine itself (origin → briankeegan1/herdkit), HERD_REPO unset → self-targets ─
P3="$T/engine"; make_proj "$P3" "https://github.com/briankeegan1/herdkit.git"
: > "$GHLOG"
out="$(run_report "$P3" 2>&1)" || fail "(3) engine self-target exited non-zero: $out"
grep -q -- "issue create -R briankeegan1/herdkit" "$GHLOG" \
  || fail "(3) engine repo did not self-target briankeegan1/herdkit — ($out) / $(cat "$GHLOG")"
pass

# ── (3b) ssh scp-form origin also recognized as the engine ──────────────────────────────────────
P3b="$T/engine-ssh"; make_proj "$P3b" "git@github.com:briankeegan1/herdkit.git"
: > "$GHLOG"
out="$(run_report "$P3b" 2>&1)" || fail "(3b) engine (ssh origin) self-target exited non-zero: $out"
grep -q -- "issue create -R briankeegan1/herdkit" "$GHLOG" \
  || fail "(3b) ssh-form origin not recognized as the engine — ($out) / $(cat "$GHLOG")"
pass

echo "ALL PASS ($PASS checks)"
