#!/usr/bin/env bash
# test-de-streamlit-docs.sh — hermetic proof for the docs/copy cleanup wave (audit item [P2]).
#
#   PART A — de-Streamlit / de-Python / de-northstar the EXAMPLE literals so a generic consumer is
#            not shown a single stack as the norm. Locks in that the neutralized literals
#            (`st.testing.v1.AppTest`, `.venv`, the `dividend-history` dogfood slug) are GONE from
#            the files this PR touched, while the surrounding GUIDANCE (one brief, language-agnostic
#            example) is preserved — not deleted.
#   PART B — document the WATCHER_SCOPE / WATCHER_OWNER team-mode keys. Locks in that both are proper
#            documented `config` rows in capabilities.tsv AND appear in config.example, and that the
#            documented semantics still match agent-watch.sh's inline behavior (drift guard).
#
# Fully hermetic: local file reads only. NO herdr, NO gh, NO network, NO model, NO temp state.
# Run:  bash tests/test-de-streamlit-docs.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"

CFG_EXAMPLE="$ROOT/templates/config.example"
CAPS="$ROOT/templates/capabilities.tsv"
HEALTHCHECK="$ROOT/scripts/herd/healthcheck.sh"
FEATURE="$ROOT/scripts/herd/herd-feature.sh"
QUICK="$ROOT/scripts/herd/herd-quick.sh"
AGENT_WATCH="$ROOT/scripts/herd/agent-watch.sh"

# The exact set of files this PR reworded — the neutralization assertions are SCOPED to these so a
# lingering literal in an out-of-scope file (owned by another lane) never masks a regression here.
SCOPED=("$CFG_EXAMPLE" "$CAPS" "$HEALTHCHECK" "$FEATURE" "$QUICK")

PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "${SCOPED[@]}" "$AGENT_WATCH"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# ── PART A.1 — neutralized single-stack literals are GONE from every scoped file ──────────────────
# Each pattern is a fixed string (grep -F) that leaked one stack (Streamlit / Python venv / the
# northstar finance-dashboard dogfood domain) as the norm.
for lit in "st.testing.v1.AppTest" ".venv" "dividend"; do
  for f in "${SCOPED[@]}"; do
    if grep -Fq -- "$lit" "$f"; then
      fail "(A.1) single-stack literal \"$lit\" still present in ${f#$ROOT/}"
    fi
  done
done
pass
echo "PASS (A.1) neutralized literals gone from all 5 scoped files (st.testing.v1.AppTest / .venv / dividend)"

# ── PART A.2 — the GUIDANCE survived: one brief language-agnostic example remains ─────────────────
# SHARE_LINKS still shows an example dir pair (de-Python'd), the interaction gate still shows a
# framework-neutral harness example. We assert the guidance is present, not merely that a literal left.
grep -Eq 'SHARE_LINKS.*e\.g\..*node_modules' "$CFG_EXAMPLE" \
  || fail "(A.2) config.example SHARE_LINKS lost its neutral example"
awk -F'\t' '$1=="SHARE_LINKS"{print $3}' "$CAPS" | grep -Fq 'node_modules' \
  || fail "(A.2) capabilities.tsv SHARE_LINKS row lost its neutral example"
grep -Fq 'UI test harness' "$HEALTHCHECK" \
  || fail "(A.2) healthcheck.sh interaction-gate lost its framework-neutral harness example"
grep -Fq 'UI test harness' "$CFG_EXAMPLE" \
  || fail "(A.2) config.example INTERACTION_TEST_CMD lost its framework-neutral harness example"
awk -F'\t' '$1=="INTERACTION_TEST_CMD"{print $3}' "$CAPS" | grep -Fq 'UI test harness' \
  || fail "(A.2) capabilities.tsv INTERACTION_TEST_CMD row lost its framework-neutral harness example"
# herd-feature's standalone usage example still exists (a neutral slug replaced dividend-history).
grep -Eq '^#[[:space:]]+herd-feature\.sh [a-z][a-z0-9-]+ ' "$FEATURE" \
  || fail "(A.2) herd-feature.sh lost its standalone usage example"
pass
echo "PASS (A.2) guidance preserved: neutral SHARE_LINKS + framework-neutral harness + usage example all remain"

# ── PART B.1 — WATCHER_SCOPE / WATCHER_OWNER are documented config keys ───────────────────────────
for k in WATCHER_SCOPE WATCHER_OWNER; do
  awk -F'\t' -v k="$k" '$1==k && $2=="config"{found=1} END{exit found?0:1}' "$CAPS" \
    || fail "(B.1) $k missing a 'config' row in capabilities.tsv"
  grep -q -- "$k" "$CFG_EXAMPLE" \
    || fail "(B.1) $k not documented in config.example"
done
pass
echo "PASS (B.1) WATCHER_SCOPE + WATCHER_OWNER are documented config rows in capabilities.tsv and appear in config.example"

# ── PART B.2 — documented semantics match agent-watch.sh's actual behavior (drift guard) ──────────
# Default scope 'mine' — the docs must not claim a different default than the engine reads.
grep -Fq '${WATCHER_SCOPE:-mine}' "$AGENT_WATCH" \
  || fail "(B.2) agent-watch.sh no longer defaults WATCHER_SCOPE to 'mine' — docs would drift"
awk -F'\t' '$1=="WATCHER_SCOPE"{print $3}' "$CAPS" | grep -Fq 'mine (default)' \
  || fail "(B.2) capabilities.tsv WATCHER_SCOPE row must document 'mine (default)'"
# Owner resolution order WATCHER_OWNER → WATCHER_VIEW_AUTHOR → gh api user, as coded.
grep -Fq 'WATCHER_OWNER:-' "$AGENT_WATCH" \
  || fail "(B.2) agent-watch.sh no longer reads WATCHER_OWNER as the primary owner identity"
grep -Fq 'WATCHER_VIEW_AUTHOR:-' "$AGENT_WATCH" \
  || fail "(B.2) agent-watch.sh no longer falls back to WATCHER_VIEW_AUTHOR for owner identity"
awk -F'\t' '$1=="WATCHER_OWNER"{print $3}' "$CAPS" | grep -Fq 'WATCHER_VIEW_AUTHOR' \
  || fail "(B.2) capabilities.tsv WATCHER_OWNER row must document the WATCHER_VIEW_AUTHOR fallback"
# Both keys are watcher-affecting in the manifest.
for k in WATCHER_SCOPE WATCHER_OWNER; do
  awk -F'\t' -v k="$k" '$1==k{print $5}' "$CAPS" | grep -Fq 'watcher' \
    || fail "(B.2) capabilities.tsv $k row must be tagged 'watcher' in the requires column"
done
pass
echo "PASS (B.2) documented WATCHER_SCOPE/WATCHER_OWNER semantics match agent-watch.sh (default 'mine', owner fallback chain, watcher-scoped)"

echo
echo "ALL PASS ($PASS checks) — docs/copy de-Streamlit'd (literals gone, guidance kept) + WATCHER_SCOPE/WATCHER_OWNER documented."
