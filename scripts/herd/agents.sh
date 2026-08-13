#!/usr/bin/env bash
# agents.sh — the SPECIALIST AGENT ROSTER (HERD-667, epic HERD-666): committed, per-project agent
# definitions (.herd/agents/*.md) plus the ONE shared implementation of "how does THIS runtime
# resolve a named agent, and does it actually resolve it".
#
# WHY THIS EXISTS. A trained agent per domain (a gate-rails specialist, a driver-portability
# specialist, …) was prototyped by hand on emberglen-godot and surfaced two traps a hand-rolled
# per-project copy cannot survive (docs/spikes/specialist-agent-roster.md):
#   T1 USER-SCOPE-VS-REPO — a runtime may resolve definitions from a USER-scope directory and ignore
#      the repo copy entirely (verified on grok 1.0.3: ~/.grok/agents/ honored, ./.grok/agents/
#      ignored). So PUBLISHING the committed source to the runtime's real lookup path is load-bearing,
#      not a convenience — hence `herd agents install`.
#   T2 SILENT FALLBACK — an UNKNOWN agent name is silently ignored: the runtime runs as a plain
#      builder and the only symptom is the agent making the mistakes its definition forbids. So
#      verification must be EMPIRICAL (spawn it and look for content that exists ONLY in that
#      definition) and it must be able to FAIL — a probe with no negative control is worthless.
#   T3 SUBAGENT DIR ≠ MAIN-SESSION PERSONA (HERD-729) — a runtime's NATIVE per-project definition
#      directory may be scoped to a different FEATURE than the one HERD_AGENT needs. Claude Code's
#      `.claude/agents/*.md` is real and IS read natively by `claude` — but as SUBAGENT types for the
#      harness's own Agent/Task tool, delegated to at the orchestrator's discretion, never as the
#      MAIN session's persona a top-level `claude -p` oneshot loads for the whole run. Publishing a
#      roster definition there (as `mode=native`/`install` would) is therefore a no-op for what
#      HERD_AGENT promises — "govern this whole build" — even though the file is genuinely read by
#      *something*. `templates/drivers/herdr-claude.driver` and `headless.driver` bind
#      DRIVER_AGENT_DEFINITION_MODE=inject for exactly this reason: injecting the body into the task
#      spec is the one mechanism that provably governs a claude oneshot's whole session, and it is
#      independently what `herd_roster_probe_kind` already resolves to for claude (no by-name
#      selector), so mode now agrees with the mechanism actually in use instead of contradicting it.
#      Lesson for the NEXT runtime: a definition dir binding must be audited for WHO reads it and
#      WHEN, not just whether the runtime reads it at all.
#
# THE THREE DRIVER BINDINGS this file reads (added to templates/drivers/*.driver by HERD-667):
#   DRIVER_AGENT_DEFINITION_DIR   where the runtime LOOKS UP named definitions (repo- or user-scope)
#   DRIVER_AGENT_SELECT_FLAG      the by-name selection flag shape ('--agent <name>'), if any
#   DRIVER_AGENT_DEFINITION_MODE  native | install | inject — how definitions reach the runtime
# Each may carry the drivers' existing `@degrade:<reason>` sentinel when the runtime has no such
# capability; herd_roster_binding treats a @degrade value as ABSENT, so an unbound runtime degrades to
# the portable INJECT fallback (prepend the definition body to the task spec) rather than a red row.
#
# CONTRACT:
#   • SOURCED, not executed, by the lanes (herd-feature.sh / herd-quick.sh) and bin/herd AFTER
#     herd-config.sh (which provides PROJECT_ROOT / WORKTREES_DIR). Defines functions ONLY; sourcing
#     has NO side effects — safe in lib mode / hermetic tests.
#   • Also RUNNABLE as a CLI (`bash agents.sh <sub> …`), which is what `herd agents` dispatches to.
#   • SHIP-DORMANT: nothing here runs unless an operator authors a definition and sets HERD_AGENT (or
#     calls `herd agents`). With HERD_AGENT unset the lanes' spawn argv and task spec are
#     BYTE-IDENTICAL (tests/test-agent-roster.sh asserts exactly that).
#   • FAIL-SOFT: a missing roster dir, an unreadable definition, an absent runtime binary and an
#     unwritable cache all degrade to a clear note and exit 0. A name that does not resolve is a LOUD
#     WARNING at spawn time, never a block — the operator's spawn is never held hostage to a probe.
#
# The engine never names a runtime here: every runtime-specific string comes from the active driver's
# bindings through scripts/herd/driver.sh, so a new runtime is a DATA file, not a fork.

# The verdict of the LAST herd_roster_verify call, for a caller that wants it programmatically.
# Pre-declared at source time (the same shape caps-sync-lint.sh's HERD_CAPS_SYNC_SKIP_REASON uses) so
# reading it under `set -u` is safe before any verify has run. NOTE: it is set in the CALLING shell,
# so `out="$(herd_roster_verify x)"` captures the human lines but leaves this untouched — redirect to
# a file instead when you want both.
HERD_ROSTER_VERDICT="${HERD_ROSTER_VERDICT:-}"

# ── roster location + definition parsing ──────────────────────────────────────────────────────────

# herd_roster_dir — the committed definition directory. HERD_AGENTS_DIR overrides it (the knob the
# hermetic tests and a non-standard layout use); otherwise it is <PROJECT_ROOT>/.herd/agents, resolved
# from the config loader's PROJECT_ROOT and falling back to the cwd so a bare `bash agents.sh` in a
# project root still finds the roster.
#
# NOT to be confused with driver.sh's _herd_agents_dir, which is <WORKTREES_DIR>/.herd/agents — the
# HEADLESS driver's detached-process registry. Same basename, different root (the repo vs the sibling
# worktree pool) and different contents (committed markdown vs pid/status files); they never collide.
herd_roster_dir() {
  if [ -n "${HERD_AGENTS_DIR:-}" ]; then printf '%s' "$HERD_AGENTS_DIR"; return 0; fi
  printf '%s/.herd/agents' "${PROJECT_ROOT:-$PWD}"
}

# herd_roster_name_ok <name> — success iff <name> is a safe definition name: one or more of
# [A-Za-z0-9._-], no slash, no leading dot, NO LEADING DASH. The name becomes a filename, a runtime
# flag VALUE and a cache key, so it is validated ONCE here and never re-sanitized ad hoc downstream.
# The leading-dash rule is not cosmetic: `--agent -foo` would read as another FLAG to the runtime's
# own argument parser, so a dash-leading name is refused before it can ever reach an argv.
herd_roster_name_ok() {
  local n="${1:-}"
  [ -n "$n" ] || return 1
  case "$n" in .*|-*|*/*|*[!A-Za-z0-9._-]*) return 1 ;; esac
  return 0
}

# herd_roster_path <name> — the definition file for <name>, or non-zero when it does not exist.
herd_roster_path() {
  local n="${1:-}" f
  herd_roster_name_ok "$n" || return 1
  f="$(herd_roster_dir)/$n.md"
  [ -f "$f" ] || return 1
  printf '%s' "$f"
}

# herd_roster_is_definition <file> — success iff <file> is a REAL roster definition rather than
# documentation that happens to sit in the roster dir (HERD-732, GH #801: a README.md alongside the
# real definitions rendered as a roster row with name "README", description "—", unverified). Reuses
# herd_roster_field, which already returns empty both for a file with NO frontmatter block at all and
# for a frontmatter block that never sets `name:` — so both shapes of "this is not a definition" are
# one check. This is the single classification every scan below builds on.
herd_roster_is_definition() {
  local f="${1:-}"
  [ -f "$f" ] || return 1
  [ -n "$(herd_roster_field "$f" name)" ]
}

# herd_roster_names — every REAL definition name in the roster, one per line, LC_ALL=C sorted. Empty
# (and exit 0) when the roster dir is absent or holds no definitions — an unused feature is not an
# error. This is the ONE roster-scan helper `list`, the pane, `install` and `verify` all consume, so a
# classification fix lands here once rather than being re-derived per surface.
herd_roster_names() {
  local d f b out=""
  d="$(herd_roster_dir)"
  [ -d "$d" ] || return 0
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue                       # nullglob-off guard: no match → literal → skip
    b="$(basename "$f" .md)"
    herd_roster_name_ok "$b" || continue
    herd_roster_is_definition "$f" || continue    # documentation (no frontmatter / no name:) — skip
    out="$out$b"$'\n'
  done
  [ -n "$out" ] || return 0
  printf '%s' "$out" | LC_ALL=C sort              # pipe-ok: a bounded roster, far under a pipe buffer
}

# herd_roster_skipped_names — every *.md in the roster dir that herd_roster_names skipped as
# documentation (a safe basename that fails herd_roster_is_definition), one per line, LC_ALL=C sorted.
# Lets `herd agents list` SAY what it skipped instead of just silently shrinking the roster.
herd_roster_skipped_names() {
  local d f b out=""
  d="$(herd_roster_dir)"
  [ -d "$d" ] || return 0
  for f in "$d"/*.md; do
    [ -f "$f" ] || continue
    b="$(basename "$f" .md)"
    herd_roster_name_ok "$b" || continue
    herd_roster_is_definition "$f" && continue
    out="$out$b"$'\n'
  done
  [ -n "$out" ] || return 0
  printf '%s' "$out" | LC_ALL=C sort
}

# _herd_roster_skip_reason <file> — the human-readable reason herd_roster_list shows next to a
# skipped .md: no frontmatter block at all, or a frontmatter block missing `name:`. Message-only — the
# actual skip decision is herd_roster_is_definition; this never gates anything.
_herd_roster_skip_reason() {
  local f="${1:-}" first
  first="$(head -n1 "$f" 2>/dev/null | tr -d '[:space:]')"
  if [ "$first" = "---" ]; then
    printf 'no name: field'
  else
    printf 'no frontmatter'
  fi
}

# herd_roster_field <file> <key> — a FRONTMATTER value from a definition. The frontmatter is the
# leading `---` fenced block; `key: value` lines only, first match wins, surrounding whitespace and a
# single pair of wrapping quotes stripped. Empty (exit 0) when absent — every field is optional to
# READ, so a hand-written definition missing one degrades to a note, never a parse error.
herd_roster_field() {
  local f="${1:-}" k="${2:-}"
  [ -f "$f" ] && [ -n "$k" ] || return 0
  HERD_ROSTER_FILE="$f" HERD_ROSTER_KEY="$k" python3 -c '
import os, sys
path = os.environ["HERD_ROSTER_FILE"]; key = os.environ["HERD_ROSTER_KEY"]
try:
    lines = open(path, encoding="utf-8", errors="replace").read().split("\n")
except Exception:
    sys.exit(0)
if not lines or lines[0].strip() != "---":
    sys.exit(0)
for ln in lines[1:]:
    if ln.strip() == "---":
        break
    if ":" not in ln:
        continue
    k, _, v = ln.partition(":")
    if k.strip() != key:
        continue
    v = v.strip()
    # chr(34)/chr(39), not a quote literal: this script is embedded in a SINGLE-QUOTED shell string,
    # so a bare apostrophe here would terminate it and silently corrupt the rest of the file.
    if len(v) >= 2 and v[0] == v[-1] and v[0] in (chr(34), chr(39)):
        v = v[1:-1]
    sys.stdout.write(v)
    break
' 2>/dev/null || true
}

# herd_roster_body <file> — the SYSTEM PROMPT: everything after the frontmatter block, leading blank
# lines trimmed. A file with no frontmatter is all body (so a bare markdown file still works).
herd_roster_body() {
  local f="${1:-}"
  [ -f "$f" ] || return 0
  HERD_ROSTER_FILE="$f" python3 -c '
import os, sys
try:
    text = open(os.environ["HERD_ROSTER_FILE"], encoding="utf-8", errors="replace").read()
except Exception:
    sys.exit(0)
lines = text.split("\n")
if lines and lines[0].strip() == "---":
    for i, ln in enumerate(lines[1:], start=1):
        if ln.strip() == "---":
            lines = lines[i + 1:]
            break
sys.stdout.write("\n".join(lines).lstrip("\n").rstrip() + "\n")
' 2>/dev/null || true
}

# herd_roster_sha <file> — the definition's content sha256 (the cache key's second half), or empty
# when no hasher is available. Mirrors health-trust.sh's hasher ladder: sha256sum (Linux), then
# shasum -a 256 (macOS). NEVER fabricates a digest — an empty sha means "do not cache", not "matches".
herd_roster_sha() {
  local f="${1:-}"
  [ -f "$f" ] || return 0
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$f" 2>/dev/null | awk '{print $1}'   # pipe-ok: one line of tool output
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$f" 2>/dev/null | awk '{print $1}'   # pipe-ok: one line of tool output
  fi
}

# ── driver bindings ───────────────────────────────────────────────────────────────────────────────

# herd_roster_binding <KEY> [driver] — a DRIVER_AGENT_DEFINITION_*/SELECT binding, with the drivers'
# `@degrade:<reason>` sentinel treated as ABSENT (empty output, exit 0). That is the whole point of
# the convention here: a runtime that has no by-name selector binds an honest, self-documenting
# sentinel instead of a guessed flag, and every consumer reads it as "capability not present" and
# takes the portable fallback. Built on driver.sh's herd_driver_agent_value (PURE — greps the .driver
# file, never sources it), so an unreadable/absent driver file degrades to empty too.
herd_roster_binding() {
  local k="${1:-}" drv="${2:-}" v
  command -v herd_driver_agent_value >/dev/null 2>&1 || return 0
  v="$(herd_driver_agent_value "$k" "" "$drv" 2>/dev/null || true)"
  case "$v" in '@degrade:'*) return 0 ;; esac
  printf '%s' "$v"
}

# herd_roster_degrade_reason <KEY> [driver] — the `@degrade:` reason a binding carries (without the
# prefix), or empty when the binding is real/absent. Lets `list`/`verify`/doctor SAY why a runtime has
# no selector instead of silently showing a blank.
herd_roster_degrade_reason() {
  local k="${1:-}" drv="${2:-}" v
  command -v herd_driver_agent_value >/dev/null 2>&1 || return 0
  v="$(herd_driver_agent_value "$k" "" "$drv" 2>/dev/null || true)"
  case "$v" in '@degrade:'*) printf '%s' "${v#@degrade:}" ;; esac
}

# herd_roster_mode [driver] — the driver's DRIVER_AGENT_DEFINITION_MODE:
#   native   the runtime reads the repo-scope definition dir directly (no publishing step needed)
#   install  the runtime only reads a USER-scope dir — `herd agents install` must publish there (T1)
#   inject   the runtime has NO definition lookup at all — the lane prepends the body to the task spec
# FAIL-SOFT default: `inject`, the portable fallback that works on ANY runtime, so a driver with no
# binding at all (an out-of-tree driver) still gets a specialist agent rather than a red row.
herd_roster_mode() {
  local m; m="$(herd_roster_binding DRIVER_AGENT_DEFINITION_MODE "${1:-}")"
  case "$m" in native|install|inject) printf '%s' "$m" ;; *) printf 'inject' ;; esac
}

# _herd_roster_expand <value> — expand `$HOME` / `${VAR:-default}` in a DEFINITION_DIR binding.
# The .driver files are COMMITTED, ZERO-SECRET DATA holding command SHAPES, and a user-scope lookup
# path is only expressible with a shell variable ('${HERD_AGENT_DEFINITION_ROOT:-$HOME}/.grok/agents'
# — the same idiom DRIVER_AGENT_SESSION_ID already uses). The expansion is guarded: any value bearing
# a command-substitution / quoting / redirection metacharacter is REFUSED outright (empty, exit 0),
# so only a plain parameter-expanded path can ever be evaluated.
_herd_roster_expand() {
  local v="${1:-}"
  [ -n "$v" ] || return 0
  case "$v" in *[\`\;\&\|\(\)\<\>\'\"\*\?]*) return 0 ;; esac
  case "$v" in
    *'$'*) eval "printf '%s' \"$v\"" 2>/dev/null || true ;;
    *) printf '%s' "$v" ;;
  esac
}

# herd_roster_definition_dir [driver] — the ABSOLUTE directory this driver's runtime looks definitions
# up in, or empty when it has none (mode=inject). A RELATIVE binding ('.claude/agents') is repo-scope
# and resolves against PROJECT_ROOT; an absolute/`$HOME`-rooted one is user-scope (T1).
herd_roster_definition_dir() {
  local drv="${1:-}" v
  v="$(herd_roster_binding DRIVER_AGENT_DEFINITION_DIR "$drv")"
  [ -n "$v" ] || return 0
  v="$(_herd_roster_expand "$v")"
  [ -n "$v" ] || return 0
  case "$v" in /*) printf '%s' "$v" ;; *) printf '%s/%s' "${PROJECT_ROOT:-$PWD}" "$v" ;; esac
}

# herd_roster_select_argv <name> [driver] — the runtime argv tokens that SELECT <name> at spawn/exec
# time, space-separated, or EMPTY when this runtime has no by-name selector. Composed from the
# driver's DRIVER_AGENT_SELECT_FLAG template by substituting the `<name>` token — the same
# token-substitution contract the DRIVER_AGENT_* exec templates use.
#
# The lanes append this to the spawn's <flags> (which herd_driver_agent_spawn_argv word-splits into
# the argv), so selection needs NO new seam in the spawn composer: an empty result leaves the argv
# BYTE-IDENTICAL. A name is validated first, so a bad name can never inject an argv token.
herd_roster_select_argv() {
  local n="${1:-}" drv="${2:-}" tmpl out="" t
  herd_roster_name_ok "$n" || return 0
  tmpl="$(herd_roster_binding DRIVER_AGENT_SELECT_FLAG "$drv")"
  [ -n "$tmpl" ] || return 0
  for t in $tmpl; do
    case "$t" in '<name>') t="$n" ;; esac
    out="${out:+$out }$t"
  done
  printf '%s' "$out"
}

# herd_roster_probe_kind [driver] — HOW a definition reaches this runtime at spawn time, which is also
# what `verify` must probe:
#   flag    the runtime selects it by name (DRIVER_AGENT_SELECT_FLAG) — resolution is the runtime's job
#   inject  no selector: the lane prepends the definition body to the prompt — resolution is OURS
# Note this is deliberately INDEPENDENT of DEFINITION_MODE: a runtime can have a native repo-scope
# definition dir and still expose no by-name spawn selector (claude does), in which case the lane
# injects and `verify` proves the INJECTION path — the mechanism the lane actually uses.
herd_roster_probe_kind() {
  local n; n="$(herd_roster_binding DRIVER_AGENT_SELECT_FLAG "${1:-}")"
  [ -n "$n" ] && printf 'flag' || printf 'inject'
}

# ── verify cache (worktree pool) ──────────────────────────────────────────────────────────────────
# One TAB-separated row per verdict, keyed by (driver, name, definition sha) so an EDITED definition
# invalidates its own verdict without any explicit cache-busting. Lives in the shared worktree pool
# beside the other cross-seat ledgers, is machine-local and regenerable, and is NEVER committed.
#   <epoch>\t<driver>\t<name>\t<sha>\t<verdict>\t<note>
# Verdicts: ok · unresolved · indeterminate · no-sentinel · unverified

herd_roster_cache_file() { printf '%s/.herd-agent-verify' "${WORKTREES_DIR:-${PROJECT_ROOT:-$PWD}}"; }

# herd_roster_cache_put <driver> <name> <sha> <verdict> [note] — append a verdict, then trim the file
# to its last 200 rows. Fail-soft: an unwritable pool is a silent skip (a verdict is evidence, not a
# gate). A row with an EMPTY sha is never written — see herd_roster_sha (no hasher ⇒ no caching).
herd_roster_cache_put() {
  local drv="${1:-}" n="${2:-}" sha="${3:-}" verdict="${4:-}" note="${5:-}" f tmp
  [ -n "$drv" ] && [ -n "$n" ] && [ -n "$sha" ] && [ -n "$verdict" ] || return 0
  f="$(herd_roster_cache_file)"
  note="$(printf '%s' "$note" | tr '\t\n' '  ')"   # pipe-ok: one short note line
  printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$(date +%s)" "$drv" "$n" "$sha" "$verdict" "$note" \
    >> "$f" 2>/dev/null || return 0
  tmp="$f.$$"
  if tail -n 200 "$f" > "$tmp" 2>/dev/null; then mv -f "$tmp" "$f" 2>/dev/null || rm -f "$tmp" 2>/dev/null || true; fi
  return 0
}

# herd_roster_cache_get <driver> <name> <sha> — the MOST RECENT verdict for that exact key, printed as
# "<verdict>\t<note>". Empty (exit 0) when the key has never been verified — which is what `doctor`
# reports as "unverified", distinct from a verdict that says it does not resolve.
herd_roster_cache_get() {
  local drv="${1:-}" n="${2:-}" sha="${3:-}" f
  [ -n "$drv" ] && [ -n "$n" ] && [ -n "$sha" ] || return 0
  f="$(herd_roster_cache_file)"
  [ -f "$f" ] || return 0
  awk -F'\t' -v d="$drv" -v n="$n" -v s="$sha" \
    '$2==d && $3==n && $4==s { v=$5; note=$6 } END { if (v != "") printf "%s\t%s", v, note }' \
    "$f" 2>/dev/null || true
}

# ── install: publish the committed source to the runtime's real lookup path (trap T1) ─────────────

# herd_roster_install [driver] — copy every committed definition into the driver's
# DRIVER_AGENT_DEFINITION_DIR. Prints one line per definition. Exit 0 on success (including the
# nothing-to-do cases: an empty roster, or mode=inject where there is no lookup path); exit 1 only
# when a real publish was attempted and FAILED, because a silent half-install is exactly the
# invisible-failure shape this feature exists to prevent.
herd_roster_install() {
  local drv="${1:-}" dir mode n src rc=0 count=0
  [ -n "$drv" ] || drv="$(herd_driver_name 2>/dev/null || printf 'herdr-claude')"
  mode="$(herd_roster_mode "$drv")"
  dir="$(herd_roster_definition_dir "$drv")"
  if [ "$mode" = "inject" ] || [ -z "$dir" ]; then
    printf 'agents install: driver %s has no definition lookup path (mode=%s) — definitions are injected into the task spec instead; nothing to publish.\n' \
      "$drv" "$mode"
    return 0
  fi
  if [ -z "$(herd_roster_names)" ]; then
    printf 'agents install: no definitions in %s — nothing to publish.\n' "$(herd_roster_dir)"
    return 0
  fi
  if ! mkdir -p "$dir" 2>/dev/null; then
    printf 'agents install: cannot create %s\n' "$dir" >&2
    return 1
  fi
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    src="$(herd_roster_path "$n")" || continue
    if cp "$src" "$dir/$n.md" 2>/dev/null; then
      printf '  published %s → %s/%s.md\n' "$n" "$dir" "$n"
      count=$(( count + 1 ))
    else
      printf '  FAILED %s → %s/%s.md\n' "$n" "$dir" "$n" >&2
      rc=1
    fi
  done <<< "$(herd_roster_names)"
  printf 'agents install: %d definition(s) published for driver %s (mode=%s).\n' "$count" "$drv" "$mode"
  return "$rc"
}

# ── verify: the EMPIRICAL probe, with a negative control (trap T2) ────────────────────────────────

# The probe prompt. Deliberately tiny in BOTH directions: it asks for one token and forbids prose, so
# a probe costs a handful of output tokens rather than a paragraph. The sentinel it asks for exists
# ONLY inside the definition — a runtime that silently ignored the name cannot produce it.
_HERD_ROSTER_PROBE_PROMPT='Print ONLY the value of the "sentinel" field from your agent definition — one line, no other words, no explanation. If you have no such field, print exactly NO-SENTINEL'

# _herd_roster_probe_model — the model a probe runs on: HERD_AGENT_VERIFY_MODEL when set, else the
# cheap quick-lane model. Resolved through the shared runtime-qualified ref resolver so a
# '<driver>:<model>' ref works here exactly as it does in a lane.
_herd_roster_probe_model() {
  local ref="${HERD_AGENT_VERIFY_MODEL:-${MODEL_QUICK:-}}"
  [ -n "$ref" ] || return 0
  command -v herd_model_for_spawn >/dev/null 2>&1 || { printf '%s' "$ref"; return 0; }
  herd_model_for_spawn "$ref" 2>/dev/null || true
}

# _herd_roster_probe <driver> <prompt> [select-arg …] — run a headless probe through the shared
# one-shot seam (DRIVER_AGENT_ONESHOT_EXEC) and echo its output, truncated to a tiny budget. Never
# fails the caller: a non-zero runtime exit yields whatever it printed (usually nothing), which the
# sentinel test then reads as "no sentinel".
_herd_roster_probe() {
  local drv="${1:-}" prompt="${2:-}" model flags out attempt
  shift 2 2>/dev/null || set --
  model="$(_herd_roster_probe_model)"
  # The runtime's OWN permission flag (never claude's), via the shared resolver the lanes use.
  flags="$(herd_driver_lane_permission_flags "$drv" 2>/dev/null || true)"
  # BOUNDED, in both directions. A probe is a diagnostic, so it may never become the slow thing:
  #   • WALL CLOCK — a wedged runtime would otherwise hang `herd agents verify` and, worse,
  #     `herd doctor --probe`, forever. `timeout` is used when present (stock macOS ships none, hence
  #     the gtimeout fallback and the run-anyway final branch — a missing bound must not disable the
  #     check, only leave it unbounded). The default was raised 90s → 150s (HERD-729): a live probe
  #     against a LONG definition (a multi-hundred-line body, injected whole ahead of the sentinel
  #     ask) intermittently ran past 90s on real model latency alone — reproduced live, not a guess —
  #     which killed a genuinely-resolving probe mid-generation and reported the silent-fallback trap
  #     (T2) for a definition that was never actually ignored. 150s gives real headroom without
  #     making a wedged runtime hang meaningfully longer.
  #   • OUTPUT — the reply is truncated before anything looks at it, so a runtime that ignores "print
  #     ONLY the value" and writes an essay costs a substring compare, not a buffer.
  local -a bound=()
  if command -v timeout >/dev/null 2>&1; then bound=(timeout "${HERD_AGENT_VERIFY_TIMEOUT:-150}")
  elif command -v gtimeout >/dev/null 2>&1; then bound=(gtimeout "${HERD_AGENT_VERIFY_TIMEOUT:-150}")
  fi
  local here; here="${_HERD_ROSTER_HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  # `timeout` cannot wrap a shell FUNCTION, so the bounded path re-enters a fresh bash that sources
  # driver.sh and calls the SAME seam — the runtime incantation still lives in exactly one place
  # (DRIVER_AGENT_ONESHOT_EXEC via herd_driver_oneshot_exec_as), never re-implemented here.
  #
  # ONE retry, ONLY on a completely empty result (HERD-729): a `timeout`-killed run yields empty
  # output (never a real-but-wrong answer — a runtime that genuinely ignores the definition, trap T2,
  # still prints SOMETHING, e.g. "I am a plain agent…"), so retrying on empty catches a transient
  # timeout/latency spike without ever masking a real silent-fallback verdict. Bounded at 2 attempts —
  # this is a diagnostic, not a resilience system.
  for attempt in 1 2; do
    # shellcheck disable=SC2086  # $flags is a whitespace-separated flag list — deliberate word-split
    if [ "${#bound[@]}" -gt 0 ] && [ -f "$here/driver.sh" ]; then
      out="$("${bound[@]}" bash -c '
          . "$1/driver.sh"
          _d="$2"; _p="$3"; _m="$4"; shift 4
          herd_driver_oneshot_exec_as "$_d" "$_p" "$_m" "$@"
        ' _ "$here" "$drv" "$prompt" "$model" $flags "$@" 2>/dev/null || true)"
    else
      out="$(herd_driver_oneshot_exec_as "$drv" "$prompt" "$model" $flags "$@" 2>/dev/null || true)"
    fi
    [ -n "$out" ] && break
  done
  printf '%s' "${out:0:2000}"
}

# herd_roster_verify <name> [driver] — the EMPIRICAL resolution proof. Prints a human line and echoes
# the verdict into the cache. ALWAYS exits 0 (a probe is evidence, not a gate); read the verdict from
# $HERD_ROSTER_VERDICT or the cache.
#
# THE PROOF, and why it has two halves:
#   POSITIVE  select <name> (by flag, or by injecting its body — whichever mechanism the LANE would
#             use for this driver) and ask for the sentinel. Sentinel returned ⇒ the definition
#             reached the model.
#   NEGATIVE  do the same with a name that provably does not exist. If THAT also returns the sentinel,
#             the probe cannot distinguish a resolved agent from an ignored one and proves nothing —
#             reported as `indeterminate`, never as a pass. This is the half that makes the check able
#             to fail, and trap T2 (grok silently ignoring an unknown --agent) is exactly why.
# Verdicts: ok · unresolved (positive produced no sentinel — the silent-fallback trap) ·
#           indeterminate (negative control also passed) · no-sentinel (the definition declares none,
#           so nothing empirical can be asserted) · unverified (runtime binary absent on this machine).
herd_roster_verify() {
  local n="${1:-}" drv="${2:-}" f sha sentinel kind rt bogus pos neg note=""
  HERD_ROSTER_VERDICT=""
  [ -n "$drv" ] || drv="$(herd_driver_name 2>/dev/null || printf 'herdr-claude')"
  if ! f="$(herd_roster_path "$n")"; then
    printf '  %-24s ✗ no definition (%s/%s.md)\n' "${n:-<empty>}" "$(herd_roster_dir)" "${n:-<empty>}"
    HERD_ROSTER_VERDICT="missing"
    return 0
  fi
  sha="$(herd_roster_sha "$f")"
  sentinel="$(herd_roster_field "$f" sentinel)"
  kind="$(herd_roster_probe_kind "$drv")"

  if [ -z "$sentinel" ]; then
    note="definition declares no 'sentinel:' frontmatter field — nothing unique to assert; add one (see herd agents new)"
    printf '  %-24s ⚠️  no-sentinel — %s\n' "$n" "$note"
    HERD_ROSTER_VERDICT="no-sentinel"
    herd_roster_cache_put "$drv" "$n" "$sha" no-sentinel "$note"
    return 0
  fi

  # The runtime binary must exist on THIS machine. It routinely does not (grok is verified-by-report
  # on the author's machine, HERD-666), so this is a first-class, clearly-labelled outcome — not a
  # failure and not a pass.
  rt="$(herd_driver_agent_runtime "$drv" 2>/dev/null || true)"
  [ -n "$rt" ] || rt="unknown"
  if ! command -v "$rt" >/dev/null 2>&1; then
    note="$rt binary not present — unverified on this machine"
    printf '  %-24s ⚠️  unverified — %s\n' "$n" "$note"
    HERD_ROSTER_VERDICT="unverified"
    herd_roster_cache_put "$drv" "$n" "$sha" unverified "$note"
    return 0
  fi

  # A name that cannot exist: derived from the definition sha so the probe stays deterministic
  # (re-running verify must not depend on a random draw), and refused if it somehow collides.
  bogus="herd-roster-negative-control-${sha:0:8}"
  if herd_roster_path "$bogus" >/dev/null 2>&1; then
    note="negative control name $bogus unexpectedly exists in the roster — remove it and re-run"
    printf '  %-24s ⚠️  indeterminate — %s\n' "$n" "$note"
    HERD_ROSTER_VERDICT="indeterminate"
    herd_roster_cache_put "$drv" "$n" "$sha" indeterminate "$note"
    return 0
  fi

  if [ "$kind" = "flag" ]; then
    # shellcheck disable=SC2046  # deliberate word-split: the select flag is a validated token pair
    pos="$(_herd_roster_probe "$drv" "$_HERD_ROSTER_PROBE_PROMPT" $(herd_roster_select_argv "$n" "$drv"))"
    # shellcheck disable=SC2046
    neg="$(_herd_roster_probe "$drv" "$_HERD_ROSTER_PROBE_PROMPT" $(herd_roster_select_argv "$bogus" "$drv"))"
  else
    # The positive probe injects EXACTLY what the lane would inject — herd_roster_lane_spec_block, the
    # same function herd-feature.sh/herd-quick.sh call — so a pass proves the real delivery path and
    # not a lookalike. The negative control is the bare prompt: an unknown name yields an empty block,
    # which is precisely what a lane spawned against a name that does not resolve would send.
    pos="$(_herd_roster_probe "$drv" "$(herd_roster_lane_spec_block "$n" "$drv")"$'\n\n'"$_HERD_ROSTER_PROBE_PROMPT")"
    neg="$(_herd_roster_probe "$drv" "$_HERD_ROSTER_PROBE_PROMPT")"
  fi

  local pos_hit=0 neg_hit=0
  case "$pos" in *"$sentinel"*) pos_hit=1 ;; esac
  case "$neg" in *"$sentinel"*) neg_hit=1 ;; esac

  if [ "$pos_hit" -eq 1 ] && [ "$neg_hit" -eq 0 ]; then
    note="probe=$kind sentinel returned; negative control correctly did not"
    printf '  %-24s ✓ ok (%s via %s)\n' "$n" "$drv" "$kind"
    HERD_ROSTER_VERDICT="ok"
  elif [ "$pos_hit" -eq 1 ]; then
    note="probe=$kind negative control ALSO returned the sentinel — the probe cannot fail, so it proves nothing"
    printf '  %-24s ⚠️  indeterminate — %s\n' "$n" "$note"
    HERD_ROSTER_VERDICT="indeterminate"
  else
    note="probe=$kind sentinel NOT returned — the runtime is ignoring this definition (silent-fallback trap); for an install-mode runtime, run: herd agents install"
    printf '  %-24s ✗ unresolved — %s\n' "$n" "$note"
    HERD_ROSTER_VERDICT="unresolved"
  fi
  herd_roster_cache_put "$drv" "$n" "$sha" "$HERD_ROSTER_VERDICT" "$note"
  return 0
}

# ── lane integration (HERD_AGENT) ─────────────────────────────────────────────────────────────────

# herd_roster_lane_select_flags <name> <driver> — the extra spawn <flags> a lane appends when
# HERD_AGENT names a definition AND this runtime selects by name. EMPTY for an unset HERD_AGENT, an
# unknown name, or an inject-only runtime — so an unset lever leaves the spawn argv BYTE-IDENTICAL.
herd_roster_lane_select_flags() {
  local n="${1:-}" drv="${2:-}"
  [ -n "$n" ] || return 0
  herd_roster_path "$n" >/dev/null 2>&1 || return 0
  herd_roster_select_argv "$n" "$drv"
}

# herd_roster_lane_spec_block <name> <driver> — the PROMPT-INJECTION block a lane appends to the task
# spec when HERD_AGENT names a definition and this runtime has NO by-name selector. This is the
# portable fallback made first-class (codex 0.147.0 has no named-agent selection at all): the
# definition body becomes part of the builder's opening prompt, so a specialist agent works on a
# runtime whose vendor never shipped the feature.
#
# EMPTY for an unset HERD_AGENT, an unknown name, or a select-flag runtime — so an unset lever leaves
# the task spec BYTE-IDENTICAL. When non-empty it LEADS with its own blank-line separator, so the
# caller concatenates without adding one.
herd_roster_lane_spec_block() {
  local n="${1:-}" drv="${2:-}" f body sentinel
  [ -n "$n" ] || return 0
  f="$(herd_roster_path "$n")" || return 0
  [ "$(herd_roster_probe_kind "$drv")" = "inject" ] || return 0
  body="$(herd_roster_body "$f")"
  [ -n "$body" ] || return 0
  # The sentinel rides ALONG WITH the body. A runtime that loads the definition file natively sees the
  # whole file, frontmatter included; injection must deliver the same facts or the two paths are not
  # the same definition — and, concretely, `herd agents verify`'s positive half asks for the sentinel,
  # so a body-only injection could never produce it and every inject-mode verify would report
  # `unresolved` for a definition that was in fact delivered perfectly. (Caught by a live probe against
  # the real runtime, not by the fixtures.) A definition with no sentinel injects exactly as before.
  sentinel="$(herd_roster_field "$f" sentinel)"
  printf '\n\n[specialist agent: %s] These standing instructions are part of your role for this build; follow them alongside the workflow rules above.%s\n\n%s' \
    "$n" "${sentinel:+$'\n'sentinel: $sentinel}" "$body"
}

# herd_roster_lane_warn <name> <driver> — the LOUD, NON-BLOCKING warning a lane prints when HERD_AGENT
# is set but the roster/cache says the selection will not take effect. Never returns non-zero and
# never blocks the spawn: an operator who asked for a specialist agent gets the build either way, but
# is never left to discover trap T2 by watching the agent make the mistakes its definition forbids.
herd_roster_lane_warn() {
  local n="${1:-}" drv="${2:-}" f sha cached verdict
  [ -n "$n" ] || return 0
  if ! f="$(herd_roster_path "$n")"; then
    printf '⚠️  HERD_AGENT=%s: no definition at %s/%s.md — spawning WITHOUT a specialist agent.\n' \
      "$n" "$(herd_roster_dir)" "$n" >&2
    return 0
  fi
  sha="$(herd_roster_sha "$f")"
  cached="$(herd_roster_cache_get "$drv" "$n" "$sha")"
  verdict="${cached%%$'\t'*}"
  case "$verdict" in
    ok|'') return 0 ;;
    *)
      printf '⚠️  HERD_AGENT=%s: last `herd agents verify` on driver %s said %s — %s\n' \
        "$n" "$drv" "$verdict" "${cached#*$'\t'}" >&2
      printf '   Spawning ANYWAY (never blocking), but this builder may run as a plain agent. Re-check with: herd agents verify %s\n' \
        "$n" >&2 ;;
  esac
  return 0
}

# ── reporting: list + doctor ──────────────────────────────────────────────────────────────────────

# herd_roster_list — the roster plus, per entry, the ACTIVE driver's resolution state read from the
# CACHE (never a live probe — `herd agents verify` owns the spawning). Always exits 0.
herd_roster_list() {
  local drv mode kind dir n f sha cached verdict desc reason skipped
  drv="$(herd_driver_name 2>/dev/null || printf 'herdr-claude')"
  mode="$(herd_roster_mode "$drv")"
  kind="$(herd_roster_probe_kind "$drv")"
  dir="$(herd_roster_definition_dir "$drv")"
  printf 'roster: %s\n' "$(herd_roster_dir)"
  printf 'driver: %s   definition-mode: %s   selection: %s   lookup-path: %s\n' \
    "$drv" "$mode" "$kind" "${dir:-<none>}"
  reason="$(herd_roster_degrade_reason DRIVER_AGENT_SELECT_FLAG "$drv")"
  [ -n "$reason" ] && printf '        no by-name selector on this runtime (%s) — definitions are INJECTED into the task spec\n' "$reason"
  skipped="$(herd_roster_skipped_names)"
  if [ -z "$(herd_roster_names)" ]; then
    printf '\n(no definitions yet — scaffold one with: herd agents new <name>)\n'
    if [ -n "$skipped" ]; then
      while IFS= read -r n; do
        [ -n "$n" ] || continue
        printf '  skipped: %s.md (%s)\n' "$n" "$(_herd_roster_skip_reason "$(herd_roster_dir)/$n.md")"
      done <<< "$skipped"
    fi
    return 0
  fi
  printf '\n%-24s %-14s %s\n' "NAME" "STATE" "DESCRIPTION"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$(herd_roster_path "$n")" || continue
    sha="$(herd_roster_sha "$f")"
    desc="$(herd_roster_field "$f" description)"
    cached="$(herd_roster_cache_get "$drv" "$n" "$sha")"
    verdict="${cached%%$'\t'*}"
    [ -n "$verdict" ] || verdict="unverified"
    # One row per definition, so the description is elided rather than wrapped — `herd agents show`
    # prints the whole thing. A table that reflows on a long description stops reading as a table.
    desc="${desc:-—}"
    [ "${#desc}" -gt 72 ] && desc="${desc:0:69}..."
    printf '%-24s %-14s %s\n' "$n" "$verdict" "$desc"
  done <<< "$(herd_roster_names)"
  if [ -n "$skipped" ]; then
    while IFS= read -r n; do
      [ -n "$n" ] || continue
      printf '  skipped: %s.md (%s)\n' "$n" "$(_herd_roster_skip_reason "$(herd_roster_dir)/$n.md")"
    done <<< "$skipped"
  fi
  printf '\nstate is the CACHED verdict for (driver=%s, definition sha) — re-probe with: herd agents verify\n' "$drv"
  return 0
}

# herd_roster_show <name> — the full definition (frontmatter fields + body).
herd_roster_show() {
  local n="${1:-}" f
  if ! f="$(herd_roster_path "$n")"; then
    printf 'herd agents show: no definition for "%s" in %s\n' "${n:-<empty>}" "$(herd_roster_dir)" >&2
    return 1
  fi
  cat "$f"
}

# herd_roster_scaffold <name> — write a NEW definition from the shipped template, with the name and a
# unique verification sentinel substituted in. Refuses to overwrite an existing definition. The
# sentinel is what makes the definition EMPIRICALLY verifiable (trap T2), so it is scaffolded in by
# default rather than left as an optional extra an author has to know about.
herd_roster_scaffold() {
  local n="${1:-}" dir f tmpl sentinel here
  if ! herd_roster_name_ok "$n"; then
    printf 'herd agents new: invalid name "%s" — use [A-Za-z0-9._-] only\n' "${n:-<empty>}" >&2
    return 1
  fi
  dir="$(herd_roster_dir)"
  f="$dir/$n.md"
  if [ -e "$f" ]; then
    printf 'herd agents new: %s already exists — edit it, or pick another name\n' "$f" >&2
    return 1
  fi
  here="${_HERD_ROSTER_HERE:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
  tmpl="${HERD_AGENT_TEMPLATE:-$here/../../templates/agent-definition.md.tmpl}"
  if [ ! -f "$tmpl" ]; then
    printf 'herd agents new: template not found (%s)\n' "$tmpl" >&2
    return 1
  fi
  mkdir -p "$dir" 2>/dev/null || { printf 'herd agents new: cannot create %s\n' "$dir" >&2; return 1; }
  # A sentinel unique to THIS definition. Derived from the name + the current epoch so two projects
  # never collide and a regenerated definition never reuses a retired token.
  sentinel="HERD-AGENT-$n-$(date +%s)"
  HERD_ROSTER_TMPL="$tmpl" HERD_ROSTER_NAME="$n" HERD_ROSTER_SENTINEL="$sentinel" python3 -c '
import os, sys
text = open(os.environ["HERD_ROSTER_TMPL"], encoding="utf-8").read()
text = text.replace("{{AGENT_NAME}}", os.environ["HERD_ROSTER_NAME"])
text = text.replace("{{AGENT_SENTINEL}}", os.environ["HERD_ROSTER_SENTINEL"])
sys.stdout.write(text)
' > "$f" 2>/dev/null || { printf 'herd agents new: could not write %s\n' "$f" >&2; rm -f "$f" 2>/dev/null; return 1; }
  printf 'scaffolded %s\n' "$f"
  printf '  1. edit the description + body (the body IS the system prompt)\n'
  printf '  2. herd agents install     # publish to the runtime lookup path (no-op when not needed)\n'
  printf '  3. herd agents verify %s\n' "$n"
  printf '  4. HERD_AGENT=%s scripts/herd/herd-feature.sh <slug> "<task>"\n' "$n"
  return 0
}

# herd_roster_doctor_section [--probe] — the roster leg of `herd doctor`. ADVISORY and always 0: it
# reads the CACHE (no spawning) and flags entries that are unverified or that a prior probe said do
# not resolve. `--probe` re-runs the live probe first. Byte-inert when no roster exists.
herd_roster_doctor_section() {
  local probe="${1:-}" drv n f sha cached verdict flagged=0
  [ -n "$(herd_roster_names)" ] || return 0
  drv="$(herd_driver_name 2>/dev/null || printf 'herdr-claude')"
  printf '\nAgent roster (%s, driver %s) — advisory:\n' "$(herd_roster_dir)" "$drv"
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    f="$(herd_roster_path "$n")" || continue
    [ "$probe" = "--probe" ] && herd_roster_verify "$n" "$drv" >/dev/null 2>&1
    sha="$(herd_roster_sha "$f")"
    cached="$(herd_roster_cache_get "$drv" "$n" "$sha")"
    verdict="${cached%%$'\t'*}"
    case "${verdict:-unverified}" in
      ok) printf '  \xe2\x9c\x93 %s\n' "$n" ;;
      unverified)
        printf '  \xe2\x9a\xa0\xef\xb8\x8f  %s — not verified against this driver+sha\n' "$n"
        printf '      fix: herd agents verify %s\n' "$n"; flagged=1 ;;
      *)
        printf '  \xe2\x9c\x97 %s — %s: %s\n' "$n" "$verdict" "${cached#*$'\t'}"
        printf '      fix: herd agents install && herd agents verify %s\n' "$n"; flagged=1 ;;
    esac
  done <<< "$(herd_roster_names)"
  [ "$flagged" -eq 1 ] && printf '  (advisory only — a roster entry never blocks a spawn; re-probe live with: herd doctor --probe)\n'
  return 0
}

# ── CLI entrypoint ────────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced): `bash agents.sh <sub> …`, which is what `herd agents`
# dispatches to. Sources herd-config.sh (PROJECT_ROOT / WORKTREES_DIR / MODEL_QUICK) and driver.sh
# (the binding readers + the one-shot seam) — sourcing them is a source-time no-op by their contract.
_herd_roster_cli() {
  local sub="${1:-list}" n rc=0
  shift 2>/dev/null || true
  case "$sub" in
    list|'') herd_roster_list ;;
    show)    herd_roster_show "${1:-}" || return 1 ;;
    new)     herd_roster_scaffold "${1:-}" || return 1 ;;
    install) herd_roster_install "${HERD_DRIVER:-}" || return 1 ;;
    verify)
      if [ -n "${1:-}" ]; then
        herd_roster_verify "$1"
      else
        if [ -z "$(herd_roster_names)" ]; then
          printf 'herd agents verify: no definitions in %s\n' "$(herd_roster_dir)"
          return 0
        fi
        printf 'verifying roster against driver %s:\n' "$(herd_driver_name)"
        while IFS= read -r n; do
          [ -n "$n" ] || continue
          herd_roster_verify "$n"
        done <<< "$(herd_roster_names)"
      fi ;;
    dir)     herd_roster_dir; echo ;;
    -h|--help|help)
      printf 'usage: herd agents {list|new <name>|show <name>|install|verify [<name>]|dir}\n' ;;
    *)
      printf 'usage: herd agents {list|new <name>|show <name>|install|verify [<name>]|dir}\n' >&2
      rc=2 ;;
  esac
  return "$rc"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _HERD_ROSTER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "$_HERD_ROSTER_HERE/herd-config.sh"
  # shellcheck source=/dev/null
  . "$_HERD_ROSTER_HERE/driver.sh"
  _herd_roster_cli "$@"
fi
