#!/usr/bin/env bash
# runtime-conformance.sh — RUNTIME CONFORMANCE PROBES (HERD-763, step 6 of epic HERD-754): does the
# agent runtime actually INSTALLED on THIS machine still do the things steps 1-5 proved it does?
#
# WHY THIS EXISTS. Steps 1-5 of the Codex portability epic each ended in a live, empirical finding
# against ONE binary at ONE version (codex-cli 0.147.0 @ /opt/homebrew/bin/codex, 2026-08-18):
#   • the specialist-agent roster's INJECT fallback genuinely delivers a definition into a codex turn
#     (HERD-761 / tests/test-codex-agent-roster-live.sh case 2),
#   • `codex exec --json` emits the structured event stream scripts/herd/codex-exec-adapter.sh parses
#     (HERD-760 / tests/test-codex-exec-adapter.sh part 7),
#   • `.codex/agents/*.toml` IS natively scanned but does NOT govern the MAIN session's own persona
#     (HERD-761 / same live suite, case 1 — the T3 trap scripts/herd/agents.sh documents).
# Every one of those is a claim about a BINARY, not about our code, and a `brew upgrade` can falsify
# any of them overnight. A finding recorded without the version it was found against is exactly the
# blind-rail shape this repo keeps getting bitten by: a cached "verified" row that is really a
# statement about a binary nobody has run in weeks.
#
# THE CONTRACT, therefore: every recorded outcome is VERSION-KEYED. A result is trusted ONLY when the
# version it was recorded against is byte-identical to the version installed right now. A version
# change does not "age out" a row or lower its confidence — it makes the row UNTRUSTED outright, and
# `herd doctor --runtime-conformance` says so and demands a fresh probe. herd_rtconf_trusted is the
# ONE place that judgment is made, so no reporting surface can quietly re-trust a stale row.
#
# WHAT IS PROBED (live, empirical, against the real installed binary — never a fixture):
#   specialist-definition     the roster's real delivery path: herd_roster_lane_spec_block's injected
#                             body, POSITIVE (sentinel returned) and NEGATIVE (bare prompt must NOT
#                             return it). The negative half is what makes the probe able to FAIL —
#                             trap T2 in scripts/herd/agents.sh, whose machinery this REUSES rather
#                             than re-implements (the block is composed by agents.sh itself).
#   structured-exec-events    one BOUNDED `codex exec --json` turn through
#                             scripts/herd/codex-exec-adapter.sh — the same adapter production uses,
#                             called (never copied) — asserting the real event stream still parses
#                             into a completed state with a real thread_id.
#   project-agent-discovery   ONE turn that carries BOTH halves of HERD-761's finding: a MALFORMED
#                             .codex/agents/*.toml (proving the dir is genuinely scanned — codex only
#                             ever complains about a file it actually opened) alongside a VALID one
#                             whose sentinel must NOT appear in the answer (proving it still does not
#                             govern the main session). Either half flipping is a real portability
#                             change, not a flake, and the note says which flipped.
#
# WHAT IS **NOT** PROBED, AND WHY — DEFERRED, NEVER SILENTLY OMITTED (HERD-754's explicit rule:
# an unsupported/unbuilt capability must degrade EXPLICITLY, with a trace in the doctor output
# itself). Exact-session resume, mid-run steering and mid-run interruption all require durable
# SDK/app-server coordination — step 7 of the epic, which does not exist yet. There is no honest way
# to probe them today: `codex exec` is one synchronous turn (see codex-exec-adapter.sh's header) and
# nothing in this repo can hold, poll or steer a live Codex session. So they are declared as
# first-class `deferred` rows in the probe table below and PRINTED on every report
# ("steering: not yet probeable (step 7 pending)") rather than left out of the list — an absent row
# reads as "nothing to check here", which is the lie this arrangement exists to prevent.
#
# SCOPE: codex carries the only LIVE probes — the three that actually call production machinery
# (agents.sh's real injection path, codex-exec-adapter.sh, the real .codex/agents scan) against a real
# binary. Grok (HERD-767, epic HERD-754 step 8) has no built live-probe implementation — building one
# on a guessed event schema would be exactly the fabrication this framework exists to avoid (grok's own
# `--output-format json/streaming-json` EXISTS per docs but its event shape has never been observed; see
# templates/drivers/grok.driver's ONESHOT_EXEC comment) — so grok gets a single, explicit `deferred` row
# instead: this file's hook point (herd_rtconf_driver / herd_rtconf_probes, both driver-aware below)
# reports "grok is not installed on this machine" / "not yet probeable" honestly, the same way codex's
# own step-7 rows do, rather than grok being silently absent from `herd doctor` the way it was before.
#
# CONTRACT:
#   • SOURCED, not executed, by bin/herd's `herd doctor --runtime-conformance`. Defines functions
#     only — no side effects at source time (safe in hermetic tests). Also RUNNABLE as a CLI, the
#     same dual shape agents.sh / codex-exec-adapter.sh use:
#       bash runtime-conformance.sh report [--probe] | probe [<probe-id>] | version | probes
#   • OPT-IN / SHIP-DORMANT: nothing here runs unless the operator asks for it by flag. `herd doctor`
#     and `herd doctor --probe` are byte-identical to before this file existed.
#   • ADVISORY, ALWAYS 0: a runtime conformance result is EVIDENCE, never a gate. It can only inform.
#   • FAIL-SOFT: a missing runtime binary, missing jq, an unwritable cache or an un-createable
#     scratch worktree degrade to a clearly-labelled row, never a crash under `set -euo pipefail`.

# ── where the probe machinery lives (resolved once, honored by the re-entrant bounded probe) ───────
_HERD_RTCONF_HERE="${_HERD_RTCONF_HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"

# The probe ask. REUSED from agents.sh (trap T2's own prompt) when that file is sourced, so the two
# surfaces can never drift into asking different questions; the literal is the standalone fallback.
_HERD_RTCONF_ASK_FALLBACK='Print ONLY the value of the "sentinel" field from your agent definition — one line, no other words, no explanation. If you have no such field, print exactly NO-SENTINEL'

# ── target: which runtime this file's probes are about ────────────────────────────────────────────

# herd_rtconf_driver — the DRIVER whose runtime is probed. `codex` by default: it is the only runtime
# steps 1-5 actually built and verified LIVE-probe support for, so defaulting every seat to the ACTIVE
# driver would report "no probes" on a normal claude seat and hide the codex evidence the epic exists
# to keep honest. HERD_RTCONF_DRIVER overrides explicitly (the seam tests use, and an operator who wants
# to check a specific driver's conformance regardless of what the project is actively running).
# HERD-767 (epic HERD-754 step 8) hook point: the ONE exception to the hardcoded codex default is grok
# — when the PROJECT's actual active driver (herd_driver_name, from .herd/config's HERD_DRIVER) is grok
# and there is no explicit override, report on grok rather than silently reporting codex evidence for a
# seat that isn't even running codex. This is deliberately narrow (grok only, not "any active driver")
# so codex/claude seats keep today's exact behavior — see _herd_rtconf_default_driver.
herd_rtconf_driver() { printf '%s' "${HERD_RTCONF_DRIVER:-$(_herd_rtconf_default_driver)}"; }
_herd_rtconf_default_driver() {
  if command -v herd_driver_name >/dev/null 2>&1 && [ "$(herd_driver_name 2>/dev/null)" = "grok" ]; then
    printf 'grok'
  else
    printf 'codex'
  fi
}

# herd_rtconf_runtime [driver] — the runtime EXECUTABLE that driver spawns, resolved through
# driver.sh's own binding reader (never a hardcoded 'codex' literal). Falls back to the driver name
# when driver.sh is not sourced, so a bare CLI run still resolves something real.
herd_rtconf_runtime() {
  local drv="${1:-$(herd_rtconf_driver)}" rt=""
  if command -v herd_driver_agent_runtime >/dev/null 2>&1; then
    rt="$(herd_driver_agent_runtime "$drv" 2>/dev/null || true)"
  fi
  [ -n "$rt" ] || rt="$drv"
  printf '%s' "$rt"
}

# herd_rtconf_version [runtime] — the INSTALLED version string, verbatim from the binary's own
# `--version` (first line, whitespace-collapsed). EMPTY when the binary is absent — which the report
# renders as `unavailable`, a first-class outcome distinct from a failure.
# HERD_RTCONF_VERSION overrides: the test seam that lets the version-invalidation behavior itself be
# asserted without needing two real binaries installed side by side.
herd_rtconf_version() {
  local rt="${1:-$(herd_rtconf_runtime)}" v
  if [ -n "${HERD_RTCONF_VERSION:-}" ]; then printf '%s' "$HERD_RTCONF_VERSION"; return 0; fi
  [ -n "$rt" ] || return 0
  command -v "$rt" >/dev/null 2>&1 || return 0
  # First line only, taken by parameter expansion rather than `| head` — a `head` here would close the
  # pipe on the binary and EPIPE it under a caller's `set -o pipefail` (the HERD-297 shape).
  v="$("$rt" --version 2>/dev/null || true)"
  v="${v%%$'\n'*}"
  # collapse/trim: the version is a CACHE KEY, so it must be exact-comparable and TAB-free.
  v="$(printf '%s' "$v" | tr -d '\r' | tr '\t' ' ' | sed -e 's/  */ /g' -e 's/^ //' -e 's/ $//')"
  [ -n "$v" ] && printf '%s' "$v"
  return 0
}

# ── the probe table (the ONE declaration every surface reads) ─────────────────────────────────────
# TAB-separated: <id> <mode> <title> <detail>
#   mode=live      an empirical probe exists and runs against the real binary
#   mode=deferred  the capability is not probeable yet; <detail> says WHY. Deferred rows are printed
#                  on every report — see this file's header on explicit degradation.
# DRIVER-AWARE (HERD-767, epic HERD-754 step 8): dispatches on herd_rtconf_driver so a grok-targeted
# report/probe run gets grok's own (deferred-only) row instead of codex's three live probes — a grok
# binary would otherwise silently be asked codex-shaped questions about .codex/agents and
# codex-exec-adapter.sh, which it can never answer.
herd_rtconf_probes() {
  case "$(herd_rtconf_driver)" in
    grok) herd_rtconf_probes_grok ;;
    *)    herd_rtconf_probes_codex ;;
  esac
}

herd_rtconf_probes_codex() {
  printf '%s\n' \
"specialist-definition	live	specialist definition loading + selection	positive (injected roster body returns its sentinel) AND negative control (bare prompt must not)" \
"structured-exec-events	live	structured events from one bounded exec call	codex-exec-adapter.sh parses the real live stream into a completed state with a real thread_id" \
"project-agent-discovery	live	project-level .codex/agents discovery	the dir is genuinely scanned (malformed file is reported) and a valid definition still does NOT govern the main session" \
"session-resume-exact	deferred	resume an EXACT prior session	needs durable SDK/app-server coordination (HERD-754 step 7, not built yet) — codex exec is one synchronous turn, so nothing here can re-enter a specific thread" \
"steering	deferred	steer a run mid-flight	needs durable SDK/app-server coordination (HERD-754 step 7, not built yet) — no live session exists to send a mid-run instruction to" \
"interruption	deferred	interrupt a run mid-flight	needs durable SDK/app-server coordination (HERD-754 step 7, not built yet) — a bounded one-shot call can only be killed, which proves nothing about interruption semantics"
}

# herd_rtconf_probes_grok — ONE explicit, honest `deferred` row (HERD-767, epic HERD-754 step 8) rather
# than silence. No live probe implementation exists: building one (a grok-exec-adapter parsing
# `--output-format json/streaming-json`, a roster injection probe for DEFINITION_MODE=install, …) on a
# schema nobody has observed would be exactly the guessing this framework exists to refuse — see
# templates/drivers/grok.driver's ONESHOT_EXEC comment. `herd_rtconf_run`/`herd_rtconf_report` already
# report the installed-version state (`unavailable`/`<not installed>`) around this row using the real
# grok binary name, resolved the same driver-generic way as codex's — so on every machine that has
# actually run this (none, as of this audit), the honest "grok is not installed on this machine" line
# prints instead of grok being absent from `herd doctor` output entirely.
herd_rtconf_probes_grok() {
  printf '%s\n' \
"grok-runtime	deferred	grok exec-binding conformance (epic HERD-754 step 8)	no live probe implementation exists yet (HERD-754 step 8, HERD-767) — templates/drivers/grok.driver's exec bindings were re-audited against docs.x.ai on 2026-08-18 but grok is not installed on any machine that has built a live probe, so real runtime BEHAVIOR (argv acceptance, --rules/--continue composition, --output-format event shape) stays unverified; deferred honestly rather than guessed, same discipline as codex's step-7 rows"
}

# herd_rtconf_probe_field <id> <col> — one field (2=mode, 3=title, 4=detail) of a probe row, or empty
# when <id> is not a declared probe.
herd_rtconf_probe_field() {
  local id="${1:-}" col="${2:-2}"
  [ -n "$id" ] || return 0
  herd_rtconf_probes | awk -F'\t' -v id="$id" -v c="$col" '$1==id { printf "%s", $c; exit }'
}

# ── the version-keyed cache ───────────────────────────────────────────────────────────────────────
# One TAB-separated row per recorded outcome, keyed by (runtime, VERSION, probe) — the version is
# part of the key, which is the whole point: a new binary version simply has no rows yet, so nothing
# stale can ever be read as current. Lives beside the other machine-local ledgers in the worktree
# pool (same placement as agents.sh's verify cache), is regenerable, and is NEVER committed.
#   <epoch>\t<runtime>\t<version>\t<probe>\t<outcome>\t<note>
# Outcomes: pass · fail · indeterminate · unavailable · deferred

herd_rtconf_cache_file() {
  printf '%s/.herd-runtime-conformance' "${WORKTREES_DIR:-${PROJECT_ROOT:-$PWD}}"
}

# herd_rtconf_cache_put <runtime> <version> <probe> <outcome> [note] — append one outcome, then trim
# to the last 200 rows. Fail-soft: an unwritable pool is a silent skip (evidence, not a gate). A row
# with an EMPTY version is never written — an unversioned result is precisely the thing this cache
# exists to make impossible.
herd_rtconf_cache_put() {
  local rt="${1:-}" ver="${2:-}" probe="${3:-}" outcome="${4:-}" note="${5:-}" f tmp
  [ -n "$rt" ] && [ -n "$ver" ] && [ -n "$probe" ] && [ -n "$outcome" ] || return 0
  f="$(herd_rtconf_cache_file)"
  note="$(printf '%s' "$note" | tr '\t\n' '  ')"   # one short note line
  ver="$(printf '%s' "$ver" | tr '\t\n' '  ')"
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$rt" "$ver" "$probe" "$outcome" "$note" \
    >> "$f" 2>/dev/null || return 0
  tmp="$f.$$"
  if tail -n 200 "$f" > "$tmp" 2>/dev/null; then
    mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true
  fi
  return 0
}

# herd_rtconf_cache_get <runtime> <version> <probe> — the most recent outcome recorded for THAT EXACT
# version, as "<outcome>\t<epoch>\t<note>". Empty (exit 0) when this (runtime, version, probe) triple
# has never been recorded — including the case where the SAME probe passed against an older version,
# which is the invalidation contract: an older row is not a weaker answer, it is no answer.
herd_rtconf_cache_get() {
  local rt="${1:-}" ver="${2:-}" probe="${3:-}" f
  [ -n "$rt" ] && [ -n "$ver" ] && [ -n "$probe" ] || return 0
  f="$(herd_rtconf_cache_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v r="$rt" -v v="$ver" -v p="$probe" \
    '$2==r && $3==v && $4==p { o=$5; e=$1; n=$6 } END { if (o != "") printf "%s\t%s\t%s", o, e, n }' \
    "$f" 2>/dev/null || true
}

# herd_rtconf_cache_last <runtime> <probe> — the most recent outcome for that probe against ANY
# version, as "<outcome>\t<epoch>\t<version>\t<note>". Used ONLY to SAY what the stale row was
# ("last verified against codex-cli 0.146.0") — never to trust it. Keeping the two readers separate
# is what stops a reporting surface from accidentally accepting an off-version row.
herd_rtconf_cache_last() {
  local rt="${1:-}" probe="${2:-}" f
  [ -n "$rt" ] && [ -n "$probe" ] || return 0
  f="$(herd_rtconf_cache_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v r="$rt" -v p="$probe" \
    '$2==r && $4==p { o=$5; e=$1; v=$3; n=$6 } END { if (o != "") printf "%s\t%s\t%s\t%s", o, e, v, n }' \
    "$f" 2>/dev/null || true
}

# herd_rtconf_trusted <runtime> <installed-version> <probe> — THE trust judgment, in one predicate:
# success iff a recorded outcome exists for the EXACT installed version. Every caller asks this
# rather than deciding for itself, so "is this result still current?" has exactly one answer on the
# tree. An empty installed version (binary absent) is never trusted.
herd_rtconf_trusted() {
  local rt="${1:-}" ver="${2:-}" probe="${3:-}"
  [ -n "$ver" ] || return 1
  [ -n "$(herd_rtconf_cache_get "$rt" "$ver" "$probe")" ]
}

# ── live probes ───────────────────────────────────────────────────────────────────────────────────

# _herd_rtconf_bounded_adapter_run <workdir> <prompt> — ONE bounded turn through the PRODUCTION
# adapter (scripts/herd/codex-exec-adapter.sh), never a re-implementation of it. `timeout` cannot wrap
# a shell function, so the bounded path re-enters a fresh bash that sources the same adapter and calls
# the same function — the identical trick _herd_roster_probe uses in agents.sh, and for the same
# reason: the runtime incantation must keep living in exactly one place. Stock macOS ships no
# `timeout`, hence the gtimeout fallback and the run-anyway branch (a missing bound must degrade to
# unbounded, never disable the probe). Prints the adapter's JSON line; never fails the caller.
_herd_rtconf_bounded_adapter_run() {
  local workdir="${1:-}" prompt="${2:-}" adapter="$_HERD_RTCONF_HERE/codex-exec-adapter.sh"
  local -a bound=()
  if command -v timeout >/dev/null 2>&1; then bound=(timeout "${HERD_RTCONF_TIMEOUT:-150}")
  elif command -v gtimeout >/dev/null 2>&1; then bound=(gtimeout "${HERD_RTCONF_TIMEOUT:-150}")
  fi
  if [ "${#bound[@]}" -gt 0 ] && [ -f "$adapter" ]; then
    "${bound[@]}" bash -c '. "$1"; codex_exec_adapter_run "$2" "$3"' _ "$adapter" "$workdir" "$prompt" 2>/dev/null || true
  else
    codex_exec_adapter_run "$workdir" "$prompt" 2>/dev/null || true
  fi
}

# _herd_rtconf_bounded_raw <workdir> <prompt> — one bounded RAW `codex exec` turn with stdout AND
# stderr captured together. Needed by exactly one probe: codex reports a malformed agent-role
# definition on its own diagnostic channel, not as a structured event, so the adapter (which owns
# structured-event parsing and deliberately discards stderr — its design req 4) cannot see it.
# `--sandbox read-only`: this probe only asks a question, so it gets the narrowest sandbox that works,
# the same discipline codex-exec-adapter.sh's isolation contract established.
_herd_rtconf_bounded_raw() {
  local workdir="${1:-}" prompt="${2:-}" bin="${CODEX_BIN:-codex}"
  local -a bound=()
  if command -v timeout >/dev/null 2>&1; then bound=(timeout "${HERD_RTCONF_TIMEOUT:-150}")
  elif command -v gtimeout >/dev/null 2>&1; then bound=(gtimeout "${HERD_RTCONF_TIMEOUT:-150}")
  fi
  if [ "${#bound[@]}" -gt 0 ]; then
    "${bound[@]}" "$bin" exec --json --sandbox read-only -C "$workdir" -- "$prompt" </dev/null 2>&1 || true
  else
    "$bin" exec --json --sandbox read-only -C "$workdir" -- "$prompt" </dev/null 2>&1 || true
  fi
}

# _herd_rtconf_final_message <adapter-json> — the model's reply text out of the adapter's typed
# object (never a raw-text grep of codex output — that is the adapter's job, done once).
_herd_rtconf_final_message() {
  command -v jq >/dev/null 2>&1 || return 0
  printf '%s' "${1:-}" | jq -r '.final_agent_message // ""' 2>/dev/null || true
}

# Each probe prints ONE line: "<outcome>\t<note>". They never write the cache themselves —
# herd_rtconf_run owns recording, so every outcome is version-keyed by construction.

# probe: specialist-definition — the roster's REAL inject path, positive AND negative.
_herd_rtconf_probe_specialist_definition() {
  local workdir="${1:-}" roster sentinel block ask pos neg pos_msg neg_msg
  command -v herd_roster_lane_spec_block >/dev/null 2>&1 || {
    printf 'unavailable\tagents.sh not sourced — cannot compose the roster injection block'; return 0; }
  # This probe covers the INJECT delivery path — the one codex actually uses (no by-name selector,
  # see templates/drivers/codex.driver). A runtime that selects BY FLAG is a different mechanism, and
  # agents.sh's herd_roster_verify already probes that one; saying so is honest, re-implementing it
  # here would be a second copy of the same proof.
  local kind; kind="$(herd_roster_probe_kind "$(herd_rtconf_driver)" 2>/dev/null || printf 'inject')"
  if [ "$kind" != "inject" ]; then
    printf 'unavailable\tdriver %s selects a definition BY FLAG, not by injection — that mechanism is probed by `herd agents verify`, not here' "$(herd_rtconf_driver)"
    return 0
  fi
  ask="${_HERD_ROSTER_PROBE_PROMPT:-$_HERD_RTCONF_ASK_FALLBACK}"
  roster="$(mktemp -d)" || { printf 'unavailable\tcould not create a scratch roster dir'; return 0; }
  sentinel="HERD-RTCONF-DEF-$$-$(date +%s)"
  cat > "$roster/rtconf-probe.md" <<EOF
---
name: rtconf-probe
description: HERD-763 runtime-conformance probe definition
sentinel: $sentinel
---

You are the runtime-conformance probe specialist agent. Follow these standing instructions.
EOF
  # Composed BY agents.sh — the exact block herd-feature.sh/herd-quick.sh prepend under HERD_AGENT.
  block="$(HERD_AGENTS_DIR="$roster" herd_roster_lane_spec_block rtconf-probe "$(herd_rtconf_driver)" 2>/dev/null || true)"
  rm -rf "$roster" 2>/dev/null || true
  case "$block" in
    *"$sentinel"*) : ;;
    *) printf 'fail\tthe roster produced no injectable block carrying the sentinel — the delivery path is broken before the runtime is even reached'; return 0 ;;
  esac
  pos="$(_herd_rtconf_bounded_adapter_run "$workdir" "RULES${block}"$'\n\n'"$ask")"
  # NEGATIVE CONTROL: the bare ask, which is exactly what a lane spawned against a name that does not
  # resolve would send. If THIS returns the sentinel, the probe cannot fail and proves nothing.
  neg="$(_herd_rtconf_bounded_adapter_run "$workdir" "$ask")"
  pos_msg="$(_herd_rtconf_final_message "$pos")"
  neg_msg="$(_herd_rtconf_final_message "$neg")"
  local pos_hit=0 neg_hit=0
  case "$pos_msg" in *"$sentinel"*) pos_hit=1 ;; esac
  case "$neg_msg" in *"$sentinel"*) neg_hit=1 ;; esac
  if [ "$pos_hit" -eq 1 ] && [ "$neg_hit" -eq 0 ]; then
    printf 'pass\tinjected roster definition returned its sentinel; the negative control correctly did not'
  elif [ "$pos_hit" -eq 1 ]; then
    printf 'indeterminate\tthe negative control ALSO returned the sentinel — this probe cannot fail, so it proves nothing'
  else
    printf 'fail\tthe injected definition did NOT reach the model (silent-fallback trap T2) — a builder under HERD_AGENT would run as a plain agent'
  fi
}

# probe: structured-exec-events — one bounded turn through the production adapter.
_herd_rtconf_probe_structured_exec_events() {
  local workdir="${1:-}" out state tid events msg word="herdrtconflive"
  command -v jq >/dev/null 2>&1 || { printf 'unavailable\tjq not installed — the adapter cannot parse events on this machine'; return 0; }
  out="$(_herd_rtconf_bounded_adapter_run "$workdir" "Reply with exactly and only the single word: $word")"
  [ -n "$out" ] || { printf 'fail\tthe adapter produced no output at all for a bounded exec turn'; return 0; }
  state="$(printf '%s' "$out" | jq -r '.state // ""' 2>/dev/null || true)"
  tid="$(printf '%s' "$out" | jq -r '.thread_id // ""' 2>/dev/null || true)"
  events="$(printf '%s' "$out" | jq -r '.raw_event_count // 0' 2>/dev/null || true)"
  msg="$(_herd_rtconf_final_message "$out" | tr '[:upper:]' '[:lower:]')"
  if [ "$state" != "completed" ]; then
    printf 'fail\tbounded exec turn did not complete (state=%s, reason=%s)' "${state:-<none>}" \
      "$(printf '%s' "$out" | jq -r '.state_reason // "?"' 2>/dev/null || printf '?')"
    return 0
  fi
  case "${events:-}" in ''|*[!0-9]*) events=0 ;; esac
  if [ -z "$tid" ] || [ "$tid" = "null" ] || [ "$events" -le 0 ]; then
    printf 'fail\tturn completed but the structured stream was thin (thread_id=%s raw_event_count=%s) — the event shapes may have changed' \
      "${tid:-<none>}" "${events:-0}"
    return 0
  fi
  case "$msg" in
    *"$word"*) printf 'pass\treal event stream parsed: state=completed, thread_id captured, %s events, reply carried through' "$events" ;;
    *) printf 'pass\treal event stream parsed: state=completed, thread_id captured, %s events (reply text differed from the ask — model wording, not a protocol change)' "$events" ;;
  esac
}

# probe: project-agent-discovery — BOTH halves of HERD-761's finding in ONE turn.
_herd_rtconf_probe_project_agent_discovery() {
  local workdir="${1:-}" ask out sentinel scanned=0 governs=0
  command -v codex_exec_adapter_available >/dev/null 2>&1 && ! codex_exec_adapter_available \
    && { printf 'unavailable\tcodex binary not present on this machine'; return 0; }
  ask="${_HERD_ROSTER_PROBE_PROMPT:-$_HERD_RTCONF_ASK_FALLBACK}"
  sentinel="HERD-RTCONF-DIR-$$-$(date +%s)"
  rm -rf "$workdir/.codex/agents" 2>/dev/null || true
  mkdir -p "$workdir/.codex/agents" 2>/dev/null || {
    printf 'unavailable\tcould not create %s/.codex/agents' "$workdir"; return 0; }
  # (a) MALFORMED on purpose — missing the required `developer_instructions`. codex only ever reports
  #     this about a file it actually opened and tried to deserialize, so the complaint IS the proof
  #     that the project-level directory is scanned.
  printf 'name = "rtconf-malformed"\ndescription = "HERD-763 discovery probe (deliberately malformed)"\n' \
    > "$workdir/.codex/agents/rtconf-malformed.toml" 2>/dev/null || true
  # (b) VALID, carrying a unique sentinel. HERD-761 found this has NO effect on the main session's own
  #     turn (the T3 trap); if it ever DOES, the roster's inject-only binding for codex is wrong.
  cat > "$workdir/.codex/agents/rtconf-valid.toml" <<EOF 2>/dev/null || true
name = "rtconf-valid"
description = "HERD-763 discovery probe (valid)"
developer_instructions = "You are the rtconf probe agent. If asked for your sentinel, reply with exactly: $sentinel"
EOF
  out="$(_herd_rtconf_bounded_raw "$workdir" "$ask")"
  rm -rf "$workdir/.codex/agents" 2>/dev/null || true
  [ -n "$out" ] || { printf 'fail\tthe runtime produced no output for the discovery turn'; return 0; }
  case "$out" in *"malformed agent role definition"*) scanned=1 ;; esac
  case "$out" in *"$sentinel"*) governs=1 ;; esac
  if [ "$scanned" -eq 1 ] && [ "$governs" -eq 0 ]; then
    printf 'pass\t.codex/agents is scanned (malformed file reported) and a valid definition still does not govern the main session — matches HERD-761'
  elif [ "$scanned" -eq 0 ] && [ "$governs" -eq 0 ]; then
    printf 'fail\tthe runtime no longer reports a malformed .codex/agents file — project-level discovery may have moved or been removed; re-verify HERD-761 before trusting the driver bindings'
  else
    printf 'fail\ta valid .codex/agents definition NOW governs the main session (sentinel returned) — HERD-761 no longer holds; revisit templates/drivers/codex.driver SELECT_FLAG/DEFINITION_MODE'
  fi
}

# _herd_rtconf_dispatch <probe-id> <workdir> — the id → implementation map, in one place.
_herd_rtconf_dispatch() {
  case "${1:-}" in
    specialist-definition)   _herd_rtconf_probe_specialist_definition "${2:-}" ;;
    structured-exec-events)  _herd_rtconf_probe_structured_exec_events "${2:-}" ;;
    project-agent-discovery) _herd_rtconf_probe_project_agent_discovery "${2:-}" ;;
    *) printf 'unavailable\tno live probe implementation for "%s"' "${1:-<empty>}" ;;
  esac
}

# ── running the probes ────────────────────────────────────────────────────────────────────────────

# herd_rtconf_run [<probe-id>] — run the live probes (or just one) against the INSTALLED runtime and
# record each outcome VERSION-KEYED. Deferred rows are recorded too, so the cache is a complete
# picture of what was asked and what was answered, and are never "run". Prints one line per probe.
# ALWAYS exits 0 — evidence, not a gate.
herd_rtconf_run() {
  local only="${1:-}" rt ver id mode _title _detail result outcome note wt tmp made_wt=0 root
  rt="$(herd_rtconf_runtime)"
  ver="$(herd_rtconf_version "$rt")"
  if [ -z "$ver" ]; then
    printf 'runtime conformance: %s is not installed on this machine — nothing can be probed (this is an outcome, not a failure).\n' "$rt"
    return 0
  fi
  printf 'probing %s (%s):\n' "$rt" "$ver"

  # An ISOLATED scratch worktree for every live probe: the runtime is asked to answer a question, not
  # to touch this checkout. A detached `scratch-*` worktree is the shape AGENTS.md prescribes (and the
  # sweep's reaper recognizes); a plain temp dir is the documented degrade when there is no repo here.
  root="${PROJECT_ROOT:-$PWD}"
  tmp="$(mktemp -d)"
  wt="$tmp/scratch-herd-runtime-conformance"
  if git -C "$root" worktree add -q --detach "$wt" HEAD >/dev/null 2>&1; then
    made_wt=1
  else
    mkdir -p "$wt" 2>/dev/null || wt="$tmp"
  fi

  while IFS=$'\t' read -r id mode _title _detail; do
    [ -n "$id" ] || continue
    [ -z "$only" ] || [ "$only" = "$id" ] || continue
    if [ "$mode" = "deferred" ]; then
      herd_rtconf_cache_put "$rt" "$ver" "$id" deferred "$_detail"
      printf '  ⏸  %-24s deferred — %s\n' "$id" "$_detail"
      continue
    fi
    result="$(_herd_rtconf_dispatch "$id" "$wt")"
    outcome="${result%%$'\t'*}"; note="${result#*$'\t'}"
    [ -n "$outcome" ] || { outcome="fail"; note="probe produced no verdict"; }
    herd_rtconf_cache_put "$rt" "$ver" "$id" "$outcome" "$note"
    case "$outcome" in
      pass) printf '  ✓ %-24s pass — %s\n' "$id" "$note" ;;
      *)    printf '  ✗ %-24s %s — %s\n' "$id" "$outcome" "$note" ;;
    esac
  done <<< "$(herd_rtconf_probes)"

  # Cleanup: the detached worktree first (AGENTS.md: never strand one), then ONLY the mktemp dir we
  # own — never a path derived from $wt, which may have degraded to somewhere else entirely.
  if [ "$made_wt" -eq 1 ]; then
    git -C "$root" worktree remove --force "$wt" >/dev/null 2>&1 || true
  fi
  case "$tmp" in /*/*) rm -rf "$tmp" 2>/dev/null || true ;; esac
  return 0
}

# ── reporting: the `herd doctor --runtime-conformance` section ────────────────────────────────────

_herd_rtconf_when() {
  local e="${1:-0}"
  date -r "$e" '+%Y-%m-%d %H:%M' 2>/dev/null || date -d "@$e" '+%Y-%m-%d %H:%M' 2>/dev/null || printf '?'
}

# herd_rtconf_report [--probe] — the doctor section. Reads the cache (never probes) unless --probe is
# given, in which case the live probes run FIRST and the report then reflects them. ALWAYS exits 0.
#
# Every row is one of exactly five states, and the STALE one is the reason this feature exists:
#   ✓ pass/…       a recorded outcome for the EXACT installed version
#   ⚠️  STALE       a recorded outcome, but against a DIFFERENT version — not trusted, re-probe
#   ⚠️  never       no recorded outcome for this runtime+probe at all
#   ⚠️  unavailable the runtime is not installed here, so nothing can be asserted
#   ⏸  deferred    not probeable yet (step 7) — printed ALWAYS, never omitted
herd_rtconf_report() {
  local probe="${1:-}" rt ver id mode title detail cached last flagged=0
  rt="$(herd_rtconf_runtime)"
  ver="$(herd_rtconf_version "$rt")"
  [ "$probe" = "--probe" ] && herd_rtconf_run >/dev/null 2>&1

  printf '\nRuntime conformance (driver %s · runtime %s · installed %s) — advisory:\n' \
    "$(herd_rtconf_driver)" "$rt" "${ver:-<not installed>}"

  while IFS=$'\t' read -r id mode title detail; do
    [ -n "$id" ] || continue
    if [ "$mode" = "deferred" ]; then
      # DEFERRED IS PRINTED, ALWAYS. HERD-754's rule: an unbuilt capability degrades explicitly.
      printf '  ⏸  %-24s not yet probeable — %s\n' "$id" "$detail"
      continue
    fi
    if [ -z "$ver" ]; then
      printf '  ⚠️  %-24s unavailable — %s is not installed on this machine (%s)\n' "$id" "$rt" "$title"
      flagged=1
      continue
    fi
    cached="$(herd_rtconf_cache_get "$rt" "$ver" "$id")"
    if [ -n "$cached" ]; then
      local outcome when note
      outcome="$(printf '%s' "$cached" | cut -f1)"
      when="$(_herd_rtconf_when "$(printf '%s' "$cached" | cut -f2)")"
      note="$(printf '%s' "$cached" | cut -f3)"
      case "$outcome" in
        pass) printf '  ✓ %-24s pass — %s  [%s, %s]\n' "$id" "$note" "$when" "$ver" ;;
        *)    printf '  ✗ %-24s %s — %s  [%s, %s]\n' "$id" "$outcome" "$note" "$when" "$ver"; flagged=1 ;;
      esac
      continue
    fi
    # Not recorded against the INSTALLED version. Say precisely which of the two reasons it is —
    # "never probed" and "probed against a version you no longer run" are different problems.
    last="$(herd_rtconf_cache_last "$rt" "$id")"
    if [ -n "$last" ]; then
      printf '  ⚠️  %-24s STALE — last recorded %s on %s against %s; the installed runtime is %s, so that result is NOT trusted\n' \
        "$id" "$(printf '%s' "$last" | cut -f1)" "$(_herd_rtconf_when "$(printf '%s' "$last" | cut -f2)")" \
        "$(printf '%s' "$last" | cut -f3)" "$ver"
    else
      printf '  ⚠️  %-24s never probed against %s — %s\n' "$id" "$ver" "$title"
    fi
    flagged=1
  done <<< "$(herd_rtconf_probes)"

  [ "$flagged" -eq 1 ] && printf '  (advisory only — a conformance result never blocks anything; probe live with: herd doctor --runtime-conformance --probe)\n'
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced), mirroring agents.sh / codex-exec-adapter.sh's dual shape.
_herd_rtconf_cli() {
  local sub="${1:-report}"
  shift 2>/dev/null || true
  case "$sub" in
    report|'')  herd_rtconf_report "${1:-}" ;;
    probe)      herd_rtconf_run "${1:-}" ;;
    version)    printf '%s\n' "$(herd_rtconf_version)" ;;
    runtime)    printf '%s\n' "$(herd_rtconf_runtime)" ;;
    probes)     herd_rtconf_probes ;;
    -h|--help|help)
      printf 'usage: runtime-conformance.sh {report [--probe]|probe [<probe-id>]|probes|runtime|version}\n' ;;
    *)
      printf 'usage: runtime-conformance.sh {report [--probe]|probe [<probe-id>]|probes|runtime|version}\n' >&2
      return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _HERD_RTCONF_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "$_HERD_RTCONF_HERE/herd-config.sh"
  # shellcheck source=/dev/null
  . "$_HERD_RTCONF_HERE/driver.sh"
  # shellcheck source=/dev/null
  . "$_HERD_RTCONF_HERE/agents.sh"
  # shellcheck source=/dev/null
  . "$_HERD_RTCONF_HERE/codex-exec-adapter.sh"
  _herd_rtconf_cli "$@"
fi
