#!/usr/bin/env bash
# driver.sh — the RUNTIME driver shim: the ONE seam binding each runtime-specific control-surface
# capability (the multiplexer + the agent runtime) to a concrete implementation, dispatched on the
# HERD_DRIVER config key (default herdr-claude). This is the runtime counterpart to the render-time
# {{DRIVER_*}} tokenization in bin/herd (docs/driver-abstraction.md phase 2).
#
# WHY THIS EXISTS (HERD-7): the coordinator SKILL is already driver-tokenized at render time. But the
# WATCHER (agent-watch.sh) and the LANE SCRIPTS exercise the SAME capabilities — list-agents,
# read-pane, send-text/keys, start-agent, notifications — at RUNTIME, hard-wired to herdr. This file
# makes those runtime uses driver-aware too, so HERD_DRIVER=headless makes panes a VIEW, not a
# dependency: the load-bearing core (merge gating, journal writes, notifications, limit detection)
# runs correctly with NO herdr panes at all. Unlocks Windows / CI / headless Linux.
#
# CONTRACT:
#   • SOURCED, not executed, by engine components AFTER herd-config.sh (which provides WORKTREES_DIR).
#     Defines functions ONLY; sourcing has NO side effects — safe in lib mode / hermetic tests.
#   • Also RUNNABLE as a CLI (`bash driver.sh <cap> …`) so the rendered HEADLESS coordinator skill
#     drives the same surface (list-agents / read-pane / send-text / focus / …). The CLI entrypoint —
#     and ONLY the CLI entrypoint — sources herd-config.sh to resolve WORKTREES_DIR.
#   • FAIL SOFT: every capability returns 0 (or a safe empty result) on any failure. A missing pane,
#     a missing herdr, a missing registry — NONE may abort a caller running under `set -euo pipefail`.
#   • BYTE-IDENTICAL DEFAULT: for HERD_DRIVER=herdr-claude every capability runs the EXACT herdr
#     command it replaces, so the default driver's behavior is unchanged.

# herd_driver_name — the active driver (env HERD_DRIVER wins; else the sourced config value; default).
herd_driver_name() { printf '%s' "${HERD_DRIVER:-herdr-claude}"; }

# _herd_driver_is_headless — success iff the active driver is the headless driver.
_herd_driver_is_headless() { [ "$(herd_driver_name)" = "headless" ]; }

# herd_driver_endpoint_env_lines — emit K=V lines for the claude custom endpoint (HERD-171).
# When ANTHROPIC_BASE_URL is set (machine-scoped config key / config.local), every spawn path injects
# it so Claude Code hits the enterprise/BAA or local gateway. Empty when unset → byte-identical argv
# (no --env). Pure: reads the env, prints zero or more lines, never fails.
herd_driver_endpoint_env_lines() {
  if [ -n "${ANTHROPIC_BASE_URL:-}" ]; then
    printf 'ANTHROPIC_BASE_URL=%s\n' "$ANTHROPIC_BASE_URL"
  fi
}

# ── MODEL matrix: runtime-qualified model refs (HERD-151) ─────────────────────────────────────────
# Every MODEL_* config key accepts an OPTIONALLY runtime-qualified ref '<driver>:<model>', so an
# operator can pin a role's agent to a specific RUNTIME (a shipped templates/drivers/<name>.driver)
# AND model, not just Claude. A BARE value (no '<driver>:' prefix) resolves to the DEFAULT driver with
# the whole value as the model — so every existing bare-claude config is BYTE-IDENTICAL.
#
# WHY THIS SEAM (driver.sh, not herd-config.sh): a model ref binds a role to a RUNTIME, and the runtime
# surface is exactly what PR #264's DRIVER_AGENT_* audit factored into the .driver files. The valid
# driver set IS the templates/drivers/*.driver enumeration render_skill() already validates HERD_DRIVER
# against; keeping the resolver here reuses that ground truth and sits it next to the exec bindings the
# routing phases (HERD-150 P2–P5) will thread the resolved (driver,model) through. driver.sh is already
# sourced by every spawn lane (feature/quick/resolve/review/scribe/research) + bin/herd, so one helper
# covers the whole spawn surface. herd-config.sh only sets defaults and is sourced everywhere — a loud
# resolver there would be the wrong altitude (config load must never abort; a spawn MUST, on a bad ref).
#
# CONTRACT EXCEPTION to driver.sh's fail-soft rule: an UNKNOWN driver prefix is a LOUD hard error
# (stderr + non-zero), NEVER a silent claude fallback — that is the whole point of the format. This is
# deliberate: fail-soft protects the pane/mux capabilities so a missing herdr never blocks the merge
# gate; a misconfigured MODEL ref is an OPERATOR ERROR that must stop the spawn, not silently downgrade
# to the wrong runtime. All the resolver functions are still pure (no side effects on source).

# _herd_drivers_dir — the templates/drivers directory holding the shipped <name>.driver files, the
# authoritative valid-driver set. HERD_DRIVERS_DIR overrides it (the same knob bin/herd + the driver
# tests use). Resolved relative to THIS file (scripts/herd/driver.sh → ../../templates/drivers) so it
# works in both the vendored dogfood layout and a global install where scripts/ and templates/ are
# siblings under HERDKIT_HOME.
_herd_drivers_dir() {
  if [ -n "${HERD_DRIVERS_DIR:-}" ]; then printf '%s' "$HERD_DRIVERS_DIR"; return 0; fi
  local here; here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null || true)"
  printf '%s/../../templates/drivers' "$here"
}

# herd_driver_known <name> — success iff <name> is a shipped driver (a templates/drivers/<name>.driver
# file exists). The valid-driver oracle the qualified-ref resolver checks a '<driver>:' prefix against.
herd_driver_known() {
  local name="${1:-}" dir
  [ -n "$name" ] || return 1
  dir="$(_herd_drivers_dir)"
  [ -f "$dir/$name.driver" ]
}

# _herd_known_drivers — space-separated list of the shipped driver names (for the loud error message),
# or '<none>' when the drivers dir cannot be read.
_herd_known_drivers() {
  local dir f out=""; dir="$(_herd_drivers_dir)"
  if [ -d "$dir" ]; then
    for f in "$dir"/*.driver; do
      [ -e "$f" ] || continue
      f="${f##*/}"; out="${out:+$out }${f%.driver}"
    done
  fi
  printf '%s' "${out:-<none>}"
}

# herd_driver_agent_value <KEY> [default] [driver] — read a DRIVER_AGENT_* binding from a driver's
# .driver file (the runtime-exec / update catalog block). Defaults to the ACTIVE driver; pass a third
# arg to read a SPECIFIC driver's binding (the spawn composer below reads the RESOLVED runtime driver,
# which a runtime-qualified MODEL ref may make differ from the active one). PURE: it READS the file (a
# single grep + quote-strip), it does NOT source it, so it has no side effects and cannot inherit an
# unrelated env var of the same name. FAIL-SOFT: echoes <default> when the drivers dir / file / key is
# unreadable, so a caller under `set -euo pipefail` never aborts. The AGENT_UPDATE mechanism reads the
# runtime binary + installer package names through this, making the knob driver-aware (claude/codex/grok).
herd_driver_agent_value() {
  local key="${1:-}" dflt="${2:-}" drv="${3:-}" f line v
  [ -n "$key" ] || { printf '%s' "$dflt"; return 0; }
  [ -n "$drv" ] || drv="$(herd_driver_name)"
  f="$(_herd_drivers_dir)/$drv.driver"
  [ -f "$f" ] || { printf '%s' "$dflt"; return 0; }
  line="$(grep -E "^${key}=" "$f" 2>/dev/null | tail -n1 || true)"
  [ -n "$line" ] || { printf '%s' "$dflt"; return 0; }
  v="${line#*=}"
  # Strip a single pair of surrounding single- or double-quotes (the .driver value convention).
  case "$v" in
    \'*\') v="${v#\'}"; v="${v%\'}" ;;
    \"*\") v="${v#\"}"; v="${v%\"}" ;;
  esac
  [ -n "$v" ] && printf '%s' "$v" || printf '%s' "$dflt"
}

# herd_driver_agent_runtime [driver] — the RUNTIME EXECUTABLE a driver spawns: the first whitespace
# token of its DRIVER_AGENT_ONESHOT_EXEC binding (the capability the one-shot seam implements), falling
# back to DRIVER_AGENT_INTERACTIVE_SPAWN. Empty when neither is bound (a driver with no agent-exec
# surface) — the caller then defaults to `claude`, so an absent binding degrades to today's behavior.
# Built ON herd_driver_agent_value (PURE, no sourcing — HERD-149): for herdr-claude/headless/codex/grok
# it is that driver's runtime binary; for the stub proof driver it is the stub runtime, proving the
# one-shot seam is not hard-wired to `claude` by construction (HERD-177 P6).
# [driver] defaults to the ACTIVE driver (herd_driver_agent_value's own default), so every pre-HERD-276
# call site is unchanged; the mixed-vendor review panel passes the RESOLVED driver of a per-panelist
# runtime-qualified MODEL ref so it can (a) pick that vendor's binary and (b) probe it before dispatch.
herd_driver_agent_runtime() {
  local drv="${1:-}" b
  b="$(herd_driver_agent_value DRIVER_AGENT_ONESHOT_EXEC "" "$drv")"
  [ -n "$b" ] || b="$(herd_driver_agent_value DRIVER_AGENT_INTERACTIVE_SPAWN "" "$drv")"
  [ -n "$b" ] || return 0
  printf '%s' "${b%%[[:space:]]*}"
}

# herd_model_resolve <ref> — resolve an optionally runtime-qualified MODEL_* value into its concrete
# driver + model. On success echoes two TAB-separated tokens "<driver>\t<model>" and returns 0:
#   • BARE (no colon)                → "<default-driver>\t<ref>"  (herd_driver_name; byte-identical)
#   • '<known-driver>:<model>'       → "<driver>\t<model>"        (split on the FIRST colon)
#   • EMPTY ref                      → "<default-driver>\t"        (empty model = no --model; unchanged)
# On an UNKNOWN driver prefix, or a '<known-driver>:' with an EMPTY model, it prints a LOUD one-line
# error to stderr and returns 1 — never a silent fallback. Splitting on the FIRST colon lets the model
# id itself contain colons (e.g. a qualified 'ollama:llama3:8b' → driver ollama, model 'llama3:8b').
herd_model_resolve() {
  local ref="${1:-}"
  case "$ref" in
    *:*) ;;                                              # candidate qualified ref (has a colon)
    *) printf '%s\t%s' "$(herd_driver_name)" "$ref"; return 0 ;;   # bare (incl. empty) → default driver
  esac
  local drv="${ref%%:*}" mdl="${ref#*:}"
  if ! herd_driver_known "$drv"; then
    printf '❌ herd: MODEL ref %s names an unknown runtime driver %s — no templates/drivers/%s.driver. Known drivers: %s. Use a bare model (default driver) or a known <driver>:<model> ref; a bad ref never silently falls back to claude.\n' \
      "'$ref'" "'$drv'" "$drv" "$(_herd_known_drivers)" >&2
    return 1
  fi
  if [ -z "$mdl" ]; then
    printf "❌ herd: MODEL ref %s has an empty model after the '%s:' driver prefix — write %s or a bare model id.\n" \
      "'$ref'" "$drv" "'$drv:<model>'" >&2
    return 1
  fi
  printf '%s\t%s' "$drv" "$mdl"
}

# herd_model_for_spawn <ref> — the LANE convenience: resolve <ref> and echo ONLY the bare model to pass
# to the runtime (e.g. `claude --model <model>`). An empty ref stays empty (no --model). On an unknown
# driver / empty-model ref it prints the loud error (via herd_model_resolve) and returns 1, so a lane
# aborts with `MODEL="$(herd_model_for_spawn "$MODEL")" || exit 1` instead of spawning on a bad ref.
# BYTE-IDENTICAL for every bare value: a bare model resolves to itself.
herd_model_for_spawn() {
  local ref="${1:-}" out
  [ -n "$ref" ] || { printf ''; return 0; }
  out="$(herd_model_resolve "$ref")" || return 1
  printf '%s' "${out#*$'\t'}"
}

# herd_model_driver_for <ref> — echo just the resolved DRIVER for a ref (default driver for a bare
# value). Fail-soft companion for callers that only want the runtime side and must not abort: an
# unknown-driver ref echoes nothing and returns 1 (no loud message — herd_model_for_spawn owns the
# loud path at spawn time). The routing phases (HERD-150 P2–P5) consume this to pick the runtime.
herd_model_driver_for() {
  local ref="${1:-}" out
  out="$(herd_model_resolve "$ref" 2>/dev/null)" || return 1
  printf '%s' "${out%%$'\t'*}"
}

# herd_model_escalate_target — the model a matched MODEL_ESCALATE_GLOB forces (HERD-376): MODEL_ESCALATE
# when the operator set it, else MODEL_FEATURE (today's behavior). Both herd-feature.sh and
# herd-quick.sh's glob-escalation branch call this so the "which model does a match force" decision
# lives in exactly one place. BYTE-IDENTICAL when MODEL_ESCALATE is unset: echoes MODEL_FEATURE, same
# as the inline literal it replaces.
herd_model_escalate_target() {
  printf '%s' "${MODEL_ESCALATE:-$MODEL_FEATURE}"
}

# ── Model accessibility preflight (HERD-282) ──────────────────────────────────────────────────────
# herd_model_preflight_accessible <ref> <driver> <model> — fast, fail-soft pre-spawn check: is the
# resolved runtime binary accessible on this machine? Call BEFORE worktree creation so a bad model
# ref fails LOUD and EARLY instead of launching a doomed builder that wedges silently.
#
# CONTRACT:
#   • Returns 0 when the model appears accessible (or when the check cannot determine inaccessibility).
#   • Returns 1 (loud ❌ to stderr, naming the bad ref and missing binary) ONLY on DEFINITIVE 'no
#     access': the runtime binary the resolved <driver> maps to is not on PATH. Any other failure
#     condition (unreadable .driver file, empty binary name, API-level unavailability we cannot probe
#     without a network round-trip) degrades to 0 — ONLY a definitive absence refuses.
#   • Bypass: HERD_SKIP_MODEL_PREFLIGHT=1 (tests / CI that stub the binary; mirrors HERD_SKIP_PREFLIGHT).
#   • Byte-identical when the model is fine: no output, no side effects, returns 0.
herd_model_preflight_accessible() {
  local ref="${1:-}" drv="${2:-}" model="${3:-}"
  # Bypass for tests / CI — same knob pattern as HERD_SKIP_PREFLIGHT for herd_preflight.
  [ "${HERD_SKIP_MODEL_PREFLIGHT:-}" = "1" ] && return 0
  # Need a resolved driver name to look up the binary; fail-soft on empty.
  [ -n "$drv" ] || return 0
  # Resolve the runtime binary from the driver's exec binding (herd_driver_agent_runtime reads
  # DRIVER_AGENT_ONESHOT_EXEC / INTERACTIVE_SPAWN from the .driver file; fail-soft: returns empty
  # when the file is absent or carries no exec binding → we allow the spawn rather than false-refusing).
  local binary; binary="$(herd_driver_agent_runtime "$drv" 2>/dev/null || true)"
  [ -n "$binary" ] || return 0   # no binary resolved → can't check → fail-soft, allow spawn
  # Definitive 'no access': the runtime binary is not on PATH — this spawn cannot possibly succeed
  # regardless of the model id or API state.
  if ! command -v "$binary" >/dev/null 2>&1; then
    local _display="${ref:-${drv}:${model}}"
    printf '❌ herd: model %s cannot spawn — runtime binary %s (driver %s) is not on PATH.\n' \
      "'$_display'" "'$binary'" "'$drv'" >&2
    printf '   Fix: install %s, or use a bare claude model ref (e.g. MODEL_FEATURE=claude-sonnet-4-6).\n' \
      "$binary" >&2
    return 1
  fi
  return 0
}

# ── Agent-runtime EXEC composition (HERD-150 P2 — route the lanes through the P1 bindings) ─────────
# P1 (PR #264) CATALOGUED every claude-specific incantation into DRIVER_AGENT_* bindings carried as
# DATA in templates/drivers/<name>.driver; nothing consumed them, so the tree stayed byte-identical.
# P2 makes the INTERACTIVE-SPAWN binding REAL at spawn: the lane/shim no longer HARDCODES
# `claude --model … <flags> <prompt>` but COMPOSES the agent-runtime argv from the RESOLVED driver's
# DRIVER_AGENT_INTERACTIVE_SPAWN template. Two consequences:
#   • a runtime-qualified MODEL ref (HERD-151, `<driver>:<model>`) now actually launches THAT driver's
#     runtime — the driver half is no longer resolved-then-DISCARDED, it selects the spawn binding;
#   • a future non-Claude runtime (P5) rebinds this ONE block instead of forking every spawn lane.
# BYTE-IDENTICAL for the shipped drivers: both herdr-claude and headless carry the `claude …` shape,
# so composing against them reproduces today's exact argv (the lane spawn test is the rail).

# The per-driver DRIVER_AGENT_* reader these helpers use is herd_driver_agent_value (above), passing the
# resolved <driver> as its third arg so a runtime-qualified MODEL ref reads the RIGHT driver's binding.

# herd_driver_agent_spawn_argv <driver> <model> <flags> <prompt> — compose the AGENT-RUNTIME argv for
# an INTERACTIVE SPAWN from <driver>'s DRIVER_AGENT_INTERACTIVE_SPAWN template, emitting each token
# NUL-TERMINATED so a caller reads it into an array (the prompt may hold spaces / newlines). The
# template is shell-tokenized (quotes respected — `"<prompt>"` is ONE token); each token maps as:
#   <model>                    → the <model> value; if EMPTY, DROP it AND the preceding --model flag
#   <prompt>                   → the <prompt> value (one token, verbatim)
#   the permission-flag token  → replaced by <flags>, whitespace-split (empty <flags> → dropped)
#   anything else              → kept literally (the runtime executable + its fixed flags)
# The permission-flag token is <driver>'s DRIVER_AGENT_PERMISSION_FLAG value, so a runtime that renames
# or drops the yolo flag still composes correctly — the permission flag is honored as its OWN P1 class.
# FAIL-SOFT: a driver with no spawn/permission binding falls back to today's exact claude shape, so a
# misconfigured/foreign driver still spawns a real command (never an empty argv). BYTE-IDENTICAL to the
# pre-P2 hardcoded `claude --model <model> <flags> <prompt>` for herdr-claude and headless.
herd_driver_agent_spawn_argv() {
  local drv="${1:-}" model="${2:-}" flags="${3:-}" prompt="${4:-}" binding perm
  [ -n "$drv" ] || drv="$(herd_driver_name)"
  binding="$(herd_driver_agent_value DRIVER_AGENT_INTERACTIVE_SPAWN "" "$drv")"
  perm="$(herd_driver_agent_value DRIVER_AGENT_PERMISSION_FLAG "" "$drv")"
  [ -n "$binding" ] || binding='claude --model <model> --dangerously-skip-permissions "<prompt>"'
  [ -n "$perm" ]    || perm='--dangerously-skip-permissions'
  # HERD grok-context-injection: a binding may carry a <agents-rules> value token (only grok.driver
  # does today) — the repo-root project conventions (AGENTS.md/CLAUDE.md) grounding a runtime that
  # does NOT auto-load CLAUDE.md. Resolve it ONLY when the token is present, so a claude/headless spawn
  # (whose binding has no such token) never even reads the file — its argv is byte-identical to before.
  # Fail-soft: no conventions → empty, and the composer drops the flag+value pair (see <agents-rules>).
  local agents=""
  case "$binding" in *'<agents-rules>'*)
    command -v herd_agents_conventions >/dev/null 2>&1 && agents="$(herd_agents_conventions)" ;;
  esac
  HERD_SPAWN_BINDING="$binding" HERD_SPAWN_PERM="$perm" HERD_SPAWN_MODEL="$model" \
  HERD_SPAWN_FLAGS="$flags" HERD_SPAWN_PROMPT="$prompt" HERD_SPAWN_AGENTS="$agents" python3 -c '
import os, shlex, sys
model  = os.environ["HERD_SPAWN_MODEL"]
flags  = os.environ["HERD_SPAWN_FLAGS"].split()   # whitespace split — mirrors bash $flags expansion
prompt = os.environ["HERD_SPAWN_PROMPT"]
agents = os.environ["HERD_SPAWN_AGENTS"]
try:
    toks = shlex.split(os.environ["HERD_SPAWN_BINDING"])
    perm = os.environ["HERD_SPAWN_PERM"]
    out = []
    for t in toks:
        if t == "<model>":
            if model:
                out.append(model)
            elif out and out[-1] == "--model":
                out.pop()                          # empty model → drop the --model flag+value pair
        elif t == "<agents-rules>":
            if agents:
                out.append(agents)
            elif out and out[-1] == "--append-rules-to-system-prompt":
                out.pop()                          # no conventions → drop the append-rules flag+value pair
        elif t == "<prompt>":
            out.append(prompt)
        elif t == perm:
            out.extend(flags)                      # permission flag → the (word-split) flags override
        else:
            out.append(t)
except Exception:
    # Unparseable binding falls back to the native claude shape, so a spawn is never silently dropped.
    out = ["claude"] + (["--model", model] if model else []) + flags + [prompt]
sys.stdout.write("".join(tok + "\0" for tok in out))
'
}

# herd_driver_lane_permission_flags <driver> — the permission FLAGS a builder LANE passes as the spawn's
# <flags> (which herd_driver_agent_spawn_argv substitutes for <driver>'s DRIVER_AGENT_PERMISSION_FLAG
# token). HERD-201: the lanes previously hardcoded CLAUDE_FLAGS to claude's --dangerously-skip-permissions
# and passed it UNCONDITIONALLY — so a runtime-qualified MODEL ref ('grok:…','codex:…') composed the
# claude flag into a non-claude runtime ('grok … --dangerously-skip-permissions') and the agent died on
# launch. This helper derives the flags correctly:
#   • an EXPLICIT non-empty HERD_CLAUDE_FLAGS override WINS, verbatim, for ANY runtime (the operator's
#     word beats the derived default — same precedence the old `${HERD_CLAUDE_FLAGS:-…}` gave it);
#   • otherwise the flags come from the RESOLVED runtime driver's OWN DRIVER_AGENT_PERMISSION_FLAG, so
#     each runtime spawns with its own approve flag (grok --always-approve, codex's bypass flag, …).
# BYTE-IDENTICAL for herdr-claude / headless: their permission flag already IS
# --dangerously-skip-permissions, so an unset/empty override yields the EXACT token the lanes hardcoded.
# Empty-or-unset are treated alike (mirrors the old `:-` default) so an explicit empty never drops the
# flag. FAIL-SOFT: an unreadable/absent binding falls back to the claude flag (today's behavior), never
# empty. PURE — no side effects on source.
herd_driver_lane_permission_flags() {
  local drv="${1:-}"
  if [ -n "${HERD_CLAUDE_FLAGS:+set}" ]; then
    printf '%s' "$HERD_CLAUDE_FLAGS"
    return 0
  fi
  [ -n "$drv" ] || drv="$(herd_driver_name)"
  herd_driver_agent_value DRIVER_AGENT_PERMISSION_FLAG '--dangerously-skip-permissions' "$drv"
}

# herd_driver_agent_runtime_native <driver> — success iff <driver>'s agent runtime is the NATIVE Claude
# Code runtime (its DRIVER_AGENT_INTERACTIVE_SPAWN launches `claude`). The mux (herdr) tracks a native
# `claude` agent by fingerprinting the pane's foreground process (herd_driver_agent_liveness's
# has_claude probe); a NON-native runtime is INVISIBLE to that heuristic and must register its own
# session identity + liveness via report-agent (below) — the HERD-178 session-identity seam. FAIL-SOFT:
# an unreadable binding is treated as native so a misconfig never forces the report-agent path.
herd_driver_agent_runtime_native() {
  local drv="${1:-}" binding
  [ -n "$drv" ] || drv="$(herd_driver_name)"
  binding="$(herd_driver_agent_value DRIVER_AGENT_INTERACTIVE_SPAWN "" "$drv")"
  [ -n "$binding" ] || return 0
  [ "${binding%% *}" = "claude" ]
}

# herd_driver_report_agent <slug> <pane> [state] — SESSION-IDENTITY registration for a NON-native agent
# runtime (HERD-178). Tells the herdr mux "this pane IS agent <slug>, state <state>" so the roster /
# liveness surface tracks a foreign runtime by NAME + reported state instead of the claude-cmdline
# heuristic that only recognizes the native runtime — the same `agent`-keyed identity herd_driver_
# agent_liveness already tolerates alongside `name`. herdr mux: `herdr pane report-agent`. headless /
# native runtime / missing pane: a clean no-op. FAIL-SOFT: never aborts a caller, never blocks a spawn —
# an un-registerable foreign agent simply falls back to the mux's own tracking (no red row). This is the
# seam a non-native runtime driver (HERD-150 P5) — or the lanes below, when the resolved runtime is
# non-native — wire their spawn through so a foreign session is visible to the watcher.
herd_driver_report_agent() {
  local slug="${1:-}" pane="${2:-}" state="${3:-working}"
  [ -n "$slug" ] && [ -n "$pane" ] || return 0
  _herd_driver_is_headless && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  # HERD-418: sanitize the registered `--agent` identity, same as every other herdr registration seam.
  slug="$(herd_agent_name_sanitize "$slug")"
  # herdr 0.7.5 made --source REQUIRED (issue #514 fallout); older herdr may not know the flag, so
  # fall back to the bare shape it accepted. Best-effort either way (the fail-soft contract above).
  herdr pane report-agent "$pane" --source herd --agent "$slug" --state "$state" >/dev/null 2>&1 \
    || herdr pane report-agent "$pane" --agent "$slug" --state "$state" >/dev/null 2>&1 || true
  return 0
}

# ── Headless detached-agent registry ─────────────────────────────────────────────────────────────
# Panes-as-a-view means the headless driver needs its own liveness surface. Each builder slug gets a
# directory under $WORKTREES_DIR/.herd/agents/<slug>/ holding:
#   pid     — the detached `claude` PID (liveness is `kill -0 <pid>`)
#   status  — a status word (working|idle|done); best-effort, defaults to "working" while alive
#   log     — captured stdout+stderr (the "pane" a human or the coordinator reads via read-pane)
#   input   — an append-only queue that send-text writes (a headless runtime may drain it)
_herd_agents_dir() {
  local base="${WORKTREES_DIR:-${TREES:-.}}"
  printf '%s' "$base/.herd/agents"
}
_herd_agent_dir() { printf '%s/%s' "$(_herd_agents_dir)" "$1"; }

# ── notify ───────────────────────────────────────────────────────────────────────────────────────
# herd_driver_notify <title> <body> [sound] — surface a desktop-style notification. Load-bearing:
# the watcher notifies on ready/held PRs, dead/respawned builders, and limit resumes. herdr-claude:
# the exact `herdr notification show` call. headless: a durable notifications.log sink (always) plus
# a best-effort native desktop notification. NEVER fails.
herd_driver_notify() {
  local title="${1:-}" body="${2:-}" sound="${3:-default}"
  if _herd_driver_is_headless; then
    _herd_headless_notify "$title" "$body" "$sound"
  else
    herdr notification show "$title" --body "$body" --sound "$sound" >/dev/null 2>&1 || true
  fi
  return 0
}
_herd_headless_notify() {
  local title="${1:-}" body="${2:-}" log ts
  log="${WORKTREES_DIR:-${TREES:-.}}/.herd/notifications.log"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || echo '')"
  mkdir -p "${log%/*}" 2>/dev/null || true
  # Tab-separated one-liner: timestamp, title, body. The durable sink — always written.
  printf '%s\t%s\t%s\n' "$ts" "$title" "$body" >> "$log" 2>/dev/null || true
  # Best-effort native desktop notification (bonus, never required). Kill-switch: NATIVE_NOTIFY=off.
  if [ "${HERD_HEADLESS_NATIVE_NOTIFY:-}" != "off" ]; then
    if command -v osascript >/dev/null 2>&1; then
      osascript -e "display notification \"${body//\"/}\" with title \"${title//\"/}\"" >/dev/null 2>&1 || true
    elif command -v notify-send >/dev/null 2>&1; then
      notify-send "$title" "$body" >/dev/null 2>&1 || true
    fi
  fi
  return 0
}

# ── list-agents ──────────────────────────────────────────────────────────────────────────────────
# herd_driver_agent_list_json — emit the agent roster as JSON in herdr's shape
# ({"result":{"agents":[{"name":<slug>,"agent_status":<word>},…]}}), which the watcher parses for
# builder liveness (dead-builder reconciliation). herdr-claude: `herdr agent list`. headless:
# synthesized from the detached-agent registry, so DEAD detection works with no panes.
herd_driver_agent_list_json() {
  if _herd_driver_is_headless; then
    _herd_headless_agent_list_json
  else
    herdr agent list 2>/dev/null || echo '{}'
  fi
}
_herd_headless_agent_list_json() {
  local dir; dir="$(_herd_agents_dir)"
  HERD_AG_DIR="$dir" python3 - <<'PY' 2>/dev/null || echo '{"result":{"agents":[]}}'
import os, json
d = os.environ.get("HERD_AG_DIR", "")
agents = []
if d and os.path.isdir(d):
    for slug in sorted(os.listdir(d)):
        adir = os.path.join(d, slug)
        if not os.path.isdir(adir):
            continue
        try:
            with open(os.path.join(adir, "pid")) as f:
                pid = f.read().strip()
        except OSError:
            pid = ""
        # A recorded-but-dead pid is NOT a listed agent — it mirrors a pane that was destroyed, which
        # is exactly the signal dead-builder reconciliation keys off. Only live pids appear.
        if not pid.isdigit():
            continue
        try:
            os.kill(int(pid), 0)
        except OSError:
            continue
        status = "working"
        try:
            with open(os.path.join(adir, "status")) as f:
                s = f.read().strip()
                if s:
                    status = s
        except OSError:
            pass
        agents.append({"name": slug, "agent_status": status})
print(json.dumps({"result": {"agents": agents}}, separators=(",", ":")))
PY
}

# ── read-pane ────────────────────────────────────────────────────────────────────────────────────
# herd_driver_read_pane <pane-or-slug> [source] — capture the current pane contents. herdr-claude:
# `herdr pane read`. headless: tail the detached agent's captured log (its on-disk stdout+stderr).
# FAILS SAFE to empty output.
herd_driver_read_pane() {
  local target="${1:-}" source="${2:-}"
  if _herd_driver_is_headless; then
    local f; f="$(_herd_agent_dir "$target")/log"
    [ -f "$f" ] && tail -c "${HERD_READ_PANE_BYTES:-16384}" "$f" 2>/dev/null || true
  elif [ -n "$source" ]; then
    herdr pane read "$target" --source "$source" 2>/dev/null || true
  else
    herdr pane read "$target" 2>/dev/null || true
  fi
}

# ── send-text ────────────────────────────────────────────────────────────────────────────────────
# herd_driver_send_text <pane-or-slug> <text> — send an auto-submitted prompt/command to a builder.
# herdr-claude (HERD-186): `herdr pane run` types the text, then an explicit `herdr pane send-keys
# Enter` SUBMITS it. Live observation 2026-07-08: `pane run` alone can leave the prompt sitting in a
# Claude/agent TUI buffer (REVIEW_AUTOFIX + coordinator re-tasks silently no-op until a human presses
# Enter). The extra Enter is fail-soft and a no-op on an empty shell prompt when the wake already
# works. headless: append to the agent's input queue (best-effort; a bare `claude` process does not
# drain it, so for the default runtime this is a documented no-op seam an SDK/headless runtime can
# consume). NEVER fails.
herd_driver_send_text() {
  local target="${1:-}" text="${2:-}"
  if _herd_driver_is_headless; then
    local q; q="$(_herd_agent_dir "$target")/input"
    mkdir -p "${q%/*}" 2>/dev/null || true
    printf '%s\n' "$text" >> "$q" 2>/dev/null || true
  else
    herdr pane run "$target" "$text" >/dev/null 2>&1 || true
    # Explicit submit (HERD-186) — pane run's documented "text + Enter" is not reliable against a
    # live agent TUI; send-keys Enter is the same keystroke operators use to finish a stuck nudge.
    herdr pane send-keys "$target" Enter >/dev/null 2>&1 || true
  fi
  return 0
}

# ── pane-launch (HERD-322) ───────────────────────────────────────────────────────────────────────
# herd_pane_launch <pane> <cmd> — type a shell command into a BARE pane, robust to herdr's
# first-character drop (HERD-322). herdr drops the leading char at the tty input boundary, so
# `bash /path/to/backlog-view.sh` arrives as `ash /path/to/backlog-view.sh` and the launch fails.
# The fix: prepend a throwaway leading SPACE (absorbs the dropped char, leaving the real command
# intact) and send an explicit Enter to ensure the shell actually executes it. This is THE ONE
# shared helper all control-room pane launches route through — coordinator.sh (backlog/watch pane
# launches) and _reload_pane_run_verified in bin/herd both use this guard internally.
# herdr-claude: pane run " <cmd>" + send-keys Enter. headless: NO-OP (panes-as-a-view).
# FAIL-SOFT: always returns 0; a missing herdr / pane / cmd is silently swallowed.
herd_pane_launch() {
  local pane="${1:-}" cmd="${2:-}"
  [ -n "$pane" ] && [ -n "$cmd" ] || return 0
  _herd_driver_is_headless && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  # Leading space absorbs herdr's first-character drop; explicit Enter submits the command.
  herdr pane run "$pane" " $cmd" >/dev/null 2>&1 || true
  herdr pane send-keys "$pane" Enter >/dev/null 2>&1 || true
  return 0
}

# ── send-keys ────────────────────────────────────────────────────────────────────────────────────
# herd_driver_close_pane <pane-id> — RETIRE a pane (the reviewer-pane lifecycle, HERD-113). herdr-claude:
# `herdr pane close`. headless: NO-OP (panes-as-a-view — a detached reviewer has no pane to close; its
# process lifecycle is the registry pid, not a pane). FAIL-SOFT: a missing herdr / already-gone pane is
# a clean no-op that never aborts a caller — retiring a reviewer pane must never block the merge gate.
herd_driver_close_pane() {
  local target="${1:-}"
  [ -n "$target" ] || return 0
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no pane to close
  else
    # HERD-310: route the live pane close through the shared invocation-context guard so a test that
    # SOURCES the driver from a builder worktree can never close the operator's real panes. Fail-soft:
    # when context-guard.sh is not in scope (driver.sh sourced standalone — its zero-dependency
    # contract) the function is absent and the close proceeds exactly as before. From the control room
    # the guard is a no-op, so a real reviewer/resolver retire is byte-identical.
    if command -v herd_context_pane_guard >/dev/null 2>&1 \
       && ! herd_context_pane_guard "herd_driver_close_pane $target"; then
      return 0
    fi
    herdr pane close "$target" >/dev/null 2>&1 || true
  fi
  return 0
}

# ── guarded pane close (HERD-134) ──────────────────────────────────────────────────────────────────
# The reviewer-pane lifecycle, the review re-dispatch split-close, and the sweeps all close panes by a
# CAPTURED pane id or agent name. A stale/recycled/wrong id kills an innocent NEIGHBOUR — the
# 2026-07-08 incident where a reviewer retire (registry pane id) plus a re-dispatch's purge-old-split
# close vaporised PR #249's live BUILDER pane sharing that tab ("agent session dead" → failed refix
# wakes → hand re-tasking). Same hazard class as cross-project watcher kills (argv0 tagging) and reap
# safety. The fix: verify a pane's LIVE identity at close time and REFUSE when it is not what the
# caller believes it is — loud (a journaled pane_close_refused), never silent.

# herd_driver_pane_identity <pane-id> — read a pane's LIVE identity as a single token, the ground truth
# the guarded close proves a pane against before closing it. Three sources, in priority order — the
# same eyes layout-reconcile / agent-liveness use:
#   agent:<name>  a registered agent (herdr carries the identity in `name` OR `agent`, matched by
#                 pane_id) — e.g. agent:review·<slug>, agent:<builder-slug>. The agent-pane reviewer.
#   pane:<label>  a pane's own LABEL (herdr pane rename / --label), matched by pane_id — the identity
#                 of a NON-agent named pane, e.g. the standalone review·<slug> tail pane.
#   argv:<cmd>    an unlabelled non-agent pane, classified by its FOREGROUND process cmdline (the
#                 scribe drainer, the task-spec viewer, a tail, …)
# Echoes NOTHING when the identity cannot be read (headless — no panes; herdr absent; a gone/opaque
# pane). FAIL-SOFT: a probe that cannot see the truth returns empty so the guard REFUSES rather than
# closing blind — it never fabricates an identity.
herd_driver_pane_identity() {
  local pane="${1:-}"
  [ -n "$pane" ] || return 0
  _herd_driver_is_headless && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  # 1) An agent pane: match this pane_id in the roster. Tolerate BOTH identity keys (`name` for an
  #    `herdr agent start` agent, `agent` for a `herdr pane report-agent` one) — the same breadth
  #    herd_driver_agent_liveness uses so the probe finds the identity however it was registered.
  local name
  name="$(herdr agent list 2>/dev/null | PANE="$pane" python3 -c '
import sys, json, os
pane = os.environ["PANE"]
try:
  for a in (json.load(sys.stdin).get("result") or {}).get("agents") or []:
    if str(a.get("pane_id","")) == pane:
      print("agent:" + (a.get("name") or a.get("agent") or ""), end=""); break
except Exception:
  pass
' 2>/dev/null || true)"
  if [ -n "$name" ]; then printf '%s' "$name"; return 0; fi
  # 2) A named non-agent pane: match this pane_id in the pane roster and read its label (what
  #    `herdr pane rename` / `--label` set) — the identity of the standalone-fallback review pane.
  local label
  label="$(herdr pane list 2>/dev/null | PANE="$pane" python3 -c '
import sys, json, os
pane = os.environ["PANE"]
try:
  for p in (json.load(sys.stdin).get("result") or {}).get("panes") or []:
    if str(p.get("pane_id","")) == pane:
      lbl = p.get("label") or ""
      if lbl: print("pane:" + lbl, end="")
      break
except Exception:
  pass
' 2>/dev/null || true)"
  if [ -n "$label" ]; then printf '%s' "$label"; return 0; fi
  # 3) An unlabelled non-agent pane: classify by the foreground cmdline (excluding the pane's own shell).
  herdr pane process-info --pane "$pane" 2>/dev/null | python3 -c '
import sys, json
try:
  pi = (json.load(sys.stdin).get("result") or {}).get("process_info")
except Exception:
  sys.exit(0)
if not pi:
  sys.exit(0)
sh = pi.get("shell_pid") or 0
fg = [p for p in (pi.get("foreground_processes") or []) if p.get("pid") != sh]
cmd = " ".join((p.get("cmdline") or "") for p in fg).strip()
if cmd:
  sys.stdout.write("argv:" + cmd)
' 2>/dev/null || true
}

# _herd_pane_close_refused_journal <pane> <expected> <actual> <reason> — record a REFUSED close. The
# pane_close_refused event is the forensic ALARM (herd why / herd log) that a close was withheld
# because the pane was NOT what the caller expected — carrying BOTH the expected and actual identities.
# journal.sh is sourced by both engine surfaces that call the guard (agent-watch.sh + herd-review.sh);
# when it is NOT in scope (driver.sh sourced standalone / the CLI) this degrades to a silent no-op so
# driver.sh keeps its zero-dependency, no-side-effect sourcing contract.
_herd_pane_close_refused_journal() {
  command -v journal_append >/dev/null 2>&1 || return 0
  journal_append pane_close_refused pane "${1:-}" expected "${2:-}" actual "${3:-}" reason "${4:-}"
}

# herd_close_pane_verified <pane-id> <expected-kind> — the ONE guarded pane-close every engine actor
# routes through (HERD-134). Reads the pane's LIVE identity (herd_driver_pane_identity) and closes it
# ONLY when that identity CONTAINS <expected-kind> (e.g. "agent:builder-slug" for a builder's own
# pane). On a mismatch — the pane id is stale/recycled and now names an innocent neighbour (the
# builder kill) — it REFUSES the close and journals pane_close_refused with BOTH identities. On an
# unreadable identity it also refuses (fail-soft: never close blind, journal and move on). Returns 0
# IFF the pane was closed. BYTE-IDENTICAL when identities match: a normal retire closes exactly as
# before.
# HERD-418: <expected-kind> is matched as a plain SUBSTRING anywhere in the identity, so a bare role
# word (e.g. "review") also matches any co-tab pane whose slug merely CONTAINS that word (a builder on
# "fix-review-race" reads "agent:fix-review-race"). A caller whose role can surface under BOTH the
# sanitized agent-name form ("agent:review-<slug>") and the pretty label form ("pane:review·<slug>")
# — the reviewer/resolver panes, since herd_agent_name_sanitize maps their middle-dot separator to a
# dash — must pass a COLON-ANCHORED kind (":review", not "review") so it only matches immediately
# after the fixed "agent:"/"pane:" tag, where herd_driver_pane_identity's tag:value shape carries its
# one and only colon.
herd_close_pane_verified() {
  local pane="${1:-}" kind="${2:-}"
  [ -n "$pane" ] || return 1
  # Headless has no panes to verify OR close: defer to the (no-op) driver close so behaviour is
  # byte-identical to the pre-guard path (which never reached a close under headless anyway).
  if _herd_driver_is_headless; then herd_driver_close_pane "$pane"; return 0; fi
  # A missing expected-kind would substring-match anything — refuse rather than close indiscriminately.
  [ -n "$kind" ] || { _herd_pane_close_refused_journal "$pane" "$kind" "" no-expected-kind; return 1; }
  local ident; ident="$(herd_driver_pane_identity "$pane" 2>/dev/null || true)"
  if [ -z "$ident" ]; then
    _herd_pane_close_refused_journal "$pane" "$kind" "" identity-unreadable
    return 1
  fi
  case "$ident" in
    *"$kind"*)
      herd_driver_close_pane "$pane"
      return 0 ;;
    *)
      _herd_pane_close_refused_journal "$pane" "$kind" "$ident" identity-mismatch
      return 1 ;;
  esac
}

# herd_driver_pane_alive <pane-id> — success iff the pane still EXISTS in the live control surface.
# The reviewer-adoption / orphan-sweep liveness probe (HERD-113): after a herdr server death + reload a
# reviewer PANE can outlive its poller pid, so "is the pane still there?" is the signal that must gate a
# re-dispatch (never duplicate into a live reviewer). herdr-claude: `herdr pane read` succeeds only for
# a live pane. headless: always FALSE (no panes; liveness there is the registry pid, checked separately).
# FAIL-SOFT: a missing herdr / unreadable pane → not-alive, so the caller degrades to the pid guard.
herd_driver_pane_alive() {
  local target="${1:-}"
  [ -n "$target" ] || return 1
  if _herd_driver_is_headless; then
    return 1
  fi
  command -v herdr >/dev/null 2>&1 || return 1
  herdr pane read "$target" >/dev/null 2>&1
}

# herd_driver_agent_liveness <slug> [pane_id] — THREE-VALUED liveness of a builder's agent SESSION:
# whether its underlying agent PROCESS is actually running, as opposed to a stale agent_status word
# herdr keeps reporting after a crash killed it (HERD-114). This is DISTINCT from mere pane EXISTENCE
# (herd_driver_pane_alive) and from the status word: the 2026-07-08 incident had a herdr server stop
# KILL both builders' claude processes while their tabs/panes/worktrees persisted and `herdr agent
# list` still reported a stale 'done' — so neither pane-alive nor the status word could tell the
# session was dead. Echoes exactly one token:
#   alive   — POSITIVE evidence the session process runs (headless: a live registry pid; herdr-claude:
#             the agent's pane still has a foreground `claude` process)
#   dead    — POSITIVE evidence it is GONE but a pane REMAINS (headless: a pid recorded but not running;
#             herdr-claude: the pane EXISTS but runs NO claude — a bare shell left behind after the
#             process was killed). "agent dead" = pane present, session unresponsive.
#   missing — POSITIVE evidence the tab has NO agent pane AT ALL (herdr-claude only): herdr answered but
#             the agent is neither in the roster NOR does any pane carry its '<slug>' label — the
#             pane vanished entirely (HERD-135). Distinct from 'dead' (pane present) so a caller can
#             surface 'agent missing' and never bounce a refix into nobody. Only ever returned when
#             herdr responded, so it is never a fabricated absence. Headless never returns this (its
#             liveness is registry-pid based, not pane based — a gone record reads 'unknown').
#   unknown — cannot tell (herdr/process-info absent or unparseable, pane gone, no registry record).
#             FAIL-SOFT: a probe that cannot see the truth NEVER fabricates a death/absence, so a
#             caller degrades to its prior behavior and never false-reds (no-false-red).
herd_driver_agent_liveness() {
  local slug="${1:-}" pane="${2:-}"
  [ -n "$slug" ] || { printf 'unknown'; return 0; }
  if _herd_driver_is_headless; then
    local pidf pid
    pidf="$(_herd_agent_dir "$slug")/pid"
    [ -f "$pidf" ] || { printf 'unknown'; return 0; }
    pid="$(cat "$pidf" 2>/dev/null || true)"
    case "$pid" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
    if kill -0 "$pid" 2>/dev/null; then printf 'alive'; else printf 'dead'; fi
    return 0
  fi
  command -v herdr >/dev/null 2>&1 || { printf 'unknown'; return 0; }
  # HERD-418: the roster's `name`/`agent` identity is whatever herdr actually REGISTERED — the
  # sanitized name for a dotted role (resolve·/review·) — while a pane LABEL stays the pretty
  # requested form (set via herd_driver_pane_rename / --label, never sanitized). Match each against
  # the right form so a delisted-but-labelled pane and a live-but-renamed-roster pane both resolve.
  local reg_slug; reg_slug="$(herd_agent_name_sanitize "$slug")"
  # Resolve the agent's pane when the caller didn't pass one. herdr carries the identity in EITHER
  # `name` (a builder started via `herdr agent start <slug>`) or `agent` (one reported via
  # `herdr pane report-agent --agent <slug>`), so match both — the same tolerance herdr's own consumers
  # use — so the probe finds the pane however the agent was registered.
  if [ -z "$pane" ]; then
    pane="$(herdr agent list 2>/dev/null | SLUG="$reg_slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  for a in (json.load(sys.stdin).get("result") or {}).get("agents") or []:
    if a.get("name") == slug or a.get("agent") == slug:
      print(a.get("pane_id", "") or "", end=""); break
except Exception:
  pass
' 2>/dev/null || true)"
  fi
  # HERD-135: an agent DELISTED from the roster (its process died and herdr dropped the registration)
  # may still own its pane — LABELLED '<slug>' by the lane at spawn. Consult that label so a
  # delisted-but-present pane is still classified (dead/alive) rather than mis-read as gone. Best-effort;
  # a driver/pane with no label just yields no match and we fall through to the 'missing' verdict below.
  if [ -z "$pane" ]; then
    pane="$(herdr pane list 2>/dev/null | SLUG="$slug" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  for p in (json.load(sys.stdin).get("result") or {}).get("panes") or []:
    if str(p.get("label", "")) == slug:
      print(p.get("pane_id", "") or "", end=""); break
except Exception:
  pass
' 2>/dev/null || true)"
  fi
  # No agent in the roster AND no pane carries its label: herdr answered (checked above) yet the agent
  # pane is positively ABSENT — the tab has NO agent pane at all. Return 'missing' (distinct from the
  # probe-blind 'unknown') so a caller surfaces 'agent missing' and never bounces a refix into nobody.
  [ -n "$pane" ] || { printf 'missing'; return 0; }
  # Classify the pane by the process in its FOREGROUND — the same ground-truth eyes layout-reconcile
  # uses: a live `claude` ⇒ alive; a shell with no claude foreground ⇒ dead (the process was killed
  # but the pane persists as a bare shell); missing/opaque process-info or a gone pane ⇒ unknown.
  #
  # The pane's OWN shell (shell_pid) is normally excluded so an idle BARE shell reads 'dead' — but the
  # lane launches claude AS the pane ROOT (no wrapping shell), so shell_pid == the claude pid. Blindly
  # dropping the shell_pid entry then filters the live claude out and fabricates a death (a live idle
  # builder read '💀 AGENT DEAD'). So we exclude the shell_pid entry ONLY when it is a real shell
  # WRAPPER (no claude in its cmdline): a claude-as-root pane keeps its own entry and reads 'alive'.
  herdr pane process-info --pane "$pane" 2>/dev/null | python3 -c '
import sys, json
def has_claude(p): return "claude" in (p.get("cmdline") or "")
try:
  pi = (json.load(sys.stdin).get("result") or {}).get("process_info")
except Exception:
  print("unknown"); sys.exit(0)
if not pi:
  print("unknown"); sys.exit(0)
sh = pi.get("shell_pid") or 0
if not sh:
  print("unknown"); sys.exit(0)
# Keep any foreground process that is NOT the pane shell, OR that IS the shell_pid entry but is itself
# claude (claude launched as the pane root) — the latter is POSITIVE alive evidence, never a wrapper.
fg = [p for p in (pi.get("foreground_processes") or []) if p.get("pid") != sh or has_claude(p)]
print("alive" if any(has_claude(p) for p in fg) else "dead")
' 2>/dev/null || printf 'unknown'
}

# herd_driver_send_keys <pane> <keys…> — send raw control keystrokes. herdr-claude:
# `herdr pane send-keys`. headless: NO-OP (raw keystrokes are a pane concept; nothing receives them).
# NEVER fails.
herd_driver_send_keys() {
  local target="${1:-}"; shift || true
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no pane to receive raw keystrokes
  else
    herdr pane send-keys "$target" "$@" >/dev/null 2>&1 || true
  fi
  return 0
}

# ── pane rename / role labelling (HERD-135) ─────────────────────────────────────────────────────────
# herd_driver_pane_rename <pane> <label> — set a pane's role LABEL. The builder lanes call this at
# spawn to name each pane by role ('<slug>' for the agent pane, 'task-spec·<slug>' for the viewer,
# 'shell·<slug>' for the bare root shell) so the dead-agent-eyes probe (herd_driver_agent_liveness)
# and the coordinator READ a pane's role instead of guessing from position/cmdline — the fix for the
# 2026-07-08 incident where a `claude --continue` was typed into the task-spec viewer pane. herdr-claude:
# `herdr pane rename`. headless: NO-OP (panes-as-a-view — nothing to label). FAIL-SOFT: a missing
# herdr / gone pane / driver that does not support rename is a clean no-op, so the probe simply falls
# back to today's heuristic (no red row). NEVER fails.
herd_driver_pane_rename() {
  local target="${1:-}" label="${2:-}"
  [ -n "$target" ] && [ -n "$label" ] || return 0
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no pane to label
  else
    herdr pane rename "$target" "$label" >/dev/null 2>&1 || true
  fi
  return 0
}

# herd_driver_agent_pane_id <slug> — echo the pane_id herdr currently associates with this agent
# (matched on the `name` OR `agent` identity key, the same breadth the liveness probe uses), so the
# lane can LABEL the freshly-created agent pane. Empty (no output) when headless / herdr absent / the
# agent is not yet listed. FAIL-SOFT: never aborts a caller under set -euo pipefail.
herd_driver_agent_pane_id() {
  local slug="${1:-}"
  [ -n "$slug" ] || return 0
  _herd_driver_is_headless && return 0
  command -v herdr >/dev/null 2>&1 || return 0
  # HERD-418: match on the REGISTERED (sanitized) name — a dotted role request (resolve·/review·)
  # never appears verbatim in the roster, so a raw comparison would never find the pane.
  herdr agent list 2>/dev/null | SLUG="$(herd_agent_name_sanitize "$slug")" python3 -c '
import sys, json, os
slug = os.environ["SLUG"]
try:
  for a in (json.load(sys.stdin).get("result") or {}).get("agents") or []:
    if a.get("name") == slug or a.get("agent") == slug:
      print(a.get("pane_id", "") or "", end=""); break
except Exception:
  pass
' 2>/dev/null || true
}

# herd_driver_pane_id_from_agent_start <json> — best-effort extract of the agent pane id from an
# `herdr agent start` result. Tolerates the shapes herdr uses (result.agent.pane_id /
# result.pane.pane_id / result.pane_id) so a lane can label the pane WITHOUT a second `agent list`
# round-trip. PURE (no herdr call — safe on captured stdout); empty on any parse failure.
herd_driver_pane_id_from_agent_start() {
  local json="${1:-}"
  [ -n "$json" ] || return 0
  printf '%s' "$json" | python3 -c '
import sys, json
try:
  r = (json.load(sys.stdin).get("result") or {})
  pid = ""
  for k in ("agent", "pane"):
    v = r.get(k)
    if isinstance(v, dict) and v.get("pane_id"):
      pid = v["pane_id"]; break
  if not pid and r.get("pane_id"):
    pid = r["pane_id"]
  sys.stdout.write(str(pid or ""))
except Exception:
  pass
' 2>/dev/null || true
}

# ── create-tab ───────────────────────────────────────────────────────────────────────────────────
# herd_driver_create_tab [args…] — create a tab/pane. herdr-claude: `herdr tab create`. headless:
# NO-OP (headless has no tabs; the lane spawns a detached process instead). NEVER fails.
herd_driver_create_tab() {
  if _herd_driver_is_headless; then
    : # no-op: view-only — headless has no tabs
  else
    herdr tab create "$@" 2>/dev/null || true
  fi
  return 0
}

# ── focus-agent ──────────────────────────────────────────────────────────────────────────────────
# herd_driver_focus_agent <slug> — jump to a builder's agent. herdr-claude: `herdr agent focus`.
# headless: VIEW — no pane to focus; print how to tail the agent's log. NEVER fails.
herd_driver_focus_agent() {
  local slug="${1:-}"
  if _herd_driver_is_headless; then
    printf 'headless: no pane to focus for %s. Tail its log:\n  tail -f %s\n' "$slug" "$(_herd_agent_dir "$slug")/log"
  else
    # HERD-418: focus by the REGISTERED (sanitized) name — a raw dotted role name was never registered.
    herdr agent focus "$(herd_agent_name_sanitize "$slug")" 2>/dev/null || true
  fi
  return 0
}

# ── herdr agent-start CLI bridge (issue #514, #516) ─────────────────────────────────────────────────
# herdr 0.7.5 (protocol 17) replaced the pane-CREATING `agent start <name> --workspace … --cwd …
# --tab … [--split …] --no-focus [--env K=V]… -- <runtime argv>` with an ATTACH contract:
#     herdr agent start <NAME> --kind <KIND> --pane <ID> [-- <AGENT_ARG>…]
# Pane creation moved to `tab create` / `pane split` (which own --env now — `agent start` has none),
# and --kind names the runtime's canonical executable, which herdr PREPENDS itself — so the argv
# after `--` must NOT repeat it (proven live: `-- --model …` yielded argv ["claude","--model",…]).
# Other machines still run pre-0.7.5 herdr (fail-soft portability), so BOTH CLIs are supported: a
# one-time per-process capability probe picks the path, and the old argv stays byte-identical.
# The attach result still carries result.agent.pane_id, so every existing stdout parser holds.
# issue #516: the attach flow also cannot shell-encode a MULTILINE agent arg — a drainer lane's
# multi-KB multiline PROMPT rejected with invalid_agent_argument where builder lanes (already
# task-spec-externalized to a one-line pointer) sail through. herd_driver_herdr_attach_agent
# externalizes any multiline runtime arg to a file under the worktree pool before attaching (mirrors
# herd_write_task_spec's externalize-then-short-pointer shape) — ONE fix here heals every lane that
# routes through this bridge, never a per-lane patch. The pre-0.7.5 argv path is untouched.

# _herd_herdr_agent_start_help — the raw `herdr agent start --help` text, queried ONCE per process and
# cached in a plain global (bash-3.2 safe) so every caller that needs to read the installed herdr's
# spawn-contract shape (the attach-CLI probe below, and the HERD-407 driver-CLI viability probe in
# config-viability.sh) shares the SAME one herdr call — never a second parallel detection path. Empty
# when herdr is not on PATH; cached as a single space so a genuinely-empty help text is not re-probed.
_herd_herdr_agent_start_help() {
  if [ -z "${_HERD_HERDR_HELP_CACHE:-}" ]; then
    _HERD_HERDR_HELP_CACHE="$(herdr agent start --help 2>&1 || true)"
    [ -n "$_HERD_HERDR_HELP_CACHE" ] || _HERD_HERDR_HELP_CACHE=' '
  fi
  printf '%s' "$_HERD_HERDR_HELP_CACHE"
}

# _herd_herdr_attach_cli — success iff the installed herdr speaks the attach CLI (its
# `agent start --help` documents --pane). Probed ONCE per process (cached in a plain global —
# bash-3.2 safe); HERD_HERDR_ATTACH_CLI=yes|no bypasses the probe (tests / a wedged herdr).
_herd_herdr_attach_cli() {
  case "${HERD_HERDR_ATTACH_CLI:-}" in yes) return 0 ;; no) return 1 ;; esac
  case "$(_herd_herdr_agent_start_help)" in
    *--pane*) return 0 ;;
    *)        return 1 ;;
  esac
}

# herd_driver_herdr_spawn_shape — classify the installed herdr's `agent start` spawn contract, read
# from its --help text (HERD-407, grounded in issues #514/#516/#526: herdr 0.7.5 broke every spawn
# SILENTLY while the control room looked healthy). Prints exactly one of:
#   attach   herdr documents --pane (>=0.7.5) — the driver seam's ATTACH contract applies.
#   legacy   herdr documents the pre-0.7.5 pane-creating flags (--workspace/--cwd) — the driver seam's
#            legacy argv applies.
#   unknown  herdr is on PATH but its help text matches NEITHER shape — a real spawn-contract drift.
#   absent   herdr is not on PATH at all. Doctor's hard-dependency check already covers this; callers
#            MUST treat `absent` as fail-soft, never as a contract mismatch.
# Reuses _herd_herdr_agent_start_help's cached text — never a second `agent start --help` call.
# HERD_HERDR_ATTACH_CLI=yes|no short-circuits to attach|legacy (tests that stub the boolean only).
herd_driver_herdr_spawn_shape() {
  case "${HERD_HERDR_ATTACH_CLI:-}" in yes) printf attach; return 0 ;; no) printf legacy; return 0 ;; esac
  command -v herdr >/dev/null 2>&1 || { printf absent; return 0; }
  local help; help="$(_herd_herdr_agent_start_help)"
  case "$help" in
    *--pane*) printf attach; return 0 ;;
  esac
  if grep -q -- '--workspace' <<< "$help" && grep -q -- '--cwd' <<< "$help"; then
    printf legacy; return 0
  fi
  printf unknown
}

# _herd_externalize_pointer_arg <name> <arg> — issue #516: herdr's attach CLI cannot shell-encode a
# MULTILINE agent argument ("agent arguments cannot be encoded safely for the target shell"). Builder
# lanes never hit this — they already externalize their full task spec to a file
# (herd_write_task_spec) and hand the agent a one-line pointer — but the drainer lanes (scribe.sh,
# research.sh) still pass a multi-KB multiline PROMPT straight through as the pointer arg. Mirrors
# herd_write_task_spec's shape: write <arg> verbatim to a file under the worktree pool, named after
# the agent, and print a SHORT single-line pointer in its place. FAIL-SOFT (unlike
# herd_write_task_spec's fail-loud contract): a write failure here must not abort an attach that would
# otherwise succeed inline, so on any failure it prints <arg> UNCHANGED — the caller falls back to
# today's behavior and herdr reports the encoding error as before.
_herd_externalize_pointer_arg() {
  local _ep_name="${1:?}" _ep_arg="${2:-}" _ep_file
  _ep_file="${WORKTREES_DIR:-${TREES:-.}}/.pointer-${_ep_name}.md"
  if printf '%s\n' "$_ep_arg" > "$_ep_file" 2>/dev/null && [ -s "$_ep_file" ]; then
    printf 'Read %s and follow it exactly as your instructions.' "$_ep_file"
  else
    printf '%s' "$_ep_arg"
  fi
}

# herd_driver_agent_herdr_kind <driver> <rt0> — the --kind value for the attach CLI: an explicit
# DRIVER_AGENT_HERDR_KIND binding wins (the escape hatch for a runtime whose binary name is not its
# herdr kind), else the basename of the composed argv[0] — exact for every shipped driver (claude /
# codex / grok name their binaries after their kind). A runtime herdr does not know then fails LOUD
# at `agent start` (herdr rejects the kind) instead of silently running claude; an empty argv
# degrades to claude, the default runtime.
herd_driver_agent_herdr_kind() {
  local drv="${1:-}" rt0="${2:-}" k
  k="$(herd_driver_agent_value DRIVER_AGENT_HERDR_KIND "" "$drv")"
  [ -n "$k" ] || k="${rt0##*/}"
  printf '%s' "${k:-claude}"
}

# herd_agent_name_sanitize <name> — HERD-418: herdr ≥0.7.5 validates the agent NAME strictly (must
# start with a lowercase letter; only lowercase letters, digits, dash, underscore; 1-32 chars), so the
# engine's dotted role names (resolve·<slug>, review·<slug> — the middle-dot separator, kept elsewhere
# as the pretty pane/tab LABEL) fail outright with invalid_agent_name. This is the ONE sanitizer every
# registration AND lookup site routes through, so the two can never derive a different name for the
# same request. PURE (no herdr call, no side effects) and DETERMINISTIC: the same input always maps to
# the same output, so a caller that re-derives the name at lookup time (rather than remembering the
# exact string it registered) still finds the right agent — no hash suffix needed for that stability.
# Case-folds first (so an uppercase letter survives instead of becoming a dash), then maps every
# remaining character outside [a-z0-9_-] to a single dash; a result not starting with a lowercase
# letter is prefixed with a single 'a' (spends 1 of the 32 chars, not the 2 an 'a-' filler would); then
# truncated to the 32-char budget.
# COLLISION NOTE: the mapping is many-to-one, not a namespaced encoding, so two DIFFERENT requested
# names can sanitize to the SAME herdr name — e.g. a reviewer role 'review·widget' and a builder slug
# literally named 'review-widget' both map to 'review-widget'; a 32+ char slug that only differs past
# char 32 also collides on truncation. Both are narrow (a builder slug colliding with a role prefix, or
# two slugs differing only past the 32-char mark) and unresolved here — callers that need to tell such
# collisions apart should keep the role/slug namespaces disjoint at the point they choose names, not
# rely on the registered herdr name for that distinction (herd_close_pane_verified's callers must, for
# exactly this reason, colon-anchor an expected-kind — see its own header comment).
herd_agent_name_sanitize() {
  local raw="${1:-}"
  printf '%s' "$raw" | python3 -c '
import re, sys
s = sys.stdin.read().lower()
s = re.sub(r"[^a-z0-9_-]", "-", s)
if not re.match(r"^[a-z]", s):
    s = "a" + s
sys.stdout.write(s[:32])
'
}

# _herd_herdr_tab_root_pane <tab> — the FIRST pane herdr lists for <tab>: a lane-created tab holds
# exactly its root at launch time, and for a shared tab the first-listed pane is the root the splits
# hang off (`tab get` carries no pane ids). Empty on any failure — fail-soft.
_herd_herdr_tab_root_pane() {
  local tab="${1:-}"
  [ -n "$tab" ] || return 0
  herdr pane list 2>/dev/null | TAB="$tab" python3 -c '
import sys, json, os
tab = os.environ["TAB"]
try:
  for p in (json.load(sys.stdin).get("result") or {}).get("panes") or []:
    if p.get("tab_id") == tab:
      print(p.get("pane_id", "") or "", end=""); break
except Exception:
  pass
' 2>/dev/null || true
}

# herd_driver_herdr_attach_agent <name> <driver> <root-pane> <cwd> <split> <focus> [K=V …] -- <rt …>
# The attach-CLI launch, shared by every herdr spawn site: give the agent its OWN pane — split
# <root-pane> when <split> is right|down (env pairs ride `pane split --env`, the pane-creating
# command, so they still reach the agent through the pane's shell), attach straight to <root-pane>
# when <split> is empty — then `agent start <name> --kind … --pane … -- <rt minus argv[0]>`.
# stdout = the `agent start` JSON (result.agent.pane_id — the shape the lanes' parsers consume);
# returns the launch status. A REQUESTED split that yields no pane is a hard failure: attaching to
# the root instead would type over a neighbour pane (the #249 incident class), never fail-soft that.
herd_driver_herdr_attach_agent() {
  local an_name="$1" an_driver="$2" an_root="$3" an_cwd="$4" an_split="$5" an_focus="$6"
  shift 6
  # HERD-418: sanitize the REGISTERED name here — the one seam every attach-CLI caller (builder start
  # + the generalized launch-agent seam) funnels through — so a dotted role name never reaches herdr.
  an_name="$(herd_agent_name_sanitize "$an_name")"
  local -a an_env=()
  while [ $# -gt 0 ] && [ "$1" != "--" ]; do an_env+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  local pane="$an_root"
  if [ -n "$an_split" ]; then
    local -a sp=(herdr pane split "$an_root" --direction "$an_split" --cwd "$an_cwd")
    local _kv
    for _kv in ${an_env[@]+"${an_env[@]}"}; do sp+=(--env "$_kv"); done
    if [ "$an_focus" = "yes" ]; then sp+=(--focus); else sp+=(--no-focus); fi
    pane="$("${sp[@]}" 2>/dev/null | python3 -c '
import sys, json
try:
  print((json.load(sys.stdin)["result"]["pane"]["pane_id"]) or "", end="")
except Exception:
  pass
' 2>/dev/null || true)"
    [ -n "$pane" ] || return 1
  fi
  local kind; kind="$(herd_driver_agent_herdr_kind "$an_driver" "${1:-}")"
  [ $# -gt 0 ] && shift   # drop argv[0]: --kind names the canonical executable; herdr prepends it
  # issue #516: the attach CLI cannot shell-encode a MULTILINE arg ("agent arguments cannot be
  # encoded safely for the target shell") — a drainer lane's multi-KB multiline PROMPT rides in here
  # verbatim. Externalize any such arg UP FRONT (see _herd_externalize_pointer_arg above) so the
  # common case never even round-trips through herdr's error path.
  local -a an_rt=("$@")
  local an_had_nl=0 an_i
  for ((an_i = 0; an_i < ${#an_rt[@]}; an_i++)); do
    case "${an_rt[$an_i]}" in
      *$'\n'*)
        an_rt[an_i]="$(_herd_externalize_pointer_arg "$an_name" "${an_rt[$an_i]}")"
        an_had_nl=1
        ;;
    esac
  done
  # A just-created pane may not have finished spawning its shell yet — herdr refuses the attach with
  # agent_pane_busy (an error JSON on STDERR) until the pane sits at an available prompt (observed
  # live on a scripted split→start). Bounded retry (~10s) instead of a racy sleep; the last attempt's
  # stdout (the JSON the callers parse) / stderr / exit status flow through on their own streams.
  local out rc try=0 errf an_iaa_retried=0
  errf="$(mktemp "${TMPDIR:-/tmp}/herd-attach-err.XXXXXX" 2>/dev/null)" || errf=/dev/null
  while :; do
    out="$(herdr agent start "$an_name" --kind "$kind" --pane "$pane" -- "${an_rt[@]}" 2>"$errf")"; rc=$?
    [ "$rc" -eq 0 ] && break
    case "$out$(cat "$errf" 2>/dev/null)" in
      *agent_pane_busy*) ;;
      *invalid_agent_argument*)
        # Defensive (cheap): no arg LOOKED multiline but herdr still rejected the argv — some other
        # unsafe-for-shell content. Externalize the LAST arg (the pointer, by the spawn binding's
        # convention of trailing <prompt>) and retry ONCE; this is not a transient like
        # agent_pane_busy, so never loop on it.
        if [ "$an_had_nl" = 0 ] && [ "$an_iaa_retried" = 0 ] && [ "${#an_rt[@]}" -gt 0 ]; then
          an_iaa_retried=1
          local an_last=$((${#an_rt[@]} - 1))
          an_rt[an_last]="$(_herd_externalize_pointer_arg "$an_name" "${an_rt[$an_last]}")"
          continue
        fi
        break
        ;;
      *) break ;;
    esac
    try=$((try+1)); [ "$try" -ge 20 ] && break
    sleep 0.5
  done
  [ -n "$out" ] && printf '%s\n' "$out"
  [ -s "$errf" ] && cat "$errf" >&2
  [ "$errf" != /dev/null ] && rm -f "$errf" 2>/dev/null
  return "$rc"
}

# ── start-agent ──────────────────────────────────────────────────────────────────────────────────
# herd_driver_start_agent <slug> <worktree> <model> <flags> <pointer> [split] — spawn a builder agent
# on a task. herdr-claude: a fresh herdr tab + `herdr agent start … claude`. headless: a DETACHED
# background `claude` (nohup) whose stdout+stderr land in the registry log, with a pid/status file so
# list-agents can report its liveness. Returns 0 iff an agent was started.
herd_driver_start_agent() {
  local slug="${1:-}" wt="${2:-}" model="${3:-}" flags="${4:-}" pointer="${5:-}" split="${6:-}"
  # Resolve an optionally runtime-qualified model ref (HERD-151) → the runtime DRIVER *and* bare model,
  # TOGETHER, so the driver half is REAL (HERD-150 P2) instead of resolved-then-discarded: it selects
  # which runtime's DRIVER_AGENT_INTERACTIVE_SPAWN binding composes the spawn argv below. Loud-fails
  # (never a silent claude fallback) on an unknown driver prefix; byte-identical for a bare value.
  local _res rt_driver
  _res="$(herd_model_resolve "$model")" || return 1
  rt_driver="${_res%%$'\t'*}"; model="${_res#*$'\t'}"
  if _herd_driver_is_headless; then
    _herd_headless_start_agent "$slug" "$wt" "$model" "$flags" "$pointer" "$rt_driver"
  else
    _herd_herdr_start_agent "$slug" "$wt" "$model" "$flags" "$pointer" "$split" "$rt_driver"
  fi
}
_herd_headless_start_agent() {
  local slug="$1" wt="$2" model="$3" flags="$4" pointer="$5" rt_driver="${6:-}"
  [ -n "$slug" ] && [ -d "$wt" ] || { printf '⚠️  headless: bad slug/worktree for start-agent (%s / %s)\n' "$slug" "$wt" >&2; return 1; }
  command -v claude >/dev/null 2>&1 || { printf '⚠️  headless: claude not on PATH — cannot start detached agent %s\n' "$slug" >&2; return 1; }
  local adir; adir="$(_herd_agent_dir "$slug")"
  mkdir -p "$adir" 2>/dev/null || { printf '⚠️  headless: cannot create agent registry dir %s\n' "$adir" >&2; return 1; }
  : "${flags:=--dangerously-skip-permissions}"
  # Detached, no controlling terminal, no pane: stdout+stderr → the registry log (the "pane"). The
  # runtime argv is COMPOSED from the resolved driver's DRIVER_AGENT_INTERACTIVE_SPAWN binding (P2).
  local -a rt=(); local t
  while IFS= read -r -d '' t; do rt+=("$t"); done < <(herd_driver_agent_spawn_argv "${rt_driver:-$(herd_driver_name)}" "$model" "$flags" "$pointer")
  # HERD-171: export the custom endpoint into the detached child when set (byte-identical when unset).
  ( cd "$wt" || exit 1
    # shellcheck disable=SC2163  # $_ep is a literal "K=V" pair — `export "K=V"` sets+exports it.
    while IFS= read -r _ep; do [ -n "$_ep" ] && export "$_ep"; done < <(herd_driver_endpoint_env_lines)
    nohup "${rt[@]}" >"$adir/log" 2>&1 </dev/null & echo $! > "$adir/pid" )
  printf 'working\n' > "$adir/status" 2>/dev/null || true
  [ -s "$adir/pid" ]
}
_herd_herdr_start_agent() {
  local slug="$1" wt="$2" model="$3" flags="$4" pointer="$5" split="$6" rt_driver="${7:-}"
  local wsid; wsid="$(herd_resolve_workspace_id 2>/dev/null || true)"
  local created tab root
  # shellcheck disable=SC2086  # ${wsid:+…} deliberately word-splits into two argv when set
  created="$(herdr tab create ${wsid:+--workspace "$wsid"} --cwd "$wt" --label "$slug" --no-focus 2>/dev/null || true)"
  read -r tab root < <(printf '%s' "$created" | python3 -c \
    'import sys,json; d=json.load(sys.stdin)["result"]; print(d["tab"]["tab_id"], d["root_pane"]["pane_id"])' 2>/dev/null || true)
  [ -n "${tab:-}" ] || return 1
  printf '%s %s builder\n' "$slug" "$tab" >> "${WORKTREES_DIR:-.}/.herd-tabs" 2>/dev/null || true
  : "${flags:=--dangerously-skip-permissions}"
  # Compose the agent-runtime argv (the part after `--`) from the resolved driver's P1 binding (P2).
  local -a rt=(); local t
  while IFS= read -r -d '' t; do rt+=("$t"); done < <(herd_driver_agent_spawn_argv "${rt_driver:-$(herd_driver_name)}" "$model" "$flags" "$pointer")
  # HERD-171: inject ANTHROPIC_BASE_URL when set (no-op / byte-identical when unset).
  local -a envkv=(); local _ep
  while IFS= read -r _ep; do [ -n "$_ep" ] && envkv+=("$_ep"); done < <(herd_driver_endpoint_env_lines)
  if _herd_herdr_attach_cli; then
    # herdr ≥0.7.5 (issue #514): the tab root stays an idle shell (the lane's preview/task-spec pane);
    # the agent gets its own split pane — the same layout the old --tab/--split argv produced. An
    # unspecified split direction defaults right, the old own-pane placement.
    if herd_driver_herdr_attach_agent "$slug" "${rt_driver:-}" "$root" "$wt" "${split:-right}" "" \
         ${envkv[@]+"${envkv[@]}"} -- "${rt[@]}" >/dev/null 2>&1; then
      return 0
    fi
  else
    local -a envargs=()
    for _ep in ${envkv[@]+"${envkv[@]}"}; do envargs+=(--env "$_ep"); done
    # shellcheck disable=SC2086  # $wsid intentionally word-splits (mirrors the lane's args)
    # HERD-418: pre-0.7.5 herdr also validates the agent name; sanitizing here too is simpler than
    # branching — a builder slug is already valid so this is a no-op for the common case.
    if herdr agent start "$(herd_agent_name_sanitize "$slug")" ${wsid:+--workspace "$wsid"} --cwd "$wt" --tab "$tab" ${split:+--split "$split"} --no-focus ${envargs[@]+"${envargs[@]}"} -- "${rt[@]}" >/dev/null 2>&1; then
      return 0
    fi
  fi
  # HERD-136: agent start failed after we created the tab — close it so no empty corpse tab lingers,
  # then journal the reap (guarded: not every caller of this helper sources journal.sh).
  herdr tab close "$tab" >/dev/null 2>&1 || true
  command -v journal_append >/dev/null 2>&1 && journal_append infra_event component builder agent "$slug" reason spawn_agent_failed tab "$tab"
  return 1
}

# ── start-agent (generalized) ──────────────────────────────────────────────────────────────────────
# herd_driver_launch_agent key=value … — the GENERALIZED start-agent entry the NON-builder lanes use
# (coordinator, fleet room, resolver, reviewer, researcher, scribe). The positional
# herd_driver_start_agent above is builder-shaped (slug/worktree/model/flags/pointer/split) and cannot
# express the launch shapes these lanes need: a CUSTOM agent name, an ARBITRARY cwd (usually $REPO, not
# a worktree), an EXPLICIT pre-created tab (each lane owns the surrounding panes), a split DIRECTION,
# a FOCUS flag, per-launch ENV vars, and an explicit (possibly EMPTY) flags set for the human seats.
#
# Options are passed as `key=value` positional args (bash-3.2 safe — NO assoc arrays / namerefs, which
# the codebase deliberately avoids for macOS's bash 3.2; see codemap.sh). Split on the FIRST `=` so a
# value may itself contain `=` (prompts do). Recognized keys (all optional unless noted):
#   name       agent name (REQUIRED)
#   cwd        working directory the agent starts in (REQUIRED)
#   pointer    opening prompt / skill command, passed after `-- claude … "<pointer>"`
#   model      model id; empty/omitted → no --model (e.g. the coordinator relaunch)
#   flags      claude flags, word-split; empty/omitted → NONE passed (the human seats). The headless
#              backend ALWAYS forces --dangerously-skip-permissions — a detached agent has no tty and
#              cannot answer a permission prompt.
#   workspace  herdr workspace id; provided-but-empty → omit --workspace (mirrors ${_WS_ID:+…});
#              omitted entirely → resolve via herd_resolve_workspace_id (the builder default)
#   tab        explicit herdr tab id; every routed lane pre-creates its tab. headless ignores it.
#   split      herdr split direction (right|down|''); empty → no --split
#   focus      'yes' → focus the new agent (omit --no-focus); anything else → --no-focus
#   env        one K=V; may be repeated (env=A=1 env=B=2) → each becomes a --env "K=V"
#
# herdr-claude: emits the SAME `herdr agent start … -- claude …` argv the lane hardcoded (byte-identical
# flag order), so its stdout (the JSON) flows to the caller for pane_id parsing and its exit status
# propagates so a fail-loud lane's `|| die` still fires. headless: a DETACHED background `claude`
# (nohup) into the registry, exactly like the builder headless path. Returns the launch exit status.
herd_driver_launch_agent() {
  local sa_name="" sa_cwd="" sa_pointer="" sa_model="" sa_flags="" sa_split="" sa_tab="" sa_focus="" sa_env=""
  local sa_ws="" sa_ws_set=0 sa_driver="" kv key val
  for kv in "$@"; do
    key="${kv%%=*}"; val="${kv#*=}"
    case "$key" in
      name)      sa_name="$val" ;;
      cwd)       sa_cwd="$val" ;;
      pointer)   sa_pointer="$val" ;;
      model)     sa_model="$val" ;;
      flags)     sa_flags="$val" ;;
      split)     sa_split="$val" ;;
      tab)       sa_tab="$val" ;;
      focus)     sa_focus="$val" ;;
      workspace) sa_ws="$val"; sa_ws_set=1 ;;
      driver)    sa_driver="$val" ;;   # HERD-150 P2: caller-resolved runtime driver (lanes pre-resolve to fail-fast)
      env)       sa_env="${sa_env}${sa_env:+$'\n'}$val" ;;
      *)         : ;;  # ignore unknown keys (forward-compat)
    esac
  done
  # HERD-171: auto-append the custom claude endpoint when set. Empty → sa_env unchanged (byte-identical).
  local _ep
  while IFS= read -r _ep; do
    [ -n "$_ep" ] && sa_env="${sa_env}${sa_env:+$'\n'}$_ep"
  done < <(herd_driver_endpoint_env_lines)
  [ -n "$sa_name" ] || { printf '⚠️  driver: launch-agent called with no name\n' >&2; return 1; }
  # Resolve an optionally runtime-qualified model ref (HERD-151) → the runtime DRIVER *and* bare model,
  # once, before either backend builds its argv (HERD-150 P2). Making the resolved driver REAL — not
  # discarded — is the point: it selects which runtime's DRIVER_AGENT_INTERACTIVE_SPAWN binding composes
  # the `-- <runtime …>` argv below.
  #
  # TWO CONTRACTS, resolve EXACTLY ONCE:
  #   • driver=<name> supplied → the caller ALREADY resolved (the builder lanes, which resolve BEFORE
  #     creating a tab so a bad ref fails fast). sa_model is BARE BY CONTRACT — do NOT re-resolve it.
  #     A bare model may LEGITIMATELY carry colons (an ollama-style 'llama3:8b' tag; a role model literally
  #     named 'headless:opus'); re-feeding it to herd_model_for_spawn would mis-split on the first colon —
  #     ABORTING on an unknown driver ('llama3'), or SILENTLY rewriting the model (headless:opus → opus).
  #     herd_model_for_spawn / herd_model_resolve are for an UNRESOLVED ref ONLY.
  #   • no driver= → sa_model is a raw (possibly qualified) ref; resolve it here (the human-seat / drainer
  #     lanes). Loud-fails on an unknown driver prefix; byte-identical for a bare value (incl. the empty
  #     model the human seats / coordinator relaunch pass → no --model).
  if [ -z "$sa_driver" ]; then
    local _res; _res="$(herd_model_resolve "$sa_model")" || return 1
    sa_driver="${_res%%$'\t'*}"; sa_model="${_res#*$'\t'}"
  fi

  if _herd_driver_is_headless; then
    [ -d "$sa_cwd" ] || { printf '⚠️  headless: bad cwd for launch-agent %s (%s)\n' "$sa_name" "$sa_cwd" >&2; return 1; }
    command -v claude >/dev/null 2>&1 || { printf '⚠️  headless: claude not on PATH — cannot start detached agent %s\n' "$sa_name" >&2; return 1; }
    local adir; adir="$(_herd_agent_dir "$sa_name")"
    mkdir -p "$adir" 2>/dev/null || { printf '⚠️  headless: cannot create agent registry dir %s\n' "$adir" >&2; return 1; }
    : "${sa_flags:=--dangerously-skip-permissions}"
    # The detached runtime argv is COMPOSED from the resolved driver's P1 binding (P2), same as the
    # herdr path below — so a runtime-qualified ref launches the right runtime detached too.
    local -a rt=(); local t
    while IFS= read -r -d '' t; do rt+=("$t"); done < <(herd_driver_agent_spawn_argv "$sa_driver" "$sa_model" "$sa_flags" "$sa_pointer")
    # Detached, no tty, no pane: stdout+stderr → the registry log; env vars exported into the child.
    ( cd "$sa_cwd" || exit 1
      # shellcheck disable=SC2163  # $_l is a literal "K=V" pair — `export "K=V"` sets+exports it.
      if [ -n "$sa_env" ]; then while IFS= read -r _l; do [ -n "$_l" ] && export "$_l"; done <<< "$sa_env"; fi
      nohup "${rt[@]}" >"$adir/log" 2>&1 </dev/null & echo $! > "$adir/pid" )
    printf 'working\n' > "$adir/status" 2>/dev/null || true
    [ -s "$adir/pid" ]
    return
  fi

  # herdr-claude: the RUNTIME tail (after `--`) is composed from the RESOLVED runtime driver's
  # DRIVER_AGENT_INTERACTIVE_SPAWN binding (P2); the MUX prefix depends on the installed herdr CLI
  # (issue #514) — the attach CLI on ≥0.7.5, the byte-identical pre-0.7.5 argv otherwise.
  local ws
  if [ "$sa_ws_set" = 1 ]; then ws="$sa_ws"; else ws="$(herd_resolve_workspace_id 2>/dev/null || true)"; fi
  local -a rt=(); local _t
  while IFS= read -r -d '' _t; do rt+=("$_t"); done < <(herd_driver_agent_spawn_argv "$sa_driver" "$sa_model" "$sa_flags" "$sa_pointer")
  if _herd_herdr_attach_cli; then
    local -a envkv=(); local _l
    if [ -n "$sa_env" ]; then while IFS= read -r _l; do [ -n "$_l" ] && envkv+=("$_l"); done <<< "$sa_env"; fi
    local base="" atsplit="$sa_split"
    if [ -n "$sa_tab" ]; then
      # A pre-created tab: the agent gets its OWN pane split off the tab's root — the old
      # `agent start --tab` shape, whose root stayed an idle shell some lanes reuse (the quick
      # lane's task-spec viewer). No caller split direction → right, the old own-pane placement.
      base="$(_herd_herdr_tab_root_pane "$sa_tab")"
      [ -n "$base" ] || { printf '⚠️  driver: launch-agent found no pane in tab %s for %s\n' "$sa_tab" "$sa_name" >&2; return 1; }
      [ -n "$atsplit" ] || atsplit=right
    else
      # No tab given (the old CLI let `agent start` create everything): create one and attach
      # straight to its root — env pairs ride `tab create --env`, the pane-creating command.
      local -a tc=(herdr tab create)
      [ -n "$ws" ] && tc+=(--workspace "$ws")
      tc+=(--cwd "$sa_cwd" --label "$sa_name")
      local _kv
      for _kv in ${envkv[@]+"${envkv[@]}"}; do tc+=(--env "$_kv"); done
      if [ "$sa_focus" = "yes" ]; then tc+=(--focus); else tc+=(--no-focus); fi
      base="$("${tc[@]}" 2>/dev/null | python3 -c '
import sys, json
try:
  print((json.load(sys.stdin)["result"]["root_pane"]["pane_id"]) or "", end="")
except Exception:
  pass
' 2>/dev/null || true)"
      [ -n "$base" ] || { printf '⚠️  driver: launch-agent could not create a tab for %s\n' "$sa_name" >&2; return 1; }
      atsplit=""; envkv=()   # env + focus already applied at tab create; attach to the fresh root
    fi
    herd_driver_herdr_attach_agent "$sa_name" "$sa_driver" "$base" "$sa_cwd" "$atsplit" "$sa_focus" \
      ${envkv[@]+"${envkv[@]}"} -- "${rt[@]}"
    return
  fi
  # pre-0.7.5 herdr: build the exact argv the lane hardcoded (indexed array — bash-3.2 safe).
  # HERD-418: sanitize the REGISTERED name; a bare-CLI herdr validates it exactly like the attach CLI.
  local -a argv
  argv=(herdr agent start "$(herd_agent_name_sanitize "$sa_name")")
  [ -n "$ws" ] && argv+=(--workspace "$ws")
  argv+=(--cwd "$sa_cwd")
  [ -n "$sa_tab" ] && argv+=(--tab "$sa_tab")
  [ -n "$sa_split" ] && argv+=(--split "$sa_split")
  [ "$sa_focus" != "yes" ] && argv+=(--no-focus)
  if [ -n "$sa_env" ]; then while IFS= read -r _l; do [ -n "$_l" ] && argv+=(--env "$_l"); done <<< "$sa_env"; fi
  argv+=(-- "${rt[@]}")
  "${argv[@]}"
}

# ── one-shot exec (HERD-175 — HERD-150 P3 drainers) ───────────────────────────────────────────────
# herd_driver_oneshot_exec <prompt> <model> [runtime-arg …] — run a HEADLESS ONE-SHOT agent query with
# NO pane: the DRIVER_AGENT_ONESHOT_EXEC capability (docs/driver-abstraction.md § agent-runtime
# portability, class 2). This is the ONE seam the drainer-family one-shot `claude -p` call sites route
# through — the mid-flight advisor (herd-advise.sh) and the pre-merge reviewer's headless `-p` passes
# (herd-review.sh: the local panel, local single, and headless-PR paths) — so a non-Claude runtime
# rebinds the incantation in ONE place instead of at every drainer site.
#
# Every arg AFTER <model> is forwarded VERBATIM (the caller's word-split $CLAUDE_FLAGS, plus the
# reviewer's --output-format stream-json --verbose), so the composed argv is BYTE-IDENTICAL to the
# inlined `claude -p "$prompt" --model "$model" $flags …` each site had before — the drift guard in
# tests/test-driver-agent-exec.sh + the compose proof in tests/test-oneshot-exec-seam.sh are the rail.
#
# NO driver branch: a one-shot query is pane-INDEPENDENT, so herdr-claude and headless run the
# IDENTICAL command (both .driver files bind DRIVER_AGENT_ONESHOT_EXEC to the same string — the exec
# surface is a property of the RUNTIME, not the mux). NOT fail-soft (a deliberate exception, like the
# model resolver): it returns the runtime's exit status UNCHANGED so each caller keeps its OWN
# degrade/verdict handling — advise degrades to 'unavailable' on non-zero/empty, review treats a
# non-zero-without-verdict as INFRA-FAIL; wrapping the status here would corrupt both.
herd_driver_oneshot_exec() {
  local prompt="${1:-}" model="${2:-}"
  shift 2 2>/dev/null || set --
  herd_driver_oneshot_exec_as "" "$prompt" "$model" "$@"
}

# herd_driver_oneshot_exec_as <driver> <prompt> <model> [runtime-arg …] — the SAME one-shot capability,
# aimed at an EXPLICIT driver instead of the active one. Empty <driver> ⇒ the active driver, so
# herd_driver_oneshot_exec above delegates here and every pre-HERD-276 call site composes a
# BYTE-IDENTICAL argv (the compose proof in tests/test-oneshot-exec-seam.sh is the rail).
#
# WHY (HERD-276): the mixed-vendor review panel dispatches each panelist through its OWN
# runtime-qualified MODEL ref, so two panelists in the same fan-out run different vendors' binaries in
# the same process tree. The active-driver lookup inside the old body made that unrepresentable — the
# driver half of a resolved ref was discarded. Threading <driver> through keeps ONE composition site
# (the DRIVER_AGENT_ONESHOT_EXEC binding remains the only place the incantation lives) while letting
# a caller name the vendor. Callers pass the driver resolved by herd_model_driver_for.
#
# Same NOT-fail-soft contract as its delegate: the runtime's exit status is returned UNCHANGED so each
# caller keeps its own degrade path. A runtime binary that does not EXIST is the caller's problem to
# probe (herd_driver_agent_runtime + `command -v`) — the review panel does exactly that, so a missing
# vendor binary reports INFRA rather than a shell "command not found" masquerading as a failed review.
herd_driver_oneshot_exec_as() {
  local drv="${1:-}" prompt="${2:-}" model="${3:-}"
  shift 3 2>/dev/null || set --
  # HERD-177 P6: run the RESOLVED driver's runtime, not a hardwired `claude`. herd_driver_agent_runtime
  # resolves the runtime executable from the driver's DRIVER_AGENT_ONESHOT_EXEC binding; a non-Claude
  # driver (stub/codex/grok) runs its own binary through the SAME arg composition. The default path is
  # the drift-guarded, BYTE-IDENTICAL `claude -p …` literal — taken whenever the runtime is claude OR
  # unresolvable (an absent binding degrades to today's behavior, never a crash). The compose proof +
  # the audit drift guard (tests/test-oneshot-exec-seam.sh, tests/test-driver-agent-exec.sh) are the rail.
  local _rt; _rt="$(herd_driver_agent_runtime "$drv" 2>/dev/null || true)"
  if [ -n "$_rt" ] && [ "$_rt" != "claude" ]; then
    "$_rt" -p "$prompt" --model "$model" "$@"
  else
    claude -p "$prompt" --model "$model" "$@"
  fi
}

# ── watcher wake surface (HERD-176 — HERD-150 P4: resume / limit / model-switch) ──────────────────
# The watcher's load-bearing wake paths used to hardcode claude-shaped incantations:
#   • resume:        `claude <flags> --continue "<prompt>"` in the builder/coordinator pane
#   • limit-banner:  `usage limit|session limit|hit your (usage|session) limit` phrase match
#   • model-switch:  `/model <model>` typed into a live session via send-text
#   • refix-wake:    already delivered via herd_driver_send_text (mux DRIVER_SEND_TEXT) for review;
#                    health/stale rails follow the same seam
# HERD-176 routes each through the P1 DRIVER_AGENT_* / DRIVER_SEND_TEXT bindings so a non-Claude
# runtime (grok/codex/stub) resumes, limit-detects, and switches model correctly. BYTE-IDENTICAL for
# herdr-claude / headless: the resume/limit/model-switch bindings carry today's exact strings, so the
# composed argv and the banner phrase match pre-P4 hardcodes (tests/test-watcher-driver-wake.sh).

# herd_driver_agent_resume_cmd <prompt> [flags] [driver] — compose the RESUME shell command from
# <driver>'s DRIVER_AGENT_RESUME template (default: active driver). Substitutes:
#   <prompt>                   → <prompt> (one token; shell-quoted on emit)
#   the permission-flag token  → <flags>, whitespace-split (empty <flags> → driver's own flag /
#                                HERD_CLAUDE_FLAGS via herd_driver_lane_permission_flags)
#   anything else              → kept literally (runtime binary + --continue / resume / …)
# FAIL-SOFT: an unreadable/absent binding falls back to today's exact claude resume shape so a
# misconfigured driver never emits an empty command. Echoes a single shell-safe command line the
# watcher wraps as `cd <wt> && <cmd>` and delivers via `herdr pane run` (a shell relaunch into an
# ENDED session — not send-text, which would also Enter-submit into a still-present TUI).
herd_driver_agent_resume_cmd() {
  local prompt="${1:-continue}" flags="${2-}" drv="${3:-}" binding perm
  [ -n "$drv" ] || drv="$(herd_driver_name)"
  binding="$(herd_driver_agent_value DRIVER_AGENT_RESUME "" "$drv")"
  perm="$(herd_driver_agent_value DRIVER_AGENT_PERMISSION_FLAG "" "$drv")"
  [ -n "$binding" ] || binding='claude --dangerously-skip-permissions --continue "<prompt>"'
  [ -n "$perm" ]    || perm='--dangerously-skip-permissions'
  # Empty/unset flags → the lane permission resolver (HERD_CLAUDE_FLAGS override, else driver's flag).
  # Use ${2-} (not ${2:-}) so an explicit empty second arg still means "derive"; only a non-empty
  # second arg pins the flags. Callers that want derived flags pass nothing or "".
  if [ -z "${flags}" ]; then
    flags="$(herd_driver_lane_permission_flags "$drv")"
  fi
  HERD_RESUME_BINDING="$binding" HERD_RESUME_PERM="$perm" \
  HERD_RESUME_FLAGS="$flags" HERD_RESUME_PROMPT="$prompt" python3 -c '
import os, shlex, sys
binding = os.environ["HERD_RESUME_BINDING"]
perm    = os.environ["HERD_RESUME_PERM"]
flags   = os.environ["HERD_RESUME_FLAGS"].split()
prompt  = os.environ["HERD_RESUME_PROMPT"]
try:
    toks = shlex.split(binding)
    out = []
    for t in toks:
        if t == "<prompt>":
            out.append(prompt)
        elif t == perm:
            out.extend(flags)
        else:
            out.append(t)
except Exception:
    out = ["claude"] + flags + ["--continue", prompt]
sys.stdout.write(" ".join(shlex.quote(t) for t in out))
'
}

# herd_driver_agent_limit_pattern [driver] — the usage-limit BANNER PHRASE regex from
# DRIVER_AGENT_LIMIT_PATTERN (primary phrase half of _text_is_limit_banner). FAIL-SOFT: echoes the
# herdr-claude default when the binding is unreadable so detection never goes silent under set -e.
# A `@degrade:…` sentinel (codex/grok) is returned as-is; the caller treats it as never-match.
herd_driver_agent_limit_pattern() {
  local drv="${1:-}"
  [ -n "$drv" ] || drv="$(herd_driver_name)"
  herd_driver_agent_value DRIVER_AGENT_LIMIT_PATTERN \
    'usage limit|session limit|hit your (usage|session) limit' "$drv"
}

# herd_driver_switch_model <pane-or-slug> <model> [driver] — mid-session model switch: compose the
# DRIVER_AGENT_MODEL_SWITCH template (`/model <model>` for every shipped driver today) and deliver it
# via the mux DRIVER_SEND_TEXT seam (herd_driver_send_text → pane run + Enter for herdr; queue-append
# for headless). FAIL-SOFT: empty target/model or a missing binding is a clean no-op — never aborts.
herd_driver_switch_model() {
  local target="${1:-}" model="${2:-}" drv="${3:-}" binding text
  [ -n "$target" ] && [ -n "$model" ] || return 0
  [ -n "$drv" ] || drv="$(herd_driver_name)"
  binding="$(herd_driver_agent_value DRIVER_AGENT_MODEL_SWITCH '/model <model>' "$drv")"
  [ -n "$binding" ] || binding='/model <model>'
  text="${binding//<model>/$model}"
  herd_driver_send_text "$target" "$text"
  return 0
}

# ── CLI entrypoint ───────────────────────────────────────────────────────────────────────────────
# Only runs when EXECUTED (not sourced): `bash driver.sh <cap> …`. Sources herd-config.sh for
# WORKTREES_DIR, then dispatches to the capability. This is what the rendered headless coordinator
# skill calls (list-agents / read-pane / send-text / focus / …).
_herd_driver_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    list-agents) herd_driver_agent_list_json ;;
    read-pane)   herd_driver_read_pane "$@" ;;
    send-text)   herd_driver_send_text "$@" ;;
    send-keys)   herd_driver_send_keys "$@" ;;
    close-pane)  herd_driver_close_pane "$@" ;;
    close-verified) herd_close_pane_verified "$@" ;;
    pane-identity)  herd_driver_pane_identity "$@"; echo ;;
    pane-rename)    herd_driver_pane_rename "$@" ;;
    report-agent)   herd_driver_report_agent "$@" ;;   # HERD-178: session-identity register for a non-native runtime
    agent-pane)     herd_driver_agent_pane_id "$@"; echo ;;
    pane-alive)  herd_driver_pane_alive "$@" ;;
    agent-liveness) herd_driver_agent_liveness "$@"; echo ;;
    create-tab)  herd_driver_create_tab "$@" ;;
    oneshot-exec) herd_driver_oneshot_exec "$@" ;;   # <prompt> <model> [runtime-arg …] → <runtime> -p …
    agent-runtime) herd_driver_agent_runtime; echo ;;       # the active driver's runtime executable
    resume-cmd)  herd_driver_agent_resume_cmd "$@"; echo ;;  # <prompt> [flags] [driver] → shell-safe resume cmd
    limit-pattern) herd_driver_agent_limit_pattern "$@"; echo ;;  # [driver] → DRIVER_AGENT_LIMIT_PATTERN
    switch-model) herd_driver_switch_model "$@" ;;   # <pane> <model> [driver]
    focus)       herd_driver_focus_agent "$@" ;;
    notify)      herd_driver_notify "$@" ;;
    name)        herd_driver_name; echo ;;
    agent-value) herd_driver_agent_value "$@"; echo ;;   # <KEY> [default] → the active driver's DRIVER_AGENT_* value
    resolve-model)   herd_model_resolve "$@"   || return 1; echo ;;   # "<driver>\t<model>" (loud-fails on unknown driver)
    model-for-spawn) herd_model_for_spawn "$@" || return 1; echo ;;   # just the bare model to pass to --model
    *) printf 'usage: driver.sh {list-agents|read-pane <slug>|send-text <slug> <text>|send-keys <slug> <keys…>|close-pane <pane>|close-verified <pane> <expected-kind>|pane-identity <pane>|pane-rename <pane> <label>|report-agent <slug> <pane> [state]|agent-pane <slug>|pane-alive <pane>|agent-liveness <slug> [pane]|create-tab <slug>|oneshot-exec <prompt> <model> [arg…]|resume-cmd <prompt> [flags] [driver]|limit-pattern [driver]|switch-model <pane> <model>|agent-runtime|focus <slug>|notify <title> <body> [sound]|name|agent-value <KEY> [default]|resolve-model <ref>|model-for-spawn <ref>}\n' >&2; return 2 ;;
  esac
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _HERD_DRIVER_HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  # shellcheck source=/dev/null
  . "$_HERD_DRIVER_HERE/herd-config.sh"
  _herd_driver_cli "$@"
fi
