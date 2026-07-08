#!/usr/bin/env bash
# test-config-local-overlay.sh — hermetic tests for the .herd/config.local per-user overlay (HERD-47).
#
# Covers the four contracts from the task spec plus machine-scope auto-routing:
#   (a) ABSENT config.local ⇒ effective config is byte-identical to a single-file setup (an EMPTY
#       overlay changes nothing) — the loader (scripts/herd/herd-config.sh) precedence.
#   (b) a key set in config.local OVERRIDES the baseline; a key it leaves unset keeps the baseline.
#   (c) `herd config set --local KEY VAL` writes to .herd/config.local, NOT .herd/config; a
#       machine-scoped key routes to the overlay even WITHOUT --local; a project key defaults to the
#       baseline.
#   (d) `herd config list` shows each effective value's PROVENANCE (baseline | local | local-only).
#
# Fully hermetic: local temp only, NO herdr/gh/network/model. Mirrors the stubbing in
# test-cli-config.sh (pgrep + herdr stubbed on PATH; HERD_CAPABILITIES_FILE → a stub manifest that
# carries the 6th `scope` column) and the loader-sourcing style of test-herd-config.sh.
# Run:  bash tests/test-config-local-overlay.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"
LOADER="$HERE/../scripts/herd/herd-config.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; okp(){ pass=$((pass+1)); }

# ── Stub pgrep + herdr on PATH (so any watcher-key reload path stays hermetic) ─
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
IFS=':' read -ra pids <<< "${FAKE_STRAY_PIDS:-}"
for p in "${pids[@]}"; do [ -n "$p" ] && printf '%s\n' "$p"; done
exit 0
STUB
chmod +x "$BIN/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

# ── Stub capabilities manifest (6-column: name kind description when requires scope) ─
# MODEL_QUICK is machine-scoped with NO requires (a clean auto-route case: no watcher/render side
# effects). SCRIBE_BACKEND is project-scoped with no requires. WORKSPACE_NAME is machine+watcher.
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\n'
  printf 'WORKSPACE_NAME\tconfig\tProject label\tAlways\twatcher\tmachine\n'
  printf 'REVIEW_CONCURRENCY\tconfig\tParallel reviews\tRaise\twatcher\n'
  printf 'MODEL_QUICK\tconfig\tQuick-lane model tier\tPer-user cost/quality\t\tmachine\n'
  printf 'SCRIBE_BACKEND\tconfig\tTracker backend\tSet for a tracker\t\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

# ── project fixture ───────────────────────────────────────────────────────────
_make_project() {
  local r="$1"; local r_real; r_real="$(cd "$r" && pwd -P)"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  ( cd "$r" && git commit -q --allow-empty -m init )
  mkdir -p "$r/.herd" "$r/trees"
  cat > "$r/.herd/config" <<CFG
# .herd/config — baseline fixture (comment preserved on purpose)
HERD_VERSION=1
PROJECT_ROOT="$r_real"
WORKTREES_DIR="$r_real/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="baselinews"
SCRIBE_BACKEND="file"
MODEL_QUICK="claude-baseline"
REVIEW_CONCURRENCY="2"
CFG
}

# run <ROOT> <args...> → `herd <args>` in ROOT; combined output → $OUT, exit → $RC.
run() {
  local r="$1"; shift
  set +e
  OUT="$( cd "$r" && HERD_RELOAD_SKIP_LAUNCH=1 HERD_RELOAD_SIGTERM_POLLS=3 FAKE_STRAY_PIDS="" \
           bash "$HERD" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ══════════════════════════════════════════════════════════════════════════════
# LOADER contracts (a) + (b) — source herd-config.sh with/without an overlay.
# ══════════════════════════════════════════════════════════════════════════════
# dump_effective <baseline> <local-or-empty> → echo the effective MODEL_QUICK / SCRIBE_BACKEND /
# WORKSPACE_NAME after sourcing the loader, from a cwd with no .herd/config above it.
dump_effective() {
  local base="$1" loc="$2"
  ( cd "$T" && HERD_CONFIG_FILE="$base" HERD_LOCAL_UNDER_TEST="$loc" bash -c '
      # Place config.local (if any) as the SIBLING the loader looks for.
      if [ -n "$HERD_LOCAL_UNDER_TEST" ]; then
        cp "$HERD_LOCAL_UNDER_TEST" "$(dirname "$HERD_CONFIG_FILE")/config.local"
      else
        rm -f "$(dirname "$HERD_CONFIG_FILE")/config.local"
      fi
      . "'"$LOADER"'"
      echo "MODEL_QUICK=$MODEL_QUICK"
      echo "SCRIBE_BACKEND=$SCRIBE_BACKEND"
      echo "WORKSPACE_NAME=$WORKSPACE_NAME"
    ' )
}

LB="$T/base"; mkdir -p "$LB/.herd"
cat > "$LB/.herd/config" <<'CFG'
WORKSPACE_NAME="baselinews"
SCRIBE_BACKEND="file"
MODEL_QUICK="claude-baseline"
CFG

# (a) No overlay vs an EMPTY overlay ⇒ identical effective config (backward-compatible).
no_overlay="$(dump_effective "$LB/.herd/config" "")"
EMPTY="$T/empty.local"; : > "$EMPTY"
empty_overlay="$(dump_effective "$LB/.herd/config" "$EMPTY")"
[ "$no_overlay" = "$empty_overlay" ] || fail "(a) empty config.local changed the effective config:
--- no overlay ---
$no_overlay
--- empty overlay ---
$empty_overlay"
printf '%s\n' "$no_overlay" | grep -qx 'MODEL_QUICK=claude-baseline' || fail "(a) baseline MODEL_QUICK not effective ($no_overlay)"
okp

# (b) An overlay override wins; a key it does NOT set keeps the baseline value.
OV="$T/override.local"
cat > "$OV" <<'CFG'
MODEL_QUICK="claude-local-override"
CFG
ov_out="$(dump_effective "$LB/.herd/config" "$OV")"
printf '%s\n' "$ov_out" | grep -qx 'MODEL_QUICK=claude-local-override' || fail "(b) overlay did NOT override MODEL_QUICK ($ov_out)"
printf '%s\n' "$ov_out" | grep -qx 'SCRIBE_BACKEND=file'               || fail "(b) non-overridden SCRIBE_BACKEND lost its baseline value ($ov_out)"
okp

# ══════════════════════════════════════════════════════════════════════════════
# CLI contract (c) — routing of `herd config set`.
# ══════════════════════════════════════════════════════════════════════════════
# (c1) --local on a PROJECT key writes to config.local, leaves the baseline untouched.
P="$T/p1"; mkdir "$P"; _make_project "$P"
run "$P" config set --local SCRIBE_BACKEND github
[ "$RC" -eq 0 ]                                             || fail "(c1) set --local failed ($OUT)"
[ -f "$P/.herd/config.local" ]                             || fail "(c1) config.local was not created"
grep -qE '^SCRIBE_BACKEND="github"' "$P/.herd/config.local" || fail "(c1) value not written to config.local ($(cat "$P/.herd/config.local"))"
grep -qE '^SCRIBE_BACKEND="file"'   "$P/.herd/config"       || fail "(c1) baseline SCRIBE_BACKEND was mutated"
printf '%s\n' "$OUT" | grep -q 'config.local'              || fail "(c1) output did not name config.local ($OUT)"
okp

# (c2) A MACHINE-scoped key routes to config.local even WITHOUT --local; baseline untouched.
run "$P" config set MODEL_QUICK claude-machine
[ "$RC" -eq 0 ]                                             || fail "(c2) machine-key set failed ($OUT)"
grep -qE '^MODEL_QUICK="claude-machine"' "$P/.herd/config.local" || fail "(c2) machine key not routed to config.local"
grep -qE '^MODEL_QUICK="claude-baseline"' "$P/.herd/config"      || fail "(c2) baseline MODEL_QUICK was mutated"
okp

# (c3) A PROJECT key WITHOUT --local writes to the baseline, not the overlay.
run "$P" config set SCRIBE_BACKEND changelog
[ "$RC" -eq 0 ]                                             || fail "(c3) project-key set failed ($OUT)"
grep -qE '^SCRIBE_BACKEND="changelog"' "$P/.herd/config"    || fail "(c3) project key not written to baseline"
# config.local still holds the earlier --local override (untouched by this baseline write).
grep -qE '^SCRIBE_BACKEND="github"' "$P/.herd/config.local" || fail "(c3) baseline write leaked into config.local"
okp

# (c4) idempotent no-op set against the overlay is inert (reads the TARGET, not the baseline).
run "$P" config set MODEL_QUICK claude-machine
{ [ "$RC" -eq 0 ] && printf '%s\n' "$OUT" | grep -qi 'no change'; } || fail "(c4) repeat machine set not a no-op ($OUT)"
okp

# ══════════════════════════════════════════════════════════════════════════════
# CLI contract (d) — provenance in `herd config list`.
# ══════════════════════════════════════════════════════════════════════════════
# Baseline: SCRIBE_BACKEND=changelog (project). Overlay: SCRIBE_BACKEND=github (override) +
# MODEL_QUICK=claude-machine (also in baseline → override) + a LOCAL-ONLY key not in the baseline.
P2="$T/p2"; mkdir "$P2"; _make_project "$P2"
cat > "$P2/.herd/config.local" <<'CFG'
SCRIBE_BACKEND="github"
WORKSPACE_NAME="localws"
CFG
run "$P2" config list
[ "$RC" -eq 0 ] || fail "(d) list failed ($OUT)"
# A baseline-only key is tagged [baseline].
printf '%s\n' "$OUT" | grep -qE 'REVIEW_CONCURRENCY[[:space:]]+2[[:space:]]+\[baseline\]' \
  || fail "(d) baseline key missing [baseline] provenance ($OUT)"
# An overridden key shows the LOCAL value tagged [local].
printf '%s\n' "$OUT" | grep -qE 'SCRIBE_BACKEND[[:space:]]+github[[:space:]]+\[local\]' \
  || fail "(d) overridden key missing [local] provenance / wrong value ($OUT)"
printf '%s\n' "$OUT" | grep -qE 'WORKSPACE_NAME[[:space:]]+localws[[:space:]]+\[local\]' \
  || fail "(d) overridden WORKSPACE_NAME missing [local] provenance ($OUT)"
# The header notes the overlay is active.
printf '%s\n' "$OUT" | grep -q 'config.local overlay' || fail "(d) list header did not note the overlay ($OUT)"
okp

# (d2) a key present ONLY in the overlay is tagged [local-only].
cat >> "$P2/.herd/config.local" <<'CFG'
MODEL_QUICK="claude-onlylocal"
CFG
# Remove MODEL_QUICK from the baseline so it is genuinely local-only.
grep -v '^MODEL_QUICK=' "$P2/.herd/config" > "$P2/.herd/config.tmp" && mv "$P2/.herd/config.tmp" "$P2/.herd/config"
run "$P2" config list
printf '%s\n' "$OUT" | grep -qE 'MODEL_QUICK[[:space:]]+claude-onlylocal[[:space:]]+\[local-only\]' \
  || fail "(d2) local-only key missing [local-only] provenance ($OUT)"
okp

# (d3) with NO overlay, list is unchanged: every value tagged [baseline], no overlay header.
P3="$T/p3"; mkdir "$P3"; _make_project "$P3"
run "$P3" config list
[ "$RC" -eq 0 ] || fail "(d3) list failed ($OUT)"
printf '%s\n' "$OUT" | grep -q 'config.local overlay' && fail "(d3) overlay header shown without an overlay"
printf '%s\n' "$OUT" | grep -qE 'SCRIBE_BACKEND[[:space:]]+file[[:space:]]+\[baseline\]' \
  || fail "(d3) no-overlay list missing [baseline] provenance ($OUT)"
okp

# ══════════════════════════════════════════════════════════════════════════════
# CLI contract (e) — `herd config get` resolves through baseline+overlay (HERD-142).
# The BUG: cmd_config_get read only the committed baseline, so an overlaid key printed the baseline
# value (or empty when the key lived only in the overlay). Fix: baseline first, overlay OVERRIDES.
# ══════════════════════════════════════════════════════════════════════════════
# (e1) An OVERLAID key returns the overlay value; a NON-overlaid key returns the baseline value.
PG="$T/pg"; mkdir "$PG"; _make_project "$PG"
cat > "$PG/.herd/config.local" <<'CFG'
MODEL_QUICK="claude-local-get"
CFG
run "$PG" config get MODEL_QUICK
[ "$RC" -eq 0 ] || fail "(e1) get failed ($OUT)"
[ "$OUT" = "claude-local-get" ] || fail "(e1) overlaid key did not return the overlay value (got: $OUT)"
run "$PG" config get SCRIBE_BACKEND
{ [ "$RC" -eq 0 ] && [ "$OUT" = "file" ]; } || fail "(e1) non-overlaid key did not return the baseline value (got: $OUT)"
okp

# (e2) A key present ONLY in the overlay (absent from the baseline) returns the overlay value — the
# exact live repro (HUMAN_VERIFY_POLICY set local-only printed empty before the fix). Modeled here
# with MODEL_QUICK removed from the baseline so it is genuinely local-only.
PG2="$T/pg2"; mkdir "$PG2"; _make_project "$PG2"
grep -v '^MODEL_QUICK=' "$PG2/.herd/config" > "$PG2/.herd/config.tmp" && mv "$PG2/.herd/config.tmp" "$PG2/.herd/config"
cat > "$PG2/.herd/config.local" <<'CFG'
MODEL_QUICK="claude-only-in-overlay"
CFG
run "$PG2" config get MODEL_QUICK
{ [ "$RC" -eq 0 ] && [ "$OUT" = "claude-only-in-overlay" ]; } || fail "(e2) local-only key did not return the overlay value (got: $OUT)"
okp

# (e3) With NO config.local, get is byte-identical to before (pure baseline read).
PG3="$T/pg3"; mkdir "$PG3"; _make_project "$PG3"
[ ! -f "$PG3/.herd/config.local" ] || fail "(e3) fixture unexpectedly has a config.local"
run "$PG3" config get MODEL_QUICK
{ [ "$RC" -eq 0 ] && [ "$OUT" = "claude-baseline" ]; } || fail "(e3) no-overlay get did not return the baseline value (got: $OUT)"
okp

# (e4) An overlay that assigns the key the EMPTY string OVERRIDES a non-empty baseline (shell-source
# last-wins) — presence, not non-emptiness, decides the override.
PG4="$T/pg4"; mkdir "$PG4"; _make_project "$PG4"
printf 'MODEL_QUICK=""\n' > "$PG4/.herd/config.local"
run "$PG4" config get MODEL_QUICK
{ [ "$RC" -eq 0 ] && [ -z "$OUT" ]; } || fail "(e4) empty-string overlay did not override the baseline (got: $OUT)"
okp

echo "ALL PASS ($pass tests)"
