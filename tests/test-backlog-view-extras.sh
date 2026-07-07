#!/usr/bin/env bash
# test-backlog-view-extras.sh — hermetic, network-free test of backlog-view.sh's optional
# BACKLOG_VIEW_EXTRAS=github-issues incoming section (HERD-15).
#
# When .herd/config sets BACKLOG_VIEW_EXTRAS=github-issues the backlog viewer renders a SECOND,
# clearly-labeled '📥 incoming (github issues)' section BENEATH the primary work queue, listing this
# repo's open GitHub issues via `gh issue list`. It is STRICTLY additive & view-only: it never merges
# into the primary list and never feeds `herd backlog`/work-selection. It fails SOFT (no-false-red):
# any gh error renders one dim 'incoming unavailable' line, never a red row, never a secret leak, and
# never breaks the primary section. Off/unset → byte-identical to before (gh never invoked).
#
# This stubs BOTH `gh` and `herd` with FAKE bins on PATH (no network) and drives the script through
# the BACKLOG_VIEW_MAX_POLLS test hook (backend mode) or a brief background run (file mode).
#
# Coverage:
#   1. file-mode + extras   — primary backlog file + the '📥 incoming' section with issue titles.
#   2. off is byte-identical — extras unset → NO incoming section AND `gh` is NEVER invoked.
#   3. backend-mode + extras — linear primary list + the '📥 incoming' section beneath it.
#   4. gh error fails soft  — a failing `gh` → dim 'incoming unavailable', primary intact, no leak.
#
# Run:  bash tests/test-backlog-view-extras.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../scripts/herd/backlog-view.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
GHLOG="$T/gh.log"
HERDLOG="$T/herd.log"

# ── Portability shims (HERD-53) ───────────────────────────────────────────────────────────────────
# env -i below is deliberately hermetic, but on Git Bash that bites twice: python3 lives under AppData
# (off the fixed PATH) so backlog-view.sh's bare `python3` (rich_to_md) can't resolve, and env -i
# strips LANG/LC_* so the emoji grep assertions run byte-blind. Resolve the real python3 once (pre
# env -i, like scripts/herd/healthcheck.sh) and shim it into $BIN, and pin a UTF-8 locale (fallback C)
# in every env -i. Both are no-ops on Linux — python3 already sits on the fixed PATH and the shimmed
# output is byte-identical.
PY="$(command -v python3 || true)"
[ -n "$PY" ] && { printf '#!/usr/bin/env bash\nexec "%s" "$@"\n' "$PY" > "$BIN/python3"; chmod +x "$BIN/python3"; }
UTF8_LOCALE=C; [ "$(LC_ALL=C.UTF-8 locale charmap 2>/dev/null)" = "UTF-8" ] && UTF8_LOCALE=C.UTF-8

# FAKE `gh` — logs every call. For `issue list` it emits scripted output ($GH_FAKE_OUT), unless
# GH_FAKE_FAIL is set: then it writes a fake API error INCLUDING a secret to STDERR and exits 1
# (the fail-soft / no-secret-leak path). Any other subcommand is a harmless no-op.
cat > "$BIN/gh" <<'FAKE'
#!/usr/bin/env bash
echo "gh $*" >> "$GH_FAKE_LOG"
if [ "${1:-}" = "issue" ] && [ "${2:-}" = "list" ]; then
  if [ -n "${GH_FAKE_FAIL:-}" ]; then
    echo "HTTP 401: Bad credentials — Authorization: token gho_LEAKED-SECRET-TOKEN" >&2
    exit 1
  fi
  printf '%s\n' "${GH_FAKE_OUT:-}"
  exit 0
fi
exit 0
FAKE
chmod +x "$BIN/gh"

# FAKE `herd` — logs calls; for `backlog` emits $HERD_FAKE_OUT (backend-mode primary list).
cat > "$BIN/herd" <<'FAKE'
#!/usr/bin/env bash
echo "herd $*" >> "$HERD_FAKE_LOG"
[ "${1:-}" = "backlog" ] || exit 0
printf '%s\n' "${HERD_FAKE_OUT:-}"
FAKE
chmod +x "$BIN/herd"

make_project() {
  local dir="$1" backend="$2" extras="$3"
  mkdir -p "$dir/.herd"
  cat > "$dir/.herd/config" <<EOF
PROJECT_ROOT="$dir"
WORKSPACE_NAME="testws"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="$backend"
BACKLOG_VIEW_EXTRAS="$extras"
EOF
}

# run_view <project-dir> [extra env KEY=VAL ...] — backend-mode driver (has the MAX_POLLS hook).
run_view() {
  local dir="$1"; shift
  env -i LC_ALL="$UTF8_LOCALE" HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$dir/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    HERD_FAKE_LOG="$HERDLOG" GH_FAKE_LOG="$GHLOG" "$@" \
    bash "$SCRIPT" 2>/dev/null </dev/null
}

# run_view_file <project-dir> <outfile> [extra env ...] — file-mode driver: the historical file loop
# has no MAX_POLLS hook (byte-identical to before), so run it briefly in the background then stop.
run_view_file() {
  local dir="$1" out="$2"; shift 2
  env -i LC_ALL="$UTF8_LOCALE" HOME="$HOME" PATH="$BIN:/usr/bin:/bin:/usr/sbin:/sbin" TERM=xterm \
    HERD_CONFIG_FILE="$dir/.herd/config" HERD_ALLOW_FOREIGN_CWD=1 \
    HERD_FAKE_LOG="$HERDLOG" GH_FAKE_LOG="$GHLOG" "$@" \
    bash "$SCRIPT" </dev/null >"$out" 2>/dev/null & local vpid=$!
  sleep 1; kill "$vpid" 2>/dev/null; wait "$vpid" 2>/dev/null
}

# ── Case 1: file backend + extras=github-issues — primary file + incoming section ────────────────
P1="$T/proj-file-x"; make_project "$P1" "file" "github-issues"
git -C "$P1" init -q; git -C "$P1" config user.email t@t.t; git -C "$P1" config user.name t
cat > "$P1/BACKLOG.md" <<'EOF'
# proj — backlog
## Now
- 🔜 primary-queue-item
EOF
git -C "$P1" add -A; git -C "$P1" commit -q -m init
: > "$GHLOG"; : > "$HERDLOG"
run_view_file "$P1" "$T/out1" GH_FAKE_OUT="#42 incoming-issue-alpha"
grep -q "📋 BACKLOG.md" "$T/out1"              || fail "file+extras: primary header missing"
grep -q "primary-queue-item" "$T/out1"         || fail "file+extras: primary backlog content missing"
grep -q "📥 incoming (github issues)" "$T/out1" || fail "file+extras: incoming section header missing"
grep -q "incoming-issue-alpha" "$T/out1"       || fail "file+extras: incoming issue title missing"
grep -q "gh issue list" "$GHLOG"               || fail "file+extras: did not invoke 'gh issue list'"
# additive: the issue must not have been folded into the primary markdown list as a work item.
grep -q "🔜.*incoming-issue-alpha" "$T/out1"    && fail "file+extras: issue leaked into the primary work queue"
pass

# ── Case 2: extras OFF is byte-identical — no incoming section AND gh never invoked ───────────────
P2="$T/proj-file-off"; make_project "$P2" "file" ""
git -C "$P2" init -q; git -C "$P2" config user.email t@t.t; git -C "$P2" config user.name t
cat > "$P2/BACKLOG.md" <<'EOF'
# proj — backlog
## Now
- 🔜 off-mode-item
EOF
git -C "$P2" add -A; git -C "$P2" commit -q -m init
: > "$GHLOG"; : > "$HERDLOG"
run_view_file "$P2" "$T/out2" GH_FAKE_OUT="#99 should-never-appear"
grep -q "off-mode-item" "$T/out2"               || fail "off-mode: primary backlog content missing"
grep -q "📥 incoming" "$T/out2"                  && fail "off-mode: incoming section rendered while extras is off"
grep -q "should-never-appear" "$T/out2"          && fail "off-mode: gh output leaked while extras is off"
if [ -s "$GHLOG" ]; then fail "off-mode must NOT invoke gh (log: $(cat "$GHLOG"))"; fi
pass

# ── Case 3: linear backend + extras=github-issues — primary list + incoming section ──────────────
P3="$T/proj-linear-x"; make_project "$P3" "linear" "github-issues"
: > "$GHLOG"; : > "$HERDLOG"
out3="$(run_view "$P3" BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0 \
        HERD_FAKE_OUT="#ABC-1 planned-linear-ticket" GH_FAKE_OUT="#7 incoming-issue-beta")"
grep -q "planned-linear-ticket" <<<"$out3"        || fail "linear+extras: primary open list missing"
grep -q "📥 incoming (github issues)" <<<"$out3"   || fail "linear+extras: incoming section header missing"
grep -q "incoming-issue-beta" <<<"$out3"          || fail "linear+extras: incoming issue title missing"
grep -q "herd backlog" "$HERDLOG"                 || fail "linear+extras: primary still sourced from 'herd backlog'"
grep -q "gh issue list" "$GHLOG"                  || fail "linear+extras: did not invoke 'gh issue list'"
pass

# ── Case 4: gh error fails SOFT — quiet note, primary intact, no red, no secret leak ─────────────
P4="$T/proj-linear-ghfail"; make_project "$P4" "linear" "github-issues"
: > "$GHLOG"; : > "$HERDLOG"
out4="$(run_view "$P4" BACKLOG_VIEW_MAX_POLLS=1 BACKLOG_VIEW_POLL_SECS=0 \
        HERD_FAKE_OUT="#ABC-2 still-here-ticket" GH_FAKE_FAIL=1)"
grep -q "still-here-ticket" <<<"$out4"            || fail "gh-fail: primary list was broken by a gh error"
grep -q "📥 incoming (github issues)" <<<"$out4"   || fail "gh-fail: incoming header should still render"
grep -q "incoming unavailable" <<<"$out4"         || fail "gh-fail: missing quiet 'incoming unavailable' note"
grep -q "gho_LEAKED-SECRET-TOKEN" <<<"$out4"      && fail "SECRET LEAK: gh error body reached the pane"
grep -q "Bad credentials" <<<"$out4"              && fail "gh-fail: raw error body must be sanitized, not shown"
pass

echo "ALL PASS ($PASS checks)"
