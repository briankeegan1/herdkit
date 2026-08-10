#!/usr/bin/env bash
# core-surface.sh — THE shared CORE-SURFACE implementation (HERD-577): which diffs touch the
# engine's load-bearing core, which sandbox-sim scenario proves each touched seam, and whether the
# scorecard that sim emitted says `result=pass`.
#
# THE BLAST-RADIUS INSIGHT this file exists to act on: every compound failure herdkit has had lives in
# roughly SIX load-bearing files — the gate loop / dispatch / verdict-cache regions of
# scripts/herd/agent-watch.sh, pysrc/herd/live_runtime.py's decide + health paths,
# pysrc/herd/ci_verdict.py, scripts/herd/healthcheck.sh, .herd/healthcheck.project.sh and
# scripts/herd/herd-review.sh's dispatch — while 40+ other merges per week flow through the same gate
# harmlessly. A uniform gate therefore spends the same proof budget on a TSV row edit and on a rewrite
# of the merge decision. CORE_SURFACE_GLOB names that core, and a diff that matches it must carry a
# GREEN sandbox-sim scorecard before it may merge.
#
# ONE implementation, three enforcement surfaces (docs/multi-seat-doctrine.md Rule 2 — a second
# hand-rolled glob match is exactly how two surfaces come to disagree about what "core" means):
#   • pysrc/herd/live_runtime.py — the watcher's gate leg (`LiveGates.core_surface`) EXECUTES this
#     file (`core-surface.sh paths|run`), never re-deriving the match or the seam→scenario map;
#   • scripts/herd/agent-watch.sh — the console rows (a live core-sim worker, a serialized hold)
#     SOURCE it for `herd_core_surface_enabled`;
#   • tests/test-core-surface.sh — the hermetic proof, which sources the pure functions directly.
# Sourced-library precedent: caps-sync-lint.sh / review-pregate.sh / health-trust.sh.
#
# SHIP-DORMANT: an EMPTY (or unset) CORE_SURFACE_GLOB is the feature OFF. Every function below then
# answers "not core" without reading a diff, the gate leg never runs, no marker is written and no
# `core_surface_*` event is journaled — byte-identical to before this file existed.
#
# FAIL-SOFT, NEVER SILENT: a scenario script that is not present in the tree is SKIPPED with a loud
# note carried into the verdict detail (and, one level up, into the journal) — never a silent pass.
# A run in which EVERY required scenario was absent reports SKIP, not PASS, so "we proved nothing"
# can never read as "we proved it".
#
# ── the API ───────────────────────────────────────────────────────────────────────────────────────
# herd_core_surface_glob
#   Echo the effective CORE_SURFACE_GLOB (empty ⇒ feature off). The ONE resolver: every other
#   function and every caller goes through it.
#
# herd_core_surface_enabled
#   Exit 0 iff the glob is non-empty. No I/O.
#
# herd_core_surface_paths <tree> [<base-ref>]
#   Print, one per line, the tree's changed paths (vs <base-ref>, default $DEFAULT_BRANCH/main) that
#   MATCH the glob. Exit: 0 = at least one match · 1 = no match (or feature off) · 2 = skipped
#   (not a git tree / no diff computable — never a red, the caller decides).
#
# herd_core_surface_scenarios <path...>
#   Print the sim scenario BASENAMES the given core paths require, deduped, in a stable order
#   (the seam map below). A core path that maps to no specific seam yields the GATE scenario — the
#   fail-toward-more-proof default.
#
# herd_core_surface_scorecard_ok <scorecard.json>
#   Exit 0 iff the file exists and its top-level "result" is "pass". jq-free (the sandbox scorecard
#   writer emits a fixed one-key-per-line shape; tests/test-sandbox-*.sh read it the same way).
#
# herd_core_surface_run <artifacts-dir> <out-file> <log-file> <nonce> <scenario-basename>...
#   THE WORKER BODY. Runs each named scenario under a hard timeout with its own artifacts dir, reads
#   each scorecard, and writes ONE line to <out-file>: "<nonce>\t<PASS|FAIL|SKIP>\t<detail>". Also the
#   `run` CLI verb, which is how live_runtime.py dispatches it as a detached child.
#
# CLI (executed, not sourced — this is what the Python core spawns):
#   core-surface.sh glob
#   core-surface.sh paths     <tree> [<base-ref>]
#   core-surface.sh scenarios <tree> [<base-ref>]
#   core-surface.sh scenarios-for <core-path>...     (the map alone, for an already-resolved match)
#   core-surface.sh verify    <scorecard.json>
#   core-surface.sh run       <artifacts-dir> <out> <log> <nonce> <scenario>...
#
# Env seams (NOT config keys — ops/test knobs with built-in defaults, mirroring HERD_REVIEW_BIN):
#   HERD_CORE_SURFACE_SIM_DIR   where the scenarios live (default: <this dir>/sim). The hermetic
#                               suite points it at a stub dir so the gate is proven without paying
#                               for a real multi-minute sandbox run.
#   HERD_CORE_SURFACE_TIMEOUT   per-scenario hard timeout in seconds (default 1800). A sim that hangs
#                               must never wedge the gate rail — it FAILS the scorecard instead.

_HERD_CORE_SURFACE_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The scenario the seam map falls back to: the end-to-end gate walk (init → build → PR → gate →
# merge → teardown). Any core path with no more specific seam gets THIS, because the gate loop is
# what every core file ultimately participates in.
HERD_CORE_SURFACE_GATE_SCENARIO="sandbox-scenario.sh"

# ── the ONE glob resolver ─────────────────────────────────────────────────────────────────────────
herd_core_surface_glob() {
  printf '%s' "${CORE_SURFACE_GLOB:-}"
}

herd_core_surface_enabled() {
  [ -n "$(herd_core_surface_glob)" ]
}

# _herd_core_surface_simdir — where the scenarios live.
_herd_core_surface_simdir() {
  printf '%s' "${HERD_CORE_SURFACE_SIM_DIR:-$_HERD_CORE_SURFACE_HERE/sim}"
}

# ── seam map: core path → the sandbox-sim scenario that proves it ─────────────────────────────────
# Deliberately a CASE STATEMENT and not a TSV: it is a property of the engine's own file layout, read
# by exactly one function, and a manifest file would need its own caps row + drift guard to say the
# same thing. The four seams are the ones the sandbox rig actually models (gate / concurrency /
# limit / panes — scripts/herd/sim/README-sandbox-sim.md).
_herd_core_surface_scenario_for() {
  case "$1" in
    # CONCURRENCY seam — slot budgets, leases, fan-out, shard selection. A change here is exactly the
    # class the 2026-07-12 double-dispatch regression came from.
    */capacity-ledger.sh|*/capacity-agent-lease-wait.sh|*/burst.sh|*/suite-shard.sh|*/herd-spawn-gate.sh)
      printf 'sandbox-concurrency-scenario.sh' ;;
    # LIMIT seam — usage-limit park + auto-resume.
    */agent-update.sh|*/driver.sh)
      printf 'sandbox-limit-resume-scenario.sh' ;;
    # PANES seam — anything whose product is a pane/tab in the control room.
    */herd-feature.sh|*/herd-quick.sh|*/resolver-pane.sh|*/tab-discipline.sh|*/coordinator.sh|*/herd-watch.sh)
      printf 'sandbox-real-panes-scenario.sh' ;;
    # GATE seam — the load-bearing six, and the fail-toward-more-proof default for everything else
    # the operator's glob chose to call core.
    *)
      printf '%s' "$HERD_CORE_SURFACE_GATE_SCENARIO" ;;
  esac
}

# herd_core_surface_scenarios <path...> — deduped, stable-ordered scenario basenames.
herd_core_surface_scenarios() {
  local _cs_p _cs_s _cs_seen=""
  for _cs_p in "$@"; do
    [ -n "$_cs_p" ] || continue
    _cs_s="$(_herd_core_surface_scenario_for "$_cs_p")"
    case " $_cs_seen " in *" $_cs_s "*) continue ;; esac
    _cs_seen="$_cs_seen $_cs_s"
  done
  # Stable order regardless of the diff's path order: two seats gating the same sha must dispatch the
  # same argv, or the nonce-keyed result of one is not the result of the other.
  printf '%s\n' $_cs_seen | sed '/^$/d' | LC_ALL=C sort
}

# ── the match ─────────────────────────────────────────────────────────────────────────────────────
# herd_core_surface_paths <tree> [<base-ref>]
herd_core_surface_paths() {
  local _cp_tree="${1:-}" _cp_base="${2:-${DEFAULT_BRANCH:-main}}" _cp_glob _cp_mb _cp_changed
  _cp_glob="$(herd_core_surface_glob)"
  [ -n "$_cp_glob" ] || return 1                      # feature off — never even opens the tree
  [ -n "$_cp_tree" ] && [ -d "$_cp_tree" ] || return 2
  git -C "$_cp_tree" rev-parse --git-dir >/dev/null 2>&1 || return 2
  # Merge-base scoped, exactly like the heavy/light router (healthcheck.sh) and the stale-base gate:
  # "what THIS branch changed", never "how this branch differs from a base that has moved on".
  _cp_mb="$(git -C "$_cp_tree" merge-base "$_cp_base" HEAD 2>/dev/null)"
  [ -n "$_cp_mb" ] || _cp_mb="$_cp_base"
  _cp_changed="$(git -C "$_cp_tree" diff --name-only "$_cp_mb" HEAD 2>/dev/null)" || return 2
  # Uncommitted AND untracked work counts too: a builder running this locally is asking about the
  # change it HAS, not the one it has already committed — and a brand-new core file is untracked
  # until the very last commit. Both are empty on a clean checked-out tree, so a watcher-side call
  # (which always reads a committed head) is unaffected.
  _cp_changed="$_cp_changed
$(git -C "$_cp_tree" diff --name-only HEAD 2>/dev/null)
$(git -C "$_cp_tree" ls-files --others --exclude-standard 2>/dev/null)"
  _cp_changed="$(printf '%s\n' "$_cp_changed" | sed '/^$/d' | LC_ALL=C sort -u)"
  [ -n "$_cp_changed" ] || return 1
  # grep the STRING, never `printf | grep -q` (HERD-299 pipe-safety): a producer piped into an
  # early-exiting grep takes EPIPE and goes nonzero under the caller's `set -o pipefail`.
  local _cp_hits
  _cp_hits="$(grep -E "$_cp_glob" <<<"$_cp_changed" 2>/dev/null)"
  [ -n "$_cp_hits" ] || return 1
  printf '%s\n' "$_cp_hits"
}

# ── the scorecard read ────────────────────────────────────────────────────────────────────────────
# herd_core_surface_scorecard_ok <file> — exit 0 iff top-level "result" is "pass".
herd_core_surface_scorecard_ok() {
  local _sc_f="${1:-}" _sc_line
  [ -n "$_sc_f" ] && [ -s "$_sc_f" ] || return 1
  # grep the FILE with -m1 (never `grep … | head`): a producer piped into an early-exiting head
  # takes EPIPE and goes nonzero under a caller's `set -o pipefail` (HERD-299).
  _sc_line="$(grep -m 1 -E '^[[:space:]]*"result"[[:space:]]*:' "$_sc_f" 2>/dev/null)"
  case "$_sc_line" in *'"pass"'*) return 0 ;; esac
  return 1
}

# herd_core_surface_scorecard_result <file> — echo the recorded result token, or "missing".
herd_core_surface_scorecard_result() {
  local _sr_f="${1:-}" _sr_line _sr_val
  [ -n "$_sr_f" ] && [ -s "$_sr_f" ] || { printf 'missing'; return 0; }
  _sr_line="$(grep -m 1 -E '^[[:space:]]*"result"[[:space:]]*:' "$_sr_f" 2>/dev/null)"
  _sr_val="$(printf '%s' "$_sr_line" | sed -n 's/.*:[[:space:]]*"\([^"]*\)".*/\1/p')"
  printf '%s' "${_sr_val:-unreadable}"
}

# ── the worker ────────────────────────────────────────────────────────────────────────────────────
# herd_core_surface_run <artifacts-dir> <out> <log> <nonce> <scenario>...
#
# Writes exactly ONE line to <out>: "<nonce>\t<verdict>\t<detail>" where verdict is
#   PASS  every required scenario RAN and its scorecard says result=pass
#   FAIL  at least one scenario ran and did NOT say result=pass (or timed out)
#   SKIP  NOTHING ran — every required scenario is absent from this tree (loud, never a pass)
# The nonce is echoed as the first field so the collector can prove the file belongs to THIS dispatch
# (HERD-349's freshness guard, the same contract the health worker honours).
herd_core_surface_run() {
  local _cr_art="${1:-}" _cr_out="${2:-}" _cr_log="${3:-}" _cr_nonce="${4:-}"
  shift 4 || true
  local _cr_dir _cr_s _cr_path _cr_card _cr_rc _cr_res
  local _cr_ran=0 _cr_bad="" _cr_absent="" _cr_secs
  _cr_dir="$(_herd_core_surface_simdir)"
  _cr_secs="${HERD_CORE_SURFACE_TIMEOUT:-1800}"
  case "$_cr_secs" in ''|*[!0-9]*) _cr_secs=1800 ;; esac
  mkdir -p "$_cr_art" 2>/dev/null || true
  : > "$_cr_log" 2>/dev/null || true

  for _cr_s in "$@"; do
    [ -n "$_cr_s" ] || continue
    _cr_path="$_cr_dir/$_cr_s"
    if [ ! -f "$_cr_path" ]; then
      # FAIL-SOFT, NEVER SILENT: absence is recorded in the log AND carried into the detail below.
      printf '[core-surface] SKIP %s — not present at %s\n' "$_cr_s" "$_cr_path" >> "$_cr_log" 2>/dev/null || true
      _cr_absent="${_cr_absent:+$_cr_absent,}$_cr_s"
      continue
    fi
    printf '[core-surface] RUN %s (timeout %ss)\n' "$_cr_s" "$_cr_secs" >> "$_cr_log" 2>/dev/null || true
    _cr_ran=$((_cr_ran + 1))
    if command -v timeout >/dev/null 2>&1; then
      timeout "$_cr_secs" bash "$_cr_path" --artifacts "$_cr_art/${_cr_s%.sh}" >> "$_cr_log" 2>&1
      _cr_rc=$?
    else
      # No coreutils `timeout` (a bare macOS box): run it unbounded rather than not at all — the
      # scorecard read below is still the verdict, and the marker's own liveness check upstream is
      # what keeps a dead worker from wedging the rail.
      bash "$_cr_path" --artifacts "$_cr_art/${_cr_s%.sh}" >> "$_cr_log" 2>&1
      _cr_rc=$?
    fi
    _cr_card="$_cr_art/${_cr_s%.sh}/scorecard.json"
    _cr_res="$(herd_core_surface_scorecard_result "$_cr_card")"
    printf '[core-surface] %s rc=%s result=%s\n' "$_cr_s" "$_cr_rc" "$_cr_res" >> "$_cr_log" 2>/dev/null || true
    # The SCORECARD is the verdict (task HERD-577: "fold scorecard.json result=pass into the
    # verdict"), not the exit code — but an exit code with no scorecard at all is a fail, not a pass.
    herd_core_surface_scorecard_ok "$_cr_card" || _cr_bad="${_cr_bad:+$_cr_bad,}$_cr_s=$_cr_res"
  done

  local _cr_verdict _cr_detail
  if [ "$_cr_ran" -eq 0 ]; then
    _cr_verdict="SKIP"
    _cr_detail="no sandbox-sim scenario present (${_cr_absent:-none required}) — nothing was proven"
  elif [ -n "$_cr_bad" ]; then
    _cr_verdict="FAIL"
    _cr_detail="scorecard not green: $_cr_bad"
    [ -n "$_cr_absent" ] && _cr_detail="$_cr_detail · absent: $_cr_absent"
  else
    _cr_verdict="PASS"
    _cr_detail="$_cr_ran scenario(s) green"
    [ -n "$_cr_absent" ] && _cr_detail="$_cr_detail · absent (SKIPPED, not proven): $_cr_absent"
  fi
  # Tabs and newlines would break the collector's single-line "<nonce>\t<verdict>\t<detail>" contract.
  _cr_detail="$(printf '%s' "$_cr_detail" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\n' "$_cr_nonce" "$_cr_verdict" "${_cr_detail:0:300}" \
    > "$_cr_out.tmp.$$" 2>/dev/null && mv "$_cr_out.tmp.$$" "$_cr_out" 2>/dev/null || true
  [ "$_cr_verdict" = "PASS" ]
}

# ── CLI ───────────────────────────────────────────────────────────────────────────────────────────
# Executed form only. Sourcing this file defines the functions and runs nothing.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _cs_verb="${1:-}"; shift || true
  case "$_cs_verb" in
    glob)      herd_core_surface_glob; printf '\n' ;;
    paths)     herd_core_surface_paths "$@" ;;
    scenarios)
      _cs_paths="$(herd_core_surface_paths "$@")" || exit $?
      _cs_arr=()
      while IFS= read -r _cs_line; do [ -n "$_cs_line" ] && _cs_arr+=("$_cs_line"); done <<<"$_cs_paths"
      herd_core_surface_scenarios "${_cs_arr[@]}" ;;
    scenarios-for) herd_core_surface_scenarios "$@" ;;
    verify)    herd_core_surface_scorecard_ok "$@" ;;
    run)       herd_core_surface_run "$@" ;;
    *)
      echo "usage: core-surface.sh glob | paths <tree> [<base-ref>] | scenarios <tree> [<base-ref>] | scenarios-for <path>... | verify <scorecard.json> | run <art> <out> <log> <nonce> <scenario>..." >&2
      exit 64 ;;
  esac
fi
