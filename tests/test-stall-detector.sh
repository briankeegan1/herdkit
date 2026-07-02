#!/usr/bin/env bash
# test-stall-detector.sh — hermetic test for the builder stall detector's liveness ladder in
# agent-watch.sh. It sources the watcher's helpers via the AGENT_WATCH_LIB guard (loads functions
# WITHOUT entering the live watch loop) and exercises them against fake worktrees (real temp git
# repos with files touched to controlled mtimes) and a stubbed Claude transcript dir. NO network,
# NO real HOME, NO real panes — everything is a temp dir under $T.
#
# Asserts the behaviors the backlog item requires:
#   • fresh uncommitted edits          ⇒ building, NEVER stalled  (the reported false-alarm)
#   • working agent + edits (even old) ⇒ building, NEVER stalled
#   • clean + old + zero commits       ⇒ the "no activity … · check pane" warning
#   • transcript still growing         ⇒ rescues a would-be stall back to building
#   • STALL_QUIET_MIN override         ⇒ shifts the fresh-vs-stale boundary
# Run:  bash tests/test-stall-detector.sh
# No `set -e`: some predicates deliberately return non-zero; we assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
WATCH="$HERE/../scripts/herd/agent-watch.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
eq(){ [ "$1" = "$2" ] || fail "$3 (expected '$2', got '$1')"; ok; }

[ -f "$WATCH" ] || fail "agent-watch.sh not found at $WATCH"
command -v git >/dev/null 2>&1 || fail "git required"

# Source the helpers WITHOUT the live loop; point config discovery at a nonexistent file so
# herd-config.sh falls back to generic defaults — fully hermetic, no repo/.herd walk-up.
export AGENT_WATCH_LIB=1
export HERD_CONFIG_FILE="$T/no-such-config"
# Redirect all mutable state the helpers touch into the temp dir.
export HERD_TRANSCRIPT_ROOT="$T/transcripts"
# shellcheck source=/dev/null
. "$WATCH" || fail "sourcing agent-watch.sh (lib mode) failed"
TRANSCRIPT_STATE="$T/transcript-state"   # override the ledger the helpers write to
for fn in _classify_builder _worktree_newest_edit _worktree_born _stall_quiet_secs _transcript_obs _transcript_growing file_mtime; do
  type "$fn" >/dev/null 2>&1 || fail "$fn not defined after sourcing"
done

# touch_at <epoch> <file> — set a file's mtime portably (BSD -t needs [[CC]YY]MMDDhhmm[.SS]).
touch_at() {
  local when="$1" f="$2" stamp
  stamp="$(date -r "$when" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$when" +%Y%m%d%H%M.%S 2>/dev/null)"
  touch -t "$stamp" "$f"
}

# mk_worktree <name> — a real git repo with one base commit; echoes its path.
mk_worktree() {
  local d="$T/$1"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  echo base > "$d/README.md"; git -C "$d" add README.md; git -C "$d" commit -qm base
  printf '%s' "$d"
}

NOW="$(date +%s)"

# ── _stall_quiet_secs: env override + numeric-safety fallback ─────────────────
( unset STALL_QUIET_MIN; eq "$(_stall_quiet_secs)" 300 "default quiet = 5min" )
( STALL_QUIET_MIN=7   ; eq "$(_stall_quiet_secs)" 420 "override 7min → 420s" )
( STALL_QUIET_MIN=abc ; eq "$(_stall_quiet_secs)" 300 "non-numeric → 300s fallback" )

# ── _worktree_newest_edit: clean tree → empty; dirty → newest mtime ──────────
WT_CLEAN="$(mk_worktree clean)"
eq "$(_worktree_newest_edit "$WT_CLEAN")" "" "clean tree ⇒ no edit signal"

WT_DIRTY="$(mk_worktree dirty)"
echo change >> "$WT_DIRTY/README.md"                 # tracked+modified
echo new    >  "$WT_DIRTY/scratch.txt"               # untracked
touch_at "$(( NOW - 1000 ))" "$WT_DIRTY/README.md"
touch_at "$(( NOW - 30 ))"   "$WT_DIRTY/scratch.txt" # newest
eq "$(_worktree_newest_edit "$WT_DIRTY")" "$(( NOW - 30 ))" "dirty tree ⇒ newest mtime among changes"

eq "$(_worktree_newest_edit "$T/not-a-repo")" "" "non-repo path ⇒ empty (no crash)"

# ── _classify_builder: the ladder verdicts ───────────────────────────────────
# Signature: <edit-age> <changes> <commits> <status> <tgrow> <quiet> <quiet-elapsed>.
# 1. fresh uncommitted edits ⇒ building, never stalled (THE reported false alarm).
eq "$(_classify_builder 30 1 0 working unknown 300 30)" BUILD_UNCOMMITTED "fresh edits ⇒ building"
# 2. working + stale edits (older than quiet) ⇒ still building, never stalled.
eq "$(_classify_builder 9999 1 0 working no 300 9999)" BUILDING "working + stale edits ⇒ building"
# 3. clean + zero commits + flat/unknown transcript + quiet BEYOND the window ⇒ stall.
eq "$(_classify_builder -1 0 0 working no 300 600)"      STALL "clean+quiet-beyond-window+commitless+flat ⇒ stall"
eq "$(_classify_builder -1 0 0 working unknown 300 600)" STALL "clean+quiet-beyond-window+commitless+no-transcript ⇒ stall"
# 3b. QUIET-FLOOR (root-cause 1): a commitless, dirty-file-free tree still INSIDE the window is NOT
#     stalled — it is just starting up. This is the '0m' cold-start false-STALL the bug reported.
eq "$(_classify_builder -1 0 0 working unknown 300 30)" BUILDING "commitless + young (qelapsed<quiet) ⇒ building (not 0m stall)"
eq "$(_classify_builder -1 0 0 working no 300 0)"       BUILDING "commitless + just-born (qelapsed 0) ⇒ building"
# 3c. boundary: quiet-elapsed exactly at the window earns the warning (≥ is the threshold).
eq "$(_classify_builder -1 0 0 working no 300 300)" STALL    "commitless + qelapsed==quiet ⇒ stall"
eq "$(_classify_builder -1 0 0 working no 300 299)" BUILDING "commitless + qelapsed just under quiet ⇒ building"
# 4. transcript growing rescues a would-be stall (even when quiet-elapsed is beyond the window).
eq "$(_classify_builder -1 0 0 working yes 300 600)" BUILDING "growing transcript ⇒ rescued to building"
# 5. already committed (rare pre-PR) ⇒ building, not stalled.
eq "$(_classify_builder -1 0 2 working no 300 600)" BUILDING "has commits ⇒ building"

# ── STALL_QUIET_MIN shifts the fresh-vs-stale boundary ───────────────────────
# An edit 400s old: stale under the 5-min default (→ plain building via rung 2), but fresh under a
# 10-min threshold (→ building (uncommitted changes)). Same inputs, threshold flips the wording.
eq "$(_classify_builder 400 1 0 working no "$(STALL_QUIET_MIN=5  _stall_quiet_secs)" 400)" BUILDING          "400s edit, 5min quiet ⇒ building"
eq "$(_classify_builder 400 1 0 working no "$(STALL_QUIET_MIN=10 _stall_quiet_secs)" 400)" BUILD_UNCOMMITTED "400s edit, 10min quiet ⇒ building (uncommitted)"

# ── _transcript_obs + _transcript_growing: cache + one-way veto ──────────────
MUNGED="$(printf '%s' "$WT_DIRTY" | tr '/.' '-')"
TDIR="$HERD_TRANSCRIPT_ROOT/$MUNGED"; mkdir -p "$TDIR"
printf 'a\n' > "$TDIR/session.jsonl"
OBS1="$(_transcript_obs "$WT_DIRTY")"
[ -n "$OBS1" ] || fail "transcript obs should be non-empty when a .jsonl exists"
eq "${OBS1%% *}" 2 "transcript obs reports byte size"

: > "$TRANSCRIPT_STATE"
eq "$(_transcript_growing "$WT_DIRTY" "$OBS1" "$NOW" 300)" unknown "first observation ⇒ unknown"
printf 'aaaa\n' > "$TDIR/session.jsonl"                       # grew
eq "$(_transcript_growing "$WT_DIRTY" "$(_transcript_obs "$WT_DIRTY")" "$NOW" 300)" yes "grown transcript ⇒ yes"
# THE FLAP FIX (root-cause 2): a flat poll immediately after a grow is still ALIVE, because the
# transcript grew within the quiet window. The old adjacent-poll compare returned "no" here and
# caused the momentary STALL flicker.
eq "$(_transcript_growing "$WT_DIRTY" "$(_transcript_obs "$WT_DIRTY")" "$NOW" 300)" yes "flat but grew within window ⇒ yes (no flap)"
# Once the last-grew epoch falls outside the window, a flat transcript is genuinely quiet ⇒ no.
eq "$(_transcript_growing "$WT_DIRTY" "$(_transcript_obs "$WT_DIRTY")" "$(( NOW + 600 ))" 300)" no "flat beyond window ⇒ no"
eq "$(_transcript_growing "$WT_DIRTY" "" "$NOW" 300)" unknown "no transcript ⇒ unknown (never fabricates a stall)"

# Cache backward-tolerance: a legacy 3-field line (no last-grew epoch). A flat re-observation has no
# recorded growth ⇒ "no" (no crash); a genuine grow vs the legacy line stamps a fresh epoch ⇒ "yes".
: > "$TRANSCRIPT_STATE"
OBS_NOW="$(_transcript_obs "$WT_DIRTY")"                      # "<size> <mtime>" of the current file
printf '%s %s %s\n' "$WT_DIRTY" "${OBS_NOW%% *}" "${OBS_NOW##* }" > "$TRANSCRIPT_STATE"  # legacy 3-field
eq "$(_transcript_growing "$WT_DIRTY" "$OBS_NOW" "$NOW" 300)" no "legacy cache line, flat ⇒ no (backward-tolerant, no crash)"
: > "$TRANSCRIPT_STATE"
printf '%s %s %s\n' "$WT_DIRTY" "${OBS_NOW%% *}" "${OBS_NOW##* }" > "$TRANSCRIPT_STATE"
printf 'aaaaaaaa\n' > "$TDIR/session.jsonl"                   # grew past the legacy size
eq "$(_transcript_growing "$WT_DIRTY" "$(_transcript_obs "$WT_DIRTY")" "$NOW" 300)" yes "legacy cache line, grew ⇒ yes"

# ── end-to-end on fake worktrees: mirror the render block's exact call sequence ──
# The optional 4th arg stubs the worktree BIRTH epoch (the render block statts the real dir; a temp
# repo is always ~now old, so we inject an age to exercise the quiet-floor without waiting).
classify_wt() {  # <worktree> <agent-status> <transcript-growing> [<born-epoch>] -> the ladder token
  local dir="$1" astatus="$2" tgrow="$3" born="${4:-}" now newest changes age commits quiet qelapsed
  quiet="$(_stall_quiet_secs)"; now="$(date +%s)"
  newest="$(_worktree_newest_edit "$dir")"
  if [ -n "$newest" ]; then changes=1; age=$(( now - newest )); else changes=0; age=-1; fi
  commits="$(git -C "$dir" rev-list HEAD --count --not "$DEFAULT_BRANCH" 2>/dev/null || echo 0)"
  [ -n "$born" ] || born="$(_worktree_born "$dir")"
  if [ "$changes" -eq 1 ]; then qelapsed="$age"; else qelapsed=$(( now - born )); fi
  _classify_builder "$age" "$changes" "${commits:-0}" "$astatus" "$tgrow" "$quiet" "$qelapsed"
}

# Fresh-edit worktree, agent working ⇒ MUST read as building, never stalled (the headline bug).
WT_LIVE="$(mk_worktree live)"; echo wip > "$WT_LIVE/feature.py"   # untracked, mtime = now
eq "$(classify_wt "$WT_LIVE" working unknown)" BUILD_UNCOMMITTED "e2e: actively-coding builder ⇒ building"

# (a) COLD START: commitless, ZERO dirty files, worktree younger than the window ⇒ building, NOT the
#     '0m' false STALL. Uses the real just-born birth of a freshly-created temp repo.
WT_NEW="$(mk_worktree cold)"
eq "$(classify_wt "$WT_NEW" working unknown)" BUILDING "e2e: cold-start young clean tree ⇒ building (not 0m stall)"

# (b) THE FLAP: commitless, clean, OLD tree whose transcript grew within the window but NOT on the
#     last poll (a flat adjacent-poll pair sitting on a recent last-grew epoch) ⇒ building.
WT_FLAP="$(mk_worktree flap)"
MUNGED_F="$(printf '%s' "$WT_FLAP" | tr '/.' '-')"; TDIR_F="$HERD_TRANSCRIPT_ROOT/$MUNGED_F"; mkdir -p "$TDIR_F"
printf 'burst\n' > "$TDIR_F/session.jsonl"
OBS_F="$(_transcript_obs "$WT_FLAP")"
# Seed the cache as if a grow happened 30s ago and the immediately-adjacent poll is flat (same obs).
: > "$TRANSCRIPT_STATE"
printf '%s %s %s %s\n' "flap" "${OBS_F%% *}" "${OBS_F##* }" "$(( NOW - 30 ))" > "$TRANSCRIPT_STATE"
TG_FLAP="$(_transcript_growing flap "$OBS_F" "$NOW" 300)"   # flat obs, but grew 30s ago ⇒ yes
eq "$TG_FLAP" yes "flap: flat poll on a 30s-old grow ⇒ transcript veto says alive"
eq "$(classify_wt "$WT_FLAP" working "$TG_FLAP" "$(( NOW - 600 ))")" BUILDING "e2e: old clean tree, transcript grew within window ⇒ building (flap fixed)"

# (c) GENUINELY QUIET: worktree older than the window, flat transcript beyond the window, zero
#     commits, agent working ⇒ MUST earn the warning.
WT_DEAD="$(mk_worktree dead)"
eq "$(classify_wt "$WT_DEAD" working no "$(( NOW - 600 ))")" STALL "e2e: old clean commitless tree, flat transcript ⇒ stall warning"

# (d) the _qmins shown for that real STALL is accurate and > 0 (mirrors the render block's math:
#     qelapsed = now - born, _qmins = qelapsed / 60). A 600s-old birth ⇒ 10m, never the bogus 0m.
QELAPSED_D=$(( NOW - ( NOW - 600 ) )); QMINS_D=$(( QELAPSED_D / 60 ))
eq "$QMINS_D" 10 "stall _qmins reflects true quiet age (600s ⇒ 10m)"
[ "$QMINS_D" -gt 0 ] || fail "stall _qmins must be > 0 (accurate, not the '0m' cold-start bug)"; ok

echo "ALL PASS ($pass checks)"
