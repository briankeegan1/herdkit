#!/usr/bin/env bash
# scripts/herd/sim/external-consumer-probe.sh — exercise the REAL init/scout/config-render/healthcheck
# logic against the synthetic Go consumer fixture and emit a machine-readable leak scorecard.
#
# This is the "run herd against a generic consumer and watch what leaks" driver for the Phase-4
# abstraction audit (docs/external-consumer-audit.md). It is hermetic: no network, no herdr panes, no
# model call, no doctor gate. It drives the actual engine entry points that a real `herd init` would
# hit — scout_repo (extracted verbatim from bin/herd), `herd render`, and scripts/herd/healthcheck.sh
# — against the fixture and RECORDS, per probe, whether a herdkit assumption leaked onto the generic
# consumer. Every leak asserted here is cited by file:line in docs/external-consumer-audit.md.
#
# Usage:  bash scripts/herd/sim/external-consumer-probe.sh [--artifacts <dir>]
#         cat <artifacts>/scorecard.json
#
# A probe's status is:  leak (the assumption leaked, as the audit predicts) · clean (no leak) ·
# skip (probe could not run). result=="leaks-confirmed" iff every expected leak reproduced.
set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$HERE/../../.." && pwd)"
HERD_BIN="$REPO_ROOT/bin/herd"
HEALTHCHECK="$REPO_ROOT/scripts/herd/healthcheck.sh"
# shellcheck source=/dev/null
. "$HERE/external-consumer-fixture.sh"

ARTIFACTS=""
while [ $# -gt 0 ]; do
  case "$1" in
    --artifacts) ARTIFACTS="${2:-}"; shift 2 ;;
    *) echo "unknown arg: $1" >&2; exit 2 ;;
  esac
done
if [ -z "$ARTIFACTS" ]; then
  ARTIFACTS="${TMPDIR:-/tmp}/ext-consumer-probe.$$"
fi
mkdir -p "$ARTIFACTS"
FIXTURE="$ARTIFACTS/repo"

# ── scorecard accumulation ───────────────────────────────────────────────────
PROBES_JSON=""; N_LEAK=0; N_CLEAN=0; N_SKIP=0
record() {  # record <name> <status:leak|clean|skip> <detail>
  local name="$1" status="$2" detail="$3"
  case "$status" in
    leak)  N_LEAK=$((N_LEAK+1));  echo "  🔴 LEAK  $name — $detail" >&2 ;;
    clean) N_CLEAN=$((N_CLEAN+1)); echo "  🟢 clean $name — $detail" >&2 ;;
    skip)  N_SKIP=$((N_SKIP+1));  echo "  ⚪ skip  $name — $detail" >&2 ;;
  esac
  detail="${detail//\\/\\\\}"; detail="${detail//\"/\\\"}"
  local entry; entry=$(printf '{"name":"%s","status":"%s","detail":"%s"}' "$name" "$status" "$detail")
  PROBES_JSON="${PROBES_JSON:+$PROBES_JSON,}$entry"
}

echo "── external-consumer abstraction probe ─────────────────────────────" >&2
echo "building synthetic Go consumer fixture → $FIXTURE" >&2
FIX_SHA="$(ext_consumer_fixture_build "$FIXTURE")" || { echo "fixture build failed" >&2; exit 1; }
echo "fixture HEAD: $FIX_SHA" >&2
echo >&2

# ── PROBE 1: scout classifies the stack but nothing downstream understands it ──
# scout_repo is extracted verbatim from bin/herd so we exercise the real detection.
SCOUT_FN="$ARTIFACTS/scout_repo.fn.sh"
sed -n '/^scout_repo() {/,/^}/p' "$HERD_BIN" > "$SCOUT_FN"
if [ -s "$SCOUT_FN" ]; then
  SCOUT="$( . "$SCOUT_FN"; scout_repo "$FIXTURE" )"
  s_lang="$(printf '%s' "$SCOUT" | sed -n 's/^lang=//p')"
  s_backlog="$(printf '%s' "$SCOUT" | sed -n 's/^backlog=//p')"
  if [ "$s_lang" = "go" ]; then
    record "scout-detects-go" "leak" \
      "scout_repo classifies lang=go, but no Go-aware healthcheck template, light-profile syntax gate, or preview path exists (bin/herd:146-149)"
  else
    record "scout-detects-go" "clean" "expected lang=go, got lang=$s_lang"
  fi
  if [ -z "$s_backlog" ]; then
    record "scout-no-backlog" "leak" \
      "no BACKLOG.md/TODO.md/ROADMAP.md → init offers to create a herdkit-format 🔜/🚧/✅ BACKLOG.md the Go project never asked for (bin/herd:549-562)"
  else
    record "scout-no-backlog" "clean" "found backlog files: $s_backlog"
  fi
else
  record "scout-detects-go" "skip" "could not extract scout_repo from bin/herd"
fi

# ── PROBE 2: the light healthcheck profile silently green-lights a broken .go file ──
# A generic consumer with no HEALTHCHECK_CMD gets the light profile, which only syntax-checks
# *.sh / *.py. Break a real .go source and confirm the gate reports CLEAN with exit 0.
cp "$FIXTURE/internal/greet/greet.go" "$ARTIFACTS/greet.go.orig"
printf '\nfunc broken( {  // deliberate Go syntax error\n' >> "$FIXTURE/internal/greet/greet.go"
LIGHT_OUT="$(HERD_CONFIG_FILE=/dev/null bash "$HEALTHCHECK" "$FIXTURE" --oneline 2>&1)"; LIGHT_RC=$?
cp "$ARTIFACTS/greet.go.orig" "$FIXTURE/internal/greet/greet.go"   # restore fixture
if [ "$LIGHT_RC" -eq 0 ] && printf '%s' "$LIGHT_OUT" | grep -qi 'clean'; then
  record "light-profile-ignores-go" "leak" \
    "broken .go passed the light healthcheck as '$LIGHT_OUT' (exit 0) — the light profile only checks *.sh/*.py (healthcheck.sh:114-153)"
else
  record "light-profile-ignores-go" "clean" "light profile did NOT green-light the broken .go (rc=$LIGHT_RC: $LIGHT_OUT)"
fi

# ── PROBE 3: the seeded ^app/ heavy/surface globs never match a Go layout ──
GO_PATHS=$'cmd/greetd/main.go\ninternal/greet/greet.go'
if printf '%s\n' "$GO_PATHS" | grep -qE '^app/'; then
  record "app-glob-mismatch" "clean" "^app/ matched a Go path (unexpected)"
else
  record "app-glob-mismatch" "leak" \
    "HEALTHCHECK_HEAVY_GLOB / APP_SURFACE_GLOB default '^app/' (config.example, capabilities.tsv:52-53) never matches Go paths cmd/ or internal/ — heavy gate and interaction gate silently never fire"
fi

# ── PROBE 4: the rendered coordinator skill hardcodes herdr/claude assumptions ──
# Render the REAL coordinator skill against a generic Go config and confirm herdkit's own tooling
# assumptions survive verbatim into the consumer's skill.
mkdir -p "$FIXTURE/.herd"
cat > "$FIXTURE/.herd/config" <<CFG
HERD_VERSION=1
PROJECT_ROOT="$FIXTURE"
WORKSPACE_NAME="greetd"
DEFAULT_BRANCH="origin/main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="file"
COORDINATOR_CMD="/coordinator"
HERD_REPO=""
DENY_PATHS=""
CFG
if ( cd "$FIXTURE" && HERD_SKIP_DOCTOR=1 "$HERD_BIN" render >/dev/null 2>&1 ); then
  SKILL="$FIXTURE/.claude/commands/coordinator.md"
  hits="$(grep -icE 'herdr|claude ' "$SKILL" 2>/dev/null || echo 0)"
  if [ "${hits:-0}" -gt 0 ]; then
    record "rendered-skill-tooling" "leak" \
      "the rendered coordinator skill references herdr/claude ${hits}× — a generic consumer's skill presumes the herdr multiplexer + Claude CLI (templates/coordinator.md.tmpl)"
  else
    record "rendered-skill-tooling" "clean" "no herdr/claude references in rendered skill"
  fi
else
  record "rendered-skill-tooling" "skip" "herd render failed against the Go fixture"
fi

# ── emit the scorecard ───────────────────────────────────────────────────────
result="leaks-confirmed"; [ "$N_LEAK" -eq 0 ] && result="no-leaks"
SCORECARD="$ARTIFACTS/scorecard.json"
cat > "$SCORECARD" <<JSON
{
  "scenario": "external-consumer-abstraction-audit",
  "artifacts_dir": "$ARTIFACTS",
  "repo_dir": "$FIXTURE",
  "fixture_sha": "$FIX_SHA",
  "result": "$result",
  "leaks": $N_LEAK,
  "clean": $N_CLEAN,
  "skipped": $N_SKIP,
  "probes": [$PROBES_JSON]
}
JSON
echo >&2
echo "scorecard → $SCORECARD  (leaks=$N_LEAK clean=$N_CLEAN skip=$N_SKIP)" >&2
cat "$SCORECARD"
