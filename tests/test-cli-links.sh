#!/usr/bin/env bash
# test-cli-links.sh — hermetic, network-free tests for the .herd/links registry:
# `herd link list` and `herd report --to <name>`. Fake `gh` on PATH; no network.
# Run:  bash tests/test-cli-links.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

# ── Test project with a two-entry .herd/links ────────────────────────────────────────────────────
P="$T/proj"
mkdir -p "$P/.herd"
cat > "$P/.herd/config" <<EOF
PROJECT_ROOT="$P"
WORKSPACE_NAME="myapp"
SCRIBE_BACKEND="file"
HERD_REPO="owner/myapp"
EOF

cat > "$P/.herd/links" <<'EOF'
# .herd/links — test registry
# name|owner/repo|backend|tracker_target
engine|acme/engine-repo|github|
ci|myorg/ci-platform|github|
EOF

# Fake gh: logs args to GHLOG; issue list returns []; issue create returns a URL.
GHLOG="$T/gh.log"
mkdir -p "$T/bin"
cat > "$T/bin/gh" <<EOF
#!/usr/bin/env bash
echo "gh \$*" >> "$GHLOG"
case "\$1 \$2" in
  "issue create") echo "https://github.com/example/example/issues/1" ;;
  "issue list")   echo '[]' ;;
  *) : ;;
esac
EOF
chmod +x "$T/bin/gh"

run_herd() {
  ( cd "$P" \
      && PATH="$T/bin:$PATH" \
         HERD_CONFIG_FILE="$P/.herd/config" \
         HERD_NONINTERACTIVE=1 \
         bash "$HERD" "$@" )
}

# ── 1. herd link list shows both entries ─────────────────────────────────────────────────────────
out="$(run_herd link list 2>&1)" || fail "link list exited non-zero: $out"
echo "$out" | grep -q "engine" || fail "link list did not show 'engine' entry — got: $out"
echo "$out" | grep -q "acme/engine-repo" || fail "link list did not show repo for 'engine' — got: $out"
echo "$out" | grep -q "ci" || fail "link list did not show 'ci' entry — got: $out"
echo "$out" | grep -q "myorg/ci-platform" || fail "link list did not show repo for 'ci' — got: $out"
pass

# ── 2. herd link (no subcommand) defaults to list ────────────────────────────────────────────────
out2="$(run_herd link 2>&1)" || fail "herd link (no args) exited non-zero: $out2"
echo "$out2" | grep -q "engine" || fail "herd link (no args) did not default to list — got: $out2"
pass

# ── 3. herd link list with no .herd/links file shows a helpful message ──────────────────────────
P2="$T/proj2"; mkdir -p "$P2/.herd"
cat > "$P2/.herd/config" <<EOF
PROJECT_ROOT="$P2"
WORKSPACE_NAME="bare"
EOF
out3="$( cd "$P2" \
           && PATH="$T/bin:$PATH" \
              HERD_CONFIG_FILE="$P2/.herd/config" \
              HERD_NONINTERACTIVE=1 \
              bash "$HERD" link list 2>&1 )" \
  || fail "link list (no links file) exited non-zero: $out3"
echo "$out3" | grep -qi "no .herd/links" \
  || fail "link list did not say 'no .herd/links' for a bare project — got: $out3"
pass

# ── 4. herd report --to engine routes to acme/engine-repo ────────────────────────────────────────
: > "$GHLOG"
out4="$(run_herd report --to engine "something is broken" 2>&1)" \
  || fail "report --to engine exited non-zero: $out4"
grep -q "issue list -R acme/engine-repo" "$GHLOG" \
  || fail "report --to engine did not dedup-check against acme/engine-repo — log: $(cat "$GHLOG")"
grep -q "issue create -R acme/engine-repo" "$GHLOG" \
  || fail "report --to engine did not file against acme/engine-repo — log: $(cat "$GHLOG")"
grep -q -- "--title \[myapp\] something is broken" "$GHLOG" \
  || fail "report --to engine did not stamp the local project name into the title — log: $(cat "$GHLOG")"
pass

# ── 5. herd report --to=ci (equals-form) routes to myorg/ci-platform ─────────────────────────────
: > "$GHLOG"
out5="$(run_herd report --to=ci "deploy pipeline stalled" 2>&1)" \
  || fail "report --to=ci exited non-zero: $out5"
grep -q "issue create -R myorg/ci-platform" "$GHLOG" \
  || fail "report --to=ci did not file against myorg/ci-platform — log: $(cat "$GHLOG")"
pass

# ── 6. herd report --to unknown-link → loud error, non-zero ─────────────────────────────────────
if run_herd report --to no-such-link "something" >/dev/null 2>&1; then
  fail "report --to unknown-link should exit non-zero"
fi
pass

# ── 7. herd report (no --to) still targets the project's own HERD_REPO ──────────────────────────
: > "$GHLOG"
out7="$(run_herd report "vanilla report" 2>&1)" || fail "plain report exited non-zero: $out7"
grep -q "issue list -R owner/myapp" "$GHLOG" \
  || fail "plain report (no --to) did not dedup against project HERD_REPO — log: $(cat "$GHLOG")"
grep -q "issue create -R owner/myapp" "$GHLOG" \
  || fail "plain report (no --to) did not file against project HERD_REPO — log: $(cat "$GHLOG")"
pass

echo "ALL PASS ($PASS checks)"
