#!/usr/bin/env bash
# test-cli-report.sh — hermetic, network-free test of the `herd report` subcommand. It loads a
# project's .herd/config, routes through the report backend's _backend_add_item (NOT a hardcoded
# `gh issue create`), and dedups against _backend_list_open before filing. A FAKE `gh` on PATH logs
# every call and returns canned output keyed on "<noun> <verb>", so we assert CALL SHAPE + dedup
# decisions without touching the network. Mirrors tests/test-backend-github.sh / test-cli-backlog.sh.
# Run:  bash tests/test-cli-report.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ── A temp project whose report backend is github but whose OWN tracker (SCRIBE_BACKEND) is file:
# proving `herd report` routes on HERD_REPORT_BACKEND independently of SCRIBE_BACKEND. ───────────
P="$T/proj"
mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="widgets"
SCRIBE_BACKEND="file"
HERD_REPO="acme/widgets"
HERD_REPORT_BACKEND="github"
EOF

# Fake gh: logs args; `issue list` returns whatever JSON is staged in $T/open.json (default []).
GHLOG="$T/gh.log"
mkdir -p "$T/bin"
echo '[]' > "$T/open.json"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue create") echo "https://github.com/acme/widgets/issues/99" ;;
  "issue list")   cat "$T/open.json" 2>/dev/null || echo '[]' ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"

SYMPTOM="scribe lane drops the receipt"   # → title "[widgets] scribe lane drops the receipt"

# run_report [extra env assignments...] -- <symptom>
# Always non-interactive + fake-gh on PATH + config pinned to the temp project.
run_report() {
  ( cd "$P" \
      && PATH="$T/bin:$PATH" \
         HERD_CONFIG_FILE="$P/.herd/config" \
         HERD_NONINTERACTIVE=1 \
         env "$@" bash "$HERD" report "$SYMPTOM" )
}

# ── (a) No open match → routes through _backend_add_item (gh issue create on HERD_REPO) ─────────
: > "$GHLOG"; echo '[]' > "$T/open.json"
out="$(run_report 2>&1)" || fail "report (no-match) exited non-zero: $out"
grep -q -- "issue list -R acme/widgets --state open" "$GHLOG" \
  || fail "report did not dedup-check via _backend_list_open (gh issue list on HERD_REPO)"
grep -q -- "issue create -R acme/widgets" "$GHLOG" \
  || fail "report did not file via _backend_add_item (gh issue create -R acme/widgets) — ($out)"
grep -q -- "--title \[widgets\] scribe lane drops the receipt" "$GHLOG" \
  || fail "report did not stamp the project name into the title"
pass

# ── (b) A matching open item present → dedup HOLDS in non-interactive mode (NO add) ─────────────
: > "$GHLOG"
printf '%s' '[{"number":12,"title":"[widgets] scribe lane drops the receipt sometimes"}]' > "$T/open.json"
out="$(run_report 2>&1)" || fail "report (dup) should hold cleanly (exit 0), got non-zero: $out"
grep -q -- "issue create" "$GHLOG" \
  && fail "report filed a likely-dup in non-interactive mode (should HOLD) — ($out)"
echo "$out" | grep -qi "duplicate" || fail "report did not surface the duplicate candidate(s) — ($out)"
echo "$out" | grep -q "HERD_REPORT_FORCE=1" || fail "report did not hint at HERD_REPORT_FORCE=1 — ($out)"
echo "$out" | grep -q "scribe lane drops the receipt sometimes" \
  || fail "report did not print the matching open candidate — ($out)"
pass

# ── (b') HERD_REPORT_FORCE=1 overrides the hold and files anyway ────────────────────────────────
: > "$GHLOG"   # open.json still holds the matching item
out="$(run_report HERD_REPORT_FORCE=1 2>&1)" || fail "report --force exited non-zero: $out"
grep -q -- "issue create -R acme/widgets" "$GHLOG" \
  || fail "HERD_REPORT_FORCE=1 did not file over the dup — ($out)"
pass

# ── (c) No match (unrelated open item) → it files ───────────────────────────────────────────────
: > "$GHLOG"
printf '%s' '[{"number":3,"title":"[widgets] dark mode toggle missing"}]' > "$T/open.json"
out="$(run_report 2>&1)" || fail "report (unrelated open item) exited non-zero: $out"
grep -q -- "issue create -R acme/widgets" "$GHLOG" \
  || fail "report should file when no open item is a likely duplicate — ($out)"
pass

# ── (d) Unknown HERD_REPORT_BACKEND → loud error, non-zero ──────────────────────────────────────
if run_report HERD_REPORT_BACKEND=nope-not-a-backend >/dev/null 2>&1; then
  fail "report should fail loudly on an unknown HERD_REPORT_BACKEND"
fi
pass

echo "ALL PASS ($PASS checks)"
