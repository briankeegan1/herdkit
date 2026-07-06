#!/usr/bin/env bash
# test-cli-backlog.sh — hermetic, network-free test of the `herd backlog` subcommand: it loads a
# project's .herd/config, sources the active SCRIBE_BACKEND, and prints _backend_list_open's output
# (the same "#<id> <title>" line shape every backend emits). No real gh, no network, no repo writes.
# Mirrors tests/test-backend-github.sh's FAKE-`gh`-on-PATH approach.
# Run:  bash tests/test-cli-backlog.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ── Case 1: github backend — `herd backlog` drains the issue tracker via a FAKE gh ──────────────
# Build a temp project whose config selects SCRIBE_BACKEND=github. A stub `gh` on PATH logs its
# args and returns a canned `issue list` JSON, so we assert that `herd backlog` sourced the github
# backend and printed _backend_list_open's parsed lines — without touching the network.
P1="$T/proj-github"
mkdir -p "$P1/.herd"
cat > "$P1/.herd/config" <<EOF
PROJECT_ROOT="$P1"
SCRIBE_BACKEND="github"
HERD_REPO="acme/widgets"
EOF

GHLOG="$T/gh.log"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue list") printf '%s' '[{"number":7,"title":"first open issue"},{"number":9,"title":"second open issue"}]' ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"

out="$( cd "$P1" && PATH="$T/bin:$PATH" bash "$HERD" backlog )" || fail "herd backlog (github) exited non-zero"
echo "$out" | grep -q "^#7 first open issue$"  || fail "github backlog missing '#7 first open issue' ($out)"
echo "$out" | grep -q "^#9 second open issue$" || fail "github backlog missing '#9 second open issue'"
grep -q -- "issue list -R acme/widgets --state open" "$GHLOG" \
  || fail "herd backlog did not invoke the github backend's 'gh issue list --state open' on HERD_REPO"
pass

# ── Case 2: file backend — `herd backlog` greps the configured BACKLOG_FILE ──────────────────────
# Backend-agnostic: a file-backend project surfaces its 🔜/🚧 lines, no external tool needed.
P2="$T/proj-file"
mkdir -p "$P2/.herd"
cat > "$P2/.herd/config" <<EOF
PROJECT_ROOT="$P2"
SCRIBE_BACKEND="file"
BACKLOG_FILE="BACKLOG.md"
EOF
cat > "$P2/BACKLOG.md" <<'EOF'
# proj — backlog
## Now
- 🚧 wiring the feedback loop
## Next
- 🔜 add a dark-mode toggle
## Recently shipped
- ✅ already done (should NOT list)
EOF
out2="$( cd "$P2" && bash "$HERD" backlog )" || fail "herd backlog (file) exited non-zero"
echo "$out2" | grep -q "🚧 wiring the feedback loop" || fail "file backlog missing the 🚧 in-progress line ($out2)"
echo "$out2" | grep -q "🔜 add a dark-mode toggle"   || fail "file backlog missing the 🔜 planned line"
echo "$out2" | grep -q "already done"                && fail "file backlog should not list ✅ shipped items"
pass

# ── Case 2b: --rich on a backend with no rich op (file) → falls back to the plain list ──────────
out2b="$( cd "$P2" && bash "$HERD" backlog --rich )" || fail "herd backlog --rich (file) exited non-zero"
[ "$out2b" = "$out2" ] || fail "--rich on the file backend must serve the plain list unchanged ($out2b)"
pass

# ── Case 2c: show on a backend with no detail op (file) → greps the plain list for the ref ──────
out2c="$( cd "$P2" && bash "$HERD" backlog show "dark-mode" )" || fail "herd backlog show (file) exited non-zero"
echo "$out2c" | grep -q "add a dark-mode toggle" || fail "show fallback did not surface the matching open line ($out2c)"
if ( cd "$P2" && bash "$HERD" backlog show "no-such-item" ) >/dev/null 2>&1; then
  fail "show with no matching item should exit non-zero"
fi
pass

# ── Case 2d: browse without fzf → soft fallback: plain list on stdout + install hint on stderr ──
# PATH is restricted so fzf can never be found even on a dev machine that has it installed.
out2d="$( cd "$P2" && env PATH="/usr/bin:/bin:/usr/sbin:/sbin" bash "$HERD" backlog browse 2>"$T/browse.err" )" \
  || fail "herd backlog browse (no fzf) exited non-zero"
echo "$out2d" | grep -q "🔜 add a dark-mode toggle" || fail "browse fallback did not print the plain list ($out2d)"
grep -q "fzf not found" "$T/browse.err" || fail "browse fallback missing the fzf install hint on stderr"
pass

# ── Case 2e: unknown flag → loud usage error, non-zero ──────────────────────────────────────────
if ( cd "$P2" && bash "$HERD" backlog --bogus ) >/dev/null 2>&1; then
  fail "herd backlog --bogus should fail loudly with usage"
fi
pass

# ── Case 3: missing config → loud error, non-zero ────────────────────────────────────────────────
if ( cd "$T" && bash "$HERD" backlog ) >/dev/null 2>&1; then
  fail "herd backlog should fail loudly with no .herd/config"
fi
pass

# ── Case 4: unknown backend → loud error, non-zero ───────────────────────────────────────────────
P3="$T/proj-bogus"
mkdir -p "$P3/.herd"
cat > "$P3/.herd/config" <<EOF
PROJECT_ROOT="$P3"
SCRIBE_BACKEND="nope-not-a-backend"
EOF
if ( cd "$P3" && bash "$HERD" backlog ) >/dev/null 2>&1; then
  fail "herd backlog should fail loudly on an unknown SCRIBE_BACKEND"
fi
pass

echo "ALL PASS ($PASS checks)"
