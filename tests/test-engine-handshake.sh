#!/usr/bin/env bash
# test-engine-handshake.sh — hermetic tests for the ENGINE VERSION HANDSHAKE + ENGINE_AUTOUPDATE
# (HERD-179, scripts/herd/engine-version.sh). What the feature promises, and what this locks in:
#
#   INERT      — ENGINE_MIN unset/0, or a current engine: every guard is a silent 0, nothing journaled
#                (byte-identical to before the feature existed).
#   REFUSAL    — against a STALE stamp (engine level < ENGINE_MIN) every WRITE path refuses non-zero,
#                prints the exact remedy text `run herd update`, and journals engine_handshake_refused.
#   ESCAPE     — HERD_ENGINE_SKIP_HANDSHAKE=1 downgrades the refusal to a warning that returns 0 AND
#                journals engine_handshake_bypass (a forced write is never invisible).
#   READS WARN — herd_engine_warn_if_stale never refuses (returns 0) on the same stale stamp.
#   DOCTOR     — the advisory row reports outdated/current and the ENGINE_AUTOUPDATE posture.
#   MONOTONIC  — herd_engine_min_stamp raises ENGINE_MIN to the engine level, appends it when absent,
#                and NEVER lowers a higher floor a newer engine stamped elsewhere.
#   AUTOUPDATE — mode parsing (off|check|auto, garbage → off); auto dispatches `herd update` only when
#                stale, honors the cooldown, and journals refused (not done) when the update declines
#                — the builders-mid-flight case it reuses.
#   WIRING     — the four write paths (lane spawn preflight, herd-claim, scribe-step apply, `herd
#                backend switch`) actually call the guard; herd-claim's refusal is proven behaviorally.
#
# Fully hermetic: temp dirs only, journal redirected via JOURNAL_FILE, `herd update` replaced by a stub
# on a scoped PATH. NO herdr, NO gh, NO network, NO model, and nothing on the host is updated.
# No `set -e`: exit codes are asserted explicitly (the guard returns non-zero BY DESIGN).
# Run:  bash tests/test-engine-handshake.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
EV_SH="$REPO/scripts/herd/engine-version.sh"
CLAIM_SH="$REPO/scripts/herd/herd-claim.sh"
PREFLIGHT_SH="$REPO/scripts/herd/herd-preflight.sh"
SCRIBE_STEP_SH="$REPO/scripts/herd/scribe-step.sh"
HERD_BIN="$REPO/bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

for f in "$EV_SH" "$CLAIM_SH" "$PREFLIGHT_SH" "$SCRIBE_STEP_SH" "$HERD_BIN"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# ev <env-assignments…> -- <shell snippet> — source the mechanism in a FRESH bash and run the snippet.
# Each case is its own process, so a stale-stamp fixture can never leak into the next.
ev() {
  local env_prefix=() ; while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do env_prefix+=("$1"); shift; done
  shift || true
  # ${arr[@]+"${arr[@]}"} — an EMPTY array expansion is an unbound-variable error under bash 3.2 + set -u.
  env ${env_prefix[@]+"${env_prefix[@]}"} bash -c ". \"\$1\"; $*" _ "$EV_SH"
}

# STALE fixture: this engine is level 1; the project demands 3.
STALE=(HERD_ENGINE_LEVEL_FORCE=1 ENGINE_MIN=3)
# CURRENT fixture: engine level meets the floor exactly.
CURRENT=(HERD_ENGINE_LEVEL_FORCE=3 ENGINE_MIN=3)

# ── (1) INERT: no floor, or a current engine ⇒ the guard is a silent 0, nothing journaled ──────────
J="$T/j1.jsonl"
out="$(ev "JOURNAL_FILE=$J" HERD_ENGINE_LEVEL_FORCE=1 -- 'herd_engine_guard "lane spawn"' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(1) unset ENGINE_MIN must be inert, got rc=$rc"
[ -z "$out" ]   || fail "(1) unset ENGINE_MIN printed: [$out]"
out="$(ev "JOURNAL_FILE=$J" "${CURRENT[@]}" -- 'herd_engine_guard "lane spawn"' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(1) a current engine must pass the guard, got rc=$rc"
[ -z "$out" ]   || fail "(1) a current engine printed: [$out]"
[ ! -s "$J" ]   || fail "(1) a passing guard journaled: $(cat "$J")"
# An engine ABOVE the floor is current too, and a garbage floor never fabricates a lockout.
ev HERD_ENGINE_LEVEL_FORCE=9 ENGINE_MIN=3 -- 'herd_engine_guard w' >/dev/null 2>&1 || fail "(1) level 9 ≥ floor 3 refused"
ev HERD_ENGINE_LEVEL_FORCE=1 ENGINE_MIN=v2 -- 'herd_engine_guard w' >/dev/null 2>&1 || fail "(1) garbage ENGINE_MIN='v2' fabricated a lockout"
ev HERD_ENGINE_LEVEL_FORCE=1 ENGINE_MIN= -- 'herd_engine_guard w' >/dev/null 2>&1 || fail "(1) empty ENGINE_MIN fabricated a lockout"
ok

# ── (2) REFUSAL on a stale stamp: non-zero + the remedy text + a journaled refusal ─────────────────
J="$T/j2.jsonl"
out="$(ev "JOURNAL_FILE=$J" "${STALE[@]}" -- 'herd_engine_guard "herd-claim (my-slug)"' 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(2) a stale engine must REFUSE a write path (rc=0)"
case "$out" in *"run herd update"*) ;; *) fail "(2) refusal is missing the remedy text 'run herd update': [$out]" ;; esac
case "$out" in *"herd-claim (my-slug)"*) ;; *) fail "(2) refusal does not name the surface: [$out]" ;; esac
case "$out" in *"ENGINE_MIN"*) ;; *) fail "(2) refusal does not name ENGINE_MIN: [$out]" ;; esac
case "$out" in *"HERD_ENGINE_SKIP_HANDSHAKE"*) ;; *) fail "(2) refusal does not name the escape hatch: [$out]" ;; esac
grep -q '"event": *"engine_handshake_refused"' "$J" || fail "(2) refusal not journaled: $(cat "$J" 2>/dev/null)"
grep -q '"engine_level": *1' "$J" || fail "(2) refusal did not journal engine_level=1: $(cat "$J")"
grep -q '"engine_min": *3'   "$J" || fail "(2) refusal did not journal engine_min=3: $(cat "$J")"
# The refusal goes to STDERR (a lane's stdout is parsed).
out="$(ev "JOURNAL_FILE=$T/j2b.jsonl" "${STALE[@]}" -- 'herd_engine_guard w' 2>/dev/null)"
[ -z "$out" ] || fail "(2) refusal leaked to stdout: [$out]"
ok

# ── (3) ESCAPE HATCH: bypass returns 0, warns, and is JOURNALED ────────────────────────────────────
J="$T/j3.jsonl"
out="$(ev "JOURNAL_FILE=$J" "${STALE[@]}" HERD_ENGINE_SKIP_HANDSHAKE=1 -- 'herd_engine_guard "scribe-step apply (commit)"' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3) the escape hatch must let the write proceed (rc=$rc)"
case "$out" in *BYPASS*) ;; *) fail "(3) the bypass did not warn: [$out]" ;; esac
grep -q '"event": *"engine_handshake_bypass"' "$J" || fail "(3) bypass not journaled: $(cat "$J" 2>/dev/null)"
grep -q '"surface": *"scribe-step apply (commit)"' "$J" || fail "(3) bypass did not journal the surface: $(cat "$J")"
grep -q 'engine_handshake_refused' "$J" && fail "(3) a bypass must not also journal a refusal"
ok

# ── (4) READ paths WARN ONLY ───────────────────────────────────────────────────────────────────────
J="$T/j4.jsonl"
out="$(ev "JOURNAL_FILE=$J" "${STALE[@]}" -- 'herd_engine_warn_if_stale "herd status"' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(4) a read path must never refuse (rc=$rc)"
case "$out" in *"run herd update"*) ;; *) fail "(4) the read warning is missing the remedy: [$out]" ;; esac
out="$(ev "JOURNAL_FILE=$J" "${CURRENT[@]}" -- 'herd_engine_warn_if_stale "herd status"' 2>&1)"
[ -z "$out" ] || fail "(4) a current engine warned on a read: [$out]"
ok

# ── (5) DOCTOR row: advisory, reports outdated vs current + the autoupdate posture ─────────────────
out="$(ev "${STALE[@]}" ENGINE_AUTOUPDATE=auto -- 'herd_engine_doctor_row' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(5) the doctor row must be advisory (rc=$rc)"
case "$out" in *"engine outdated"*) ;; *) fail "(5) stale doctor row lacks 'engine outdated': [$out]" ;; esac
case "$out" in *"run herd update"*) ;; *) fail "(5) stale doctor row lacks the remedy: [$out]" ;; esac
case "$out" in *"ENGINE_AUTOUPDATE=auto"*) ;; *) fail "(5) doctor row does not report the mode: [$out]" ;; esac
out="$(ev "${CURRENT[@]}" -- 'herd_engine_doctor_row' 2>&1)"
case "$out" in *"engine current"*) ;; *) fail "(5) current doctor row lacks 'engine current': [$out]" ;; esac
case "$out" in *"engine outdated"*) fail "(5) a current engine reported outdated: [$out]" ;; esac
out="$(ev HERD_ENGINE_LEVEL_FORCE=2 -- 'herd_engine_doctor_row' 2>&1)"
case "$out" in *"pins no floor"*) ;; *) fail "(5) an unpinned project's row lacks the inert note: [$out]" ;; esac
ok

# ── (6) MONOTONIC ENGINE_MIN stamp (what `herd upgrade` writes) ────────────────────────────────────
# (a) absent key → appended at the engine's level.
cfg="$T/cfg-append"; printf 'HERD_VERSION=1\n' > "$cfg"
v="$(ev HERD_ENGINE_LEVEL_FORCE=4 -- "herd_engine_min_stamp '$cfg'")"
[ "$v" = 4 ] || fail "(6a) stamp on an absent key echoed [$v], want 4"
grep -qE '^ENGINE_MIN=4$' "$cfg" || fail "(6a) ENGINE_MIN=4 not appended: $(cat "$cfg")"
# (b) lower existing floor → RAISED in place, key not duplicated.
cfg="$T/cfg-raise"; printf 'HERD_VERSION=1\nENGINE_MIN=2\nHERD_THEME="x"\n' > "$cfg"
v="$(ev HERD_ENGINE_LEVEL_FORCE=5 -- "herd_engine_min_stamp '$cfg'")"
[ "$v" = 5 ] || fail "(6b) stamp echoed [$v], want 5"
grep -qE '^ENGINE_MIN=5$' "$cfg" || fail "(6b) floor not raised: $(cat "$cfg")"
[ "$(grep -cE '^ENGINE_MIN=' "$cfg")" -eq 1 ] || fail "(6b) ENGINE_MIN duplicated: $(cat "$cfg")"
grep -q 'HERD_THEME="x"' "$cfg" || fail "(6b) stamp clobbered another key: $(cat "$cfg")"
# (c) HIGHER existing floor → NEVER lowered (an old checkout must not un-pin the project).
cfg="$T/cfg-keep"; printf 'ENGINE_MIN=9\n' > "$cfg"
v="$(ev HERD_ENGINE_LEVEL_FORCE=2 -- "herd_engine_min_stamp '$cfg'")"
[ "$v" = 9 ] || fail "(6c) stamp echoed [$v], want the untouched 9"
grep -qE '^ENGINE_MIN=9$' "$cfg" || fail "(6c) a lower engine LOWERED the floor: $(cat "$cfg")"
ok

# ── (7) ENGINE_AUTOUPDATE mode parsing: off | check | auto, anything else → off ────────────────────
for pair in ":off" "off:off" "check:check" "auto:auto" "AUTO:off" "on:off" "yes:off"; do
  want="${pair#*:}"; set_to="${pair%%:*}"
  got="$(ev "ENGINE_AUTOUPDATE=$set_to" -- 'herd_engine_autoupdate_mode' 2>/dev/null)"
  [ "$got" = "$want" ] || fail "(7) ENGINE_AUTOUPDATE='$set_to' → mode [$got], want [$want]"
done
ok

# ── (8) AUTOUPDATE tick: dispatches only when auto AND stale; cooldown holds; refusal ≠ done ───────
# A stub `herd` on a scoped PATH records its argv; its exit code is the scenario's `herd update` verdict.
STUB="$T/stub"; mkdir -p "$STUB"
mk_herd() {  # mk_herd <exit-code>
  cat > "$STUB/herd" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$T/herd-calls"
exit $1
EOF
  chmod +x "$STUB/herd"
}
tick() {  # tick <extra env…> — one synchronous autoupdate tick with a fresh cooldown file
  env PATH="$STUB:$PATH" HERD_ENGINE_UPDATE_SYNC=1 "$@" bash -c '. "$1"; herd_engine_autoupdate_tick' _ "$EV_SH"
}
mk_herd 0; : > "$T/herd-calls"; J="$T/j8.jsonl"
# off + stale → nothing.
tick "JOURNAL_FILE=$J" "HERD_ENGINE_COOLDOWN_FILE=$T/cd-off" "${STALE[@]}" ENGINE_AUTOUPDATE=off
[ ! -s "$T/herd-calls" ] || fail "(8) ENGINE_AUTOUPDATE=off dispatched an update: $(cat "$T/herd-calls")"
# check + stale → still nothing (check NOTES, it never runs the update).
tick "JOURNAL_FILE=$J" "HERD_ENGINE_COOLDOWN_FILE=$T/cd-check" "${STALE[@]}" ENGINE_AUTOUPDATE=check
[ ! -s "$T/herd-calls" ] || fail "(8) ENGINE_AUTOUPDATE=check dispatched an update: $(cat "$T/herd-calls")"
# auto + CURRENT engine → nothing (staleness, not the mode, is the trigger).
tick "JOURNAL_FILE=$J" "HERD_ENGINE_COOLDOWN_FILE=$T/cd-cur" "${CURRENT[@]}" ENGINE_AUTOUPDATE=auto
[ ! -s "$T/herd-calls" ] || fail "(8) auto dispatched against a CURRENT engine: $(cat "$T/herd-calls")"
[ ! -s "$J" ] || fail "(8) an inert tick journaled: $(cat "$J")"
# auto + stale → dispatches `herd update`; success journals dispatched + done.
CD="$T/cd-auto"; tick "JOURNAL_FILE=$J" "HERD_ENGINE_COOLDOWN_FILE=$CD" "${STALE[@]}" ENGINE_AUTOUPDATE=auto
grep -qx 'update' "$T/herd-calls" || fail "(8) auto+stale did not run 'herd update': [$(cat "$T/herd-calls")]"
grep -q '"event": *"engine_autoupdate_dispatched"' "$J" || fail "(8) dispatch not journaled: $(cat "$J")"
grep -q '"event": *"engine_autoupdate_done"' "$J" || fail "(8) a successful update did not journal done: $(cat "$J")"
[ -s "$CD" ] || fail "(8) the cooldown was not stamped"
# COOLDOWN: an immediate second tick is a no-op (this is what stops a refusal hammering the remote).
: > "$T/herd-calls"
tick "JOURNAL_FILE=$J" "HERD_ENGINE_COOLDOWN_FILE=$CD" "${STALE[@]}" ENGINE_AUTOUPDATE=auto
[ ! -s "$T/herd-calls" ] || fail "(8) the cooldown did not hold: $(cat "$T/herd-calls")"
# ...and a 0-second cooldown lets the next tick through.
tick "JOURNAL_FILE=$J" "HERD_ENGINE_COOLDOWN_FILE=$CD" HERD_ENGINE_COOLDOWN_SECS=0 "${STALE[@]}" ENGINE_AUTOUPDATE=auto
grep -qx 'update' "$T/herd-calls" || fail "(8) an expired cooldown did not re-dispatch"
# REFUSAL: `herd update` declining (builders mid-flight / dirty engine checkout) journals refused, not done.
mk_herd 1; : > "$T/herd-calls"; J="$T/j8r.jsonl"
tick "JOURNAL_FILE=$J" "HERD_ENGINE_COOLDOWN_FILE=$T/cd-refuse" "${STALE[@]}" ENGINE_AUTOUPDATE=auto
grep -q '"event": *"engine_autoupdate_refused"' "$J" || fail "(8) a declined update did not journal refused: $(cat "$J")"
grep -q 'engine_autoupdate_done' "$J" && fail "(8) a declined update journaled done"
ok

# ── (9) WIRING: the four write paths cross the guard ───────────────────────────────────────────────
# Behavioral for herd-claim (the earliest gate a lane crosses): a stale stamp aborts the spawn even
# with the claim itself switched OFF — the lane never reaches new-feature.sh.
J="$T/j9.jsonl"
out="$(env "JOURNAL_FILE=$J" "${STALE[@]}" CLAIM_REQUIRED=off \
  bash -c '. "$1"; herd_claim_or_abort my-slug' _ "$CLAIM_SH" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(9) herd_claim_or_abort proceeded on a stale engine"
case "$out" in *"run herd update"*) ;; *) fail "(9) claim refusal lacks the remedy: [$out]" ;; esac
grep -q 'engine_handshake_refused' "$J" || fail "(9) the claim refusal was not journaled"
# ...and a CURRENT engine leaves the claim path byte-identical (CLAIM_REQUIRED=off ⇒ silent 0).
out="$(env "JOURNAL_FILE=$T/j9b.jsonl" "${CURRENT[@]}" CLAIM_REQUIRED=off \
  bash -c '. "$1"; herd_claim_or_abort my-slug' _ "$CLAIM_SH" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(9) a current engine broke the claim passthrough (rc=$rc)"
[ -z "$out" ]   || fail "(9) a current engine made the claim path chatty: [$out]"
# Behavioral for the lane spawn preflight: herd_preflight refuses BEFORE any herdr probe.
out="$(env "JOURNAL_FILE=$T/j9c.jsonl" "${STALE[@]}" PATH="$T/empty:$PATH" HERD_DRIVER=headless \
  bash -c '. "$1"; herd_preflight' _ "$PREFLIGHT_SH" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(9) herd_preflight passed a stale engine (headless early-return must not skip it)"
case "$out" in *"lane spawn preflight"*) ;; *) fail "(9) preflight refusal does not name its surface: [$out]" ;; esac
# HERD_SKIP_PREFLIGHT stays what it says on the tin: it skips the WHOLE guard.
env "${STALE[@]}" HERD_SKIP_PREFLIGHT=1 bash -c '. "$1"; herd_preflight' _ "$PREFLIGHT_SH" >/dev/null 2>&1 \
  || fail "(9) HERD_SKIP_PREFLIGHT=1 did not bypass the handshake"
# Static for the two paths whose behavioral drive needs a real project/backend: scribe-step's APPLY
# verbs and `herd backend switch` must each call the guard.
grep -q 'herd_engine_guard "scribe-step apply' "$SCRIBE_STEP_SH" || fail "(9) scribe-step.sh does not guard its apply verbs"
grep -qE '^  commit\|add-item\|update-state\|amend\)' "$SCRIBE_STEP_SH" || fail "(9) scribe-step.sh guards the wrong verb set"
grep -q 'herd_engine_guard "herd backend switch"' "$HERD_BIN" || fail "(9) bin/herd does not guard the backend switch"
grep -q 'herd_engine_warn_if_stale "herd status"' "$HERD_BIN" || fail "(9) bin/herd does not warn on the status read path"
grep -q 'herd_engine_min_stamp "\$cfg"' "$HERD_BIN" || fail "(9) herd upgrade does not stamp ENGINE_MIN"
ok

# ── (10) The engine's OWN stamp is coherent: herdkit's .herd/config floor is met by this checkout ──
# A merge that raises _HERD_ENGINE_LEVEL without stamping .herd/config (or the reverse) would lock the
# herd out of its own repo. Guard both directions here rather than discover it in a lane.
lvl="$(ev -- 'herd_engine_level')"
min="$(ev -- "_herd_engine_min_in_file '$REPO/.herd/config'")"
[ "$lvl" -ge "$min" ] || fail "(10) this checkout (engine level $lvl) is STALE against its own .herd/config ENGINE_MIN=$min"
[ "$min" -gt 0 ] || fail "(10) herdkit's own .herd/config pins no ENGINE_MIN floor — the dogfood project must exercise the handshake"
ok

echo "ALL PASS ($pass checks)"
