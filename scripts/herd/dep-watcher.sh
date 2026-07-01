#!/usr/bin/env bash
# dep-watcher.sh — persistent per-project dependency-watcher singleton.
#
# Reads .herd/deps for "blocked-on: <link-name>#<id>" entries, polls each dep's
# _backend_item_state on an interval with exponential backoff, removes closed deps from
# .herd/deps, and warns on stalled deps (open longer than DEP_STALE_TTL seconds).
#
# Uses the same flock/PID-file spawn-lock pattern as agent-watch.sh (PR #21).
#
# .herd/deps minimal read format (Gap 3 owns schema/write — this watcher only reads):
#   blocked-on: <link-name>#<id>
#
# Env knobs:
#   DEP_POLL_MIN     — initial poll interval in seconds (default: 30)
#   DEP_POLL_MAX     — maximum poll interval after backoff (default: 300)
#   DEP_STALE_TTL    — seconds before a still-open dep is surfaced as a warning (default: 86400)
#   DEP_WATCHER_LIB  — set to 1 to source helpers without entering the polling loop (for tests)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=herd-config.sh
. "$HERE/herd-config.sh"
# shellcheck source=herd-links.sh
. "$HERE/herd-links.sh"

DEPS_FILE="${DEPS_FILE:-$PROJECT_ROOT/.herd/deps}"
DEP_POLL_MIN="${DEP_POLL_MIN:-30}"
DEP_POLL_MAX="${DEP_POLL_MAX:-300}"
DEP_STALE_TTL="${DEP_STALE_TTL:-86400}"
# Per-project state file: tracks first-seen epoch for stale detection.
SINCE_FILE="${HERD_DEPWATCHER_LOCK%.pid}.since"
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
    # Prints the ITEM_STATE on stdout (open|closed|in-progress|unknown).
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

    for ref in "${refs[@]+"${refs[@]}"}"; do
        _dw_record_since "$ref" "$now"

        state="$(_dw_check_state "$ref" || printf 'unknown')"

        case "$state" in
            closed)
                _dw_log "dep CLOSED: $ref — unblocking"
                _dw_remove_dep "$ref"
                herdr notification show "🔓 Dep unblocked" \
                    --body "$ref is closed — $WORKSPACE_NAME is unblocked" \
                    --sound done >/dev/null 2>&1 || true
                changed=1
                ;;
            open|in-progress)
                any_open=$((any_open + 1))
                since="$(_dw_get_since "$ref")"
                if [ -n "$since" ]; then
                    age=$(( now - since ))
                    if [ "$age" -gt "$DEP_STALE_TTL" ]; then
                        _dw_warn "STALLED: $ref — open for ${age}s (TTL=${DEP_STALE_TTL}s)"
                    fi
                fi
                ;;
            *)
                _dw_warn "could not resolve state for $ref — will retry"
                any_open=$((any_open + 1))
                ;;
        esac
    done

    # Backoff: reset to min on a change, double on idle.
    if [ "$changed" -eq 1 ]; then
        interval="$DEP_POLL_MIN"
    elif [ "$any_open" -gt 0 ]; then
        interval=$(( interval * 2 ))
        [ "$interval" -gt "$DEP_POLL_MAX" ] && interval="$DEP_POLL_MAX"
    fi

    sleep "$interval"
done
