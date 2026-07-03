#!/usr/bin/env bash
# dep-watcher.sh — persistent per-project dependency-watcher singleton.
#
# Reads .herd/deps for "blocked-on: <link-name>#<id>" entries, polls each dep's live upstream state
# on a capped-exponential-backoff interval, removes closed deps from .herd/deps, and surfaces a
# richer dep state so a slow enterprise PR is a STATUS LINE — never a workspace freeze.
#
# Dep STATE (derived from the upstream PR/issue's live state + how long it's been pending):
#   open        — upstream is open, not yet picked up
#   in-progress — upstream work has started (backend reports a started/in-progress state)
#   in-review   — upstream is out for review (backend reports a review state)
#   stalled     — upstream is still open/in-progress/in-review but has shown no movement past the TTL
#                 (surfaced loudly, but still polled — a stall is a warning, not a hard block)
#   closed      — upstream is done → the dep is removed and the workspace is unblocked
#
# BACKOFF: while every open dep is unchanged tick-over-tick the poll interval doubles (capped at
# DEP_POLL_MAX) so a long-pending dep is polled less aggressively over time rather than hammered
# every tick; any state change (a dep closing) resets the interval to DEP_POLL_MIN.
#
# CONSOLE: each tick writes one "<ref> <state> <age-seconds>" line per live dep to $STATES_FILE
# (<lock-stem>.states); agent-watch.sh reads it to paint a "blocked on" status section. The file is
# purely informational — its absence or staleness never gates anything.
#
# Uses the same flock/PID-file spawn-lock pattern as agent-watch.sh (PR #21).
#
# .herd/deps minimal read format (Gap 3 owns schema/write — this watcher only reads):
#   blocked-on: <link-name>#<id>
#
# Config keys (read from .herd/config via herd-config.sh; each falls back to its inline default below,
# so behavior is unchanged when unset — documented in templates/capabilities.tsv + templates/config.example):
#   DEP_POLL_MIN     — initial poll interval in seconds (default: 30)
#   DEP_POLL_MAX     — maximum poll interval after backoff (default: 300)
#   DEP_STALE_TTL    — seconds before a still-open dep is surfaced as `stalled` (default: 86400; 0 disables)
# Env-only knob (test seam, NOT a config key):
#   DEP_WATCHER_LIB  — set to 1 to source helpers without entering the polling loop (for tests)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=herd-config.sh
. "$HERE/herd-config.sh"
# shellcheck source=herd-links.sh
. "$HERE/herd-links.sh"

DEPS_FILE="${DEPS_FILE:-$PROJECT_ROOT/.herd/deps}"
# Poll-cadence + stall-TTL config keys: herd-config.sh (sourced above) has already applied any value
# set in .herd/config, so these reads pick it up; the inline default is the fallback when unset.
DEP_POLL_MIN="${DEP_POLL_MIN:-30}"
DEP_POLL_MAX="${DEP_POLL_MAX:-300}"
DEP_STALE_TTL="${DEP_STALE_TTL:-86400}"
# Per-project state file: tracks first-seen epoch for stale detection.
SINCE_FILE="${HERD_DEPWATCHER_LOCK%.pid}.since"
# Per-project console-surface file: one "<ref> <state> <age>" line per live dep, rewritten each
# tick. agent-watch.sh reads this to paint the "blocked on" section. Informational only.
STATES_FILE="${HERD_DEPWATCHER_LOCK%.pid}.states"
_SECRETS="$PROJECT_ROOT/.herd/secrets"
# shellcheck source=/dev/null
[ -f "$_SECRETS" ] && . "$_SECRETS"
unset _SECRETS

# ── Helper functions ──────────────────────────────────────────────────────────

_dw_log()  { printf '[dep-watcher] %s\n' "$*"; }
_dw_warn() { printf '[dep-watcher] ⚠️  %s\n' "$*" >&2; }

_dw_epoch() {
    date +%s 2>/dev/null || python3 -c 'import time; print(int(time.time()))'
}

_dw_get_since() {
    local ref="$1"
    [ -f "$SINCE_FILE" ] || { printf ''; return 0; }
    awk -v ref="$ref" '$1 == ref { print $2; exit }' "$SINCE_FILE" 2>/dev/null || printf ''
}

_dw_record_since() {
    local ref="$1" epoch="$2"
    [ -n "$(_dw_get_since "$ref")" ] && return 0
    mkdir -p "$(dirname "$SINCE_FILE")" 2>/dev/null || true
    printf '%s %s\n' "$ref" "$epoch" >> "$SINCE_FILE"
}

_dw_clear_since() {
    local ref="$1"
    [ -f "$SINCE_FILE" ] || return 0
    local tmp; tmp="${SINCE_FILE}.$$"
    awk -v ref="$ref" '$1 != ref { print }' "$SINCE_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$SINCE_FILE"
}

_dw_remove_dep() {
    # Atomically remove the blocked-on: <ref> line from .herd/deps.
    local ref="$1"
    [ -f "$DEPS_FILE" ] || return 0
    local tmp; tmp="${DEPS_FILE}.$$"
    grep -Fv "blocked-on: ${ref}" "$DEPS_FILE" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$DEPS_FILE"
    _dw_clear_since "$ref"
}

_dw_check_state() {
    # Resolve the link for <ref>, source the backend, call _backend_item_state.
    # Prints the RAW upstream state on stdout: open|in-progress|in-review|closed|unknown.
    # (Backends that don't distinguish review/progress just report open/closed — the derived
    # state machine below degrades gracefully.) Tests stub this to script upstream transitions.
    local ref="$1"
    (
        link_name="${ref%%#*}"
        # shellcheck source=herd-config.sh
        . "$HERE/herd-config.sh"
        # shellcheck source=herd-links.sh
        . "$HERE/herd-links.sh"
        if ! _herd_resolve_link "$link_name" 2>/dev/null; then
            printf 'unknown\n'
            exit 0
        fi
        backend_file="$HERE/backends/${HERD_REPORT_BACKEND:-github}.sh"
        if [ ! -f "$backend_file" ]; then
            printf 'unknown\n'
            exit 0
        fi
        ITEM_STATE=""
        # shellcheck source=/dev/null
        . "$backend_file"
        _backend_item_state "$ref" 2>/dev/null || true
        printf '%s\n' "${ITEM_STATE:-unknown}"
    )
}

_dw_derive_state() {
    # Pure state machine: map a RAW upstream state + how long the dep has been pending onto the
    # dep STATE surfaced to the operator. A dep that is still open/in-progress/in-review but has
    # shown no movement past the TTL becomes `stalled` — surfaced loudly, yet still polled (a stall
    # is a status line, never a freeze). Usage: _dw_derive_state <raw> <age-seconds> <ttl-seconds>.
    local raw="$1" age="${2:-0}" ttl="${3:-0}"
    case "$raw" in
        closed)
            printf 'closed'
            ;;
        open|in-progress|in-review)
            if [ "$ttl" -gt 0 ] && [ "$age" -gt "$ttl" ]; then
                printf 'stalled'
            else
                printf '%s' "$raw"
            fi
            ;;
        *)
            printf 'unknown'
            ;;
    esac
}

_dw_next_interval() {
    # Pure capped-exponential backoff. Usage: _dw_next_interval <current> <min> <max> <widen>.
    # widen=1 → double the current interval, capped at <max>; anything else → reset to <min>.
    # Prints the next interval on stdout.
    local current="$1" min="$2" max="$3" widen="${4:-0}"
    if [ "$widen" = "1" ]; then
        local next=$(( current * 2 ))
        [ "$next" -gt "$max" ] && next="$max"
        [ "$next" -lt "$min" ] && next="$min"
        printf '%s' "$next"
    else
        printf '%s' "$min"
    fi
}

_dw_write_states() {
    # Atomically rewrite $STATES_FILE from the caller-accumulated $1 (one "<ref> <state> <age>"
    # line per live dep). Best-effort: a failed write never interrupts the poll loop.
    local body="$1"
    [ -n "${STATES_FILE:-}" ] || return 0
    mkdir -p "$(dirname "$STATES_FILE")" 2>/dev/null || true
    local tmp; tmp="${STATES_FILE}.$$"
    if printf '%s' "$body" > "$tmp" 2>/dev/null; then
        mv "$tmp" "$STATES_FILE" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
    else
        rm -f "$tmp" 2>/dev/null || true
    fi
}

# ── Lib mode: helpers only, no loop (for tests) ───────────────────────────────
if [ "${DEP_WATCHER_LIB:-}" = "1" ]; then return 0 2>/dev/null || exit 0; fi

# ── Singleton spawn-lock: exactly one dep-watcher per project ─────────────────
# Follows the same two-mechanism pattern as agent-watch.sh (PR #21):
#   • flock(1) available  — non-blocking exclusive lock on fd 9, auto-released on exit.
#   • no flock (macOS)    — atomic-mkdir mutex + PID file, cleaned up on EXIT/INT/TERM.
mkdir -p "$(dirname "$HERD_DEPWATCHER_LOCK")" 2>/dev/null || true
if command -v flock >/dev/null 2>&1; then
    exec 9>"$HERD_DEPWATCHER_LOCK"
    if ! flock -n 9; then
        printf 'dep-watcher already running for %s — exiting.\n' "$WORKSPACE_NAME" >&2
        exit 0
    fi
    printf '%s\n' "$$" >"$HERD_DEPWATCHER_LOCK"
else
    _wl_mtx="${HERD_DEPWATCHER_LOCK}.d"
    _wl_tries=0
    while ! mkdir "$_wl_mtx" 2>/dev/null; do
        [ -z "$(find "$_wl_mtx" -prune -mmin -1 2>/dev/null)" ] && { rmdir "$_wl_mtx" 2>/dev/null || true; continue; }
        _wl_tries=$((_wl_tries + 1)); [ "$_wl_tries" -ge 30 ] && break; sleep 0.1
    done
    _wl_pid="$(cat "$HERD_DEPWATCHER_LOCK" 2>/dev/null || true)"
    if [ -n "$_wl_pid" ] && kill -0 "$_wl_pid" 2>/dev/null; then
        rmdir "$_wl_mtx" 2>/dev/null || true
        printf 'dep-watcher already running for %s (PID %s) — exiting.\n' "$WORKSPACE_NAME" "$_wl_pid" >&2
        exit 0
    fi
    _wl_tmp="${HERD_DEPWATCHER_LOCK}.$$"
    printf '%s\n' "$$" >"$_wl_tmp"; mv "$_wl_tmp" "$HERD_DEPWATCHER_LOCK"
    rmdir "$_wl_mtx" 2>/dev/null || true
    unset _wl_mtx _wl_tries _wl_pid _wl_tmp
    trap 'rm -f "$HERD_DEPWATCHER_LOCK" 2>/dev/null || true' EXIT
    trap 'rm -f "$HERD_DEPWATCHER_LOCK" 2>/dev/null || true; exit 1' INT TERM
fi
# ─────────────────────────────────────────────────────────────────────────────

_dw_log "started for $WORKSPACE_NAME (PID $$; TTL=${DEP_STALE_TTL}s; poll ${DEP_POLL_MIN}-${DEP_POLL_MAX}s)"
interval="$DEP_POLL_MIN"

while true; do
    if [ ! -f "$DEPS_FILE" ]; then
        sleep "$interval"
        continue
    fi

    # Snapshot blocked-on refs into an array to avoid fd conflicts when removing deps mid-loop.
    refs=()
    while IFS= read -r line; do
        case "$line" in 'blocked-on: '*) ;; *) continue ;; esac
        ref="${line#blocked-on: }"
        ref="${ref%%[[:space:]]*}"
        [ -n "$ref" ] && refs+=("$ref")
    done < "$DEPS_FILE"

    now="$(_dw_epoch)"
    any_open=0
    changed=0
    states_body=""

    for ref in "${refs[@]+"${refs[@]}"}"; do
        _dw_record_since "$ref" "$now"

        raw="$(_dw_check_state "$ref" || printf 'unknown')"
        since="$(_dw_get_since "$ref")"
        age=0
        [ -n "$since" ] && age=$(( now - since ))
        state="$(_dw_derive_state "$raw" "$age" "$DEP_STALE_TTL")"

        case "$state" in
            closed)
                _dw_log "dep CLOSED: $ref — unblocking"
                _dw_remove_dep "$ref"
                herdr notification show "🔓 Dep unblocked" \
                    --body "$ref is closed — $WORKSPACE_NAME is unblocked" \
                    --sound done >/dev/null 2>&1 || true
                changed=1
                # Closed deps drop off the console surface (they're removed from .herd/deps).
                continue
                ;;
            stalled)
                # A stall is a STATUS LINE, never a freeze: surface it loudly but keep polling.
                _dw_warn "STALLED: $ref — no upstream movement for ${age}s (TTL=${DEP_STALE_TTL}s)"
                any_open=$((any_open + 1))
                ;;
            open|in-progress|in-review)
                any_open=$((any_open + 1))
                ;;
            *)
                _dw_warn "could not resolve state for $ref — will retry"
                any_open=$((any_open + 1))
                ;;
        esac

        states_body="${states_body}${ref} ${state} ${age}"$'\n'
    done

    _dw_write_states "$states_body"

    # Backoff: reset to DEP_POLL_MIN on any change; otherwise, while open deps sit unchanged, widen
    # the interval (capped) so long-pending deps are polled less aggressively over time.
    widen=0
    [ "$changed" -eq 0 ] && [ "$any_open" -gt 0 ] && widen=1
    interval="$(_dw_next_interval "$interval" "$DEP_POLL_MIN" "$DEP_POLL_MAX" "$widen")"

    sleep "$interval"
done
