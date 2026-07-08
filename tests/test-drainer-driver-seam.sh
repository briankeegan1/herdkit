#!/usr/bin/env bash
# test-drainer-driver-seam.sh — the scribe/research drainers route their notifications AND their
# singleton-liveness roster read through the driver seam (scripts/herd/driver.sh), not raw herdr
# (HERD-160 quick win).
#
# WHY: raw `herdr notification show` / `herdr agent list` in the drainers meant a headless run either
# fired a real desktop notification (the 2026-07-08 cry-wolf hermeticity incident) or could not read
# its roster at all. Routing through herd_driver_notify / herd_driver_agent_list_json makes the
# drainers driver-aware: under HERD_DRIVER=headless the notification lands in the durable
# notifications.log sink and the roster is synthesized from the detached-agent registry.
#
# PART A drives research-step.sh's `report` end-to-end under the headless driver and asserts the
# notification hit the durable sink (behavioural). PART B asserts the wiring in all four files.
#
# Hermetic: headless driver + temp dirs, native desktop notify suppressed. No real herdr/claude/network.
# Run:  bash tests/test-drainer-driver-seam.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SCRIPTS="$ROOT/scripts/herd"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# _code_has <file> <ere> — true iff a NON-comment line of <file> matches <ere>.
_code_has() { awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s !~ /^#/) print }' "$1" | "$GREP" -qE "$2"; }

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART A — research-step.sh `report` fires the notification through the headless driver sink.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
TREES="$T/trees"; PROJ="$T/proj"; mkdir -p "$TREES" "$PROJ/.herd"
cat > "$PROJ/.herd/config" <<EOF
PROJECT_ROOT="$PROJ"
WORKTREES_DIR="$TREES"
EOF
export HERD_CONFIG_FILE="$PROJ/.herd/config"
export HERD_DRIVER=headless
export HERD_HEADLESS_NATIVE_NOTIFY=off      # suppress the best-effort real desktop notification
export RESEARCH_TREES="$TREES"
export RESEARCH_QUEUE="$TREES/research-queue"
export RESEARCH_REPORTS="$TREES/research-reports"
export RESEARCH_INBOX="$TREES/.research-reports"
mkdir -p "$RESEARCH_QUEUE"

# A claimed request file (name → REQ_ID) + a findings file, the two inputs `report` consumes.
MINE="$RESEARCH_QUEUE/req-XYZ.req.mine"
printf 'what is the meaning of the seam?\n' > "$MINE"
FINDINGS="$T/findings.md"
printf '# findings\nthe seam is one place to change behavior.\n' > "$FINDINGS"

out="$(bash "$SCRIPTS/research-step.sh" report "$MINE" "$FINDINGS" 2>&1)" || fail "(A) research-step report exited non-zero: $out"
echo "$out" | "$GREP" -q 'DONE req-XYZ' || fail "(A) report did not confirm DONE: $out"
pass

# The headless driver's durable sink recorded the notification (title + body), and no desktop channel.
SINK="$TREES/.herd/notifications.log"
[ -f "$SINK" ] || fail "(A) headless notify sink was not written at $SINK"
"$GREP" -q 'Research ready' "$SINK" || fail "(A) sink missing the 'Research ready' title: $(cat "$SINK")"
"$GREP" -q 'req-XYZ' "$SINK"        || fail "(A) sink missing the REQ_ID in the notification body"
pass

# The report was actually filed (sanity: the seam swap didn't break the drainer's real work).
[ -f "$RESEARCH_REPORTS/req-XYZ.md" ] || fail "(A) report file was not moved into place"
"$GREP" -q 'req-XYZ' "$RESEARCH_INBOX" || fail "(A) inbox line not appended"
pass

unset HERD_CONFIG_FILE HERD_DRIVER HERD_HEADLESS_NATIVE_NOTIFY \
      RESEARCH_TREES RESEARCH_QUEUE RESEARCH_REPORTS RESEARCH_INBOX

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART B — wiring: all four files use the seam, none carry the raw herdr form.
# ══════════════════════════════════════════════════════════════════════════════════════════════════
# research-step.sh + scribe-step.sh: source the driver, notify through it, no raw `herdr notification`.
for f in research-step scribe-step; do
  _code_has "$SCRIPTS/$f.sh" 'herd_driver_notify' \
    || fail "(B) $f.sh does not call herd_driver_notify"
  _code_has "$SCRIPTS/$f.sh" '\. "\$HERE/driver\.sh"' \
    || fail "(B) $f.sh does not source driver.sh"
  ! _code_has "$SCRIPTS/$f.sh" 'herdr notification' \
    || fail "(B) $f.sh still contains a raw 'herdr notification' call"
done
pass

# scribe.sh + research.sh: singleton probe reads the roster through herd_driver_agent_list_json.
for f in scribe research; do
  _code_has "$SCRIPTS/$f.sh" 'AGENTS_JSON="\$\(herd_driver_agent_list_json' \
    || fail "(B) $f.sh does not read its roster through herd_driver_agent_list_json"
  ! _code_has "$SCRIPTS/$f.sh" 'herdr agent list' \
    || fail "(B) $f.sh still contains a raw 'herdr agent list' call"
done
pass

echo "ALL PASS ($PASS checks)"
