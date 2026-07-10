#!/usr/bin/env bash
# herd-preflight.sh — a sourceable guard that fails FAST (with an actionable message) when the
# `herdr` CLI every lane depends on is missing or its contract has skewed.
#
# Why this exists: every lane shells out to herdr (tab create, agent start, pane split, tab list)
# and parses fixed JSON (`result.tabs`, `result.tab.tab_id`, `result.root_pane.pane_id`, …). With
# no upfront guard, a missing or version-skewed herdr blows up CRYPTICALLY deep inside the first
# `herdr tab create` — empty ids, "command not found", or a KeyError in the python parse. This
# turns that into one clear error at the entry point.
#
# Usage (after HERE + herd-config.sh are loaded, near the top of an entry-point script):
#   . "$HERE/herd-preflight.sh"
#   herd_preflight || exit 1        # fatal on fail; silent + 0 when herdr is healthy
#
# Sourcing this file is side-effect-free (it only DEFINES the function). The function is written
# to be safe under the caller's `set -euo pipefail` (expected non-zero is handled, never fatal-by-
# surprise) and to return non-zero only on a genuine missing/skew condition.
#
# Knobs:
#   HERD_SKIP_PREFLIGHT=1   bypass the guard entirely (tests / CI / known-good environments).
#   HERDR_MIN_VERSION=X.Y   OPT-IN floor on `herdr --version`; empty (default) = shape-probe only.
#                           Prefer the shape probe — version strings are brittle; this is a backstop.

# _herd_brand — the display brand shown in user-facing doctor/preflight diagnostics. A consumer who
# has branded their own workflow sees THEIR name instead of the literal "herdkit"; it defaults
# through the current herdkit values so this repo's own output is byte-unchanged (external-consumer
# audit, Leak A / ranked follow-up #7). Prefer the EXISTING config identity WORKSPACE_NAME (set in
# .herd/config, sourced before this file); HERD_BRAND is an explicit override for when the display
# brand and the workspace name should differ. HERD_BRAND is a declared config key
# (templates/capabilities.tsv); this inline default keeps herdkit's own output byte-unchanged.
_herd_brand() { printf '%s' "${HERD_BRAND:-${WORKSPACE_NAME:-herdkit}}"; }

# Engine version handshake (HERD-179). Sourced here — not assumed present — because herd_preflight is
# the lane-spawn write gate and coordinator.sh/new-feature.sh source THIS file directly, without going
# through bin/herd. Defines functions only; a missing module leaves the guard call below undefined, so
# the `command -v` check keeps a partial install fail-open rather than fatal.
_HERD_PREFLIGHT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
# shellcheck source=/dev/null
command -v herd_engine_guard >/dev/null 2>&1 || . "$_HERD_PREFLIGHT_DIR/engine-version.sh" 2>/dev/null || true

herd_preflight() {
  [ "${HERD_SKIP_PREFLIGHT:-}" = "1" ] && return 0
  # ENGINE VERSION HANDSHAKE (HERD-179), before every other probe: a lane spawn is a WRITE (worktree,
  # branch, tab, agent, claim), and an engine below the project's committed ENGINE_MIN must not make
  # it. Refuses with `run herd update`; inert when the project pins no floor. Placed AFTER the
  # HERD_SKIP_PREFLIGHT bypass (that knob is documented as "skip this whole guard") and BEFORE the
  # headless early-return, since a headless lane writes exactly as much as a herdr one.
  if command -v herd_engine_guard >/dev/null 2>&1; then
    herd_engine_guard "lane spawn preflight" || return 1
  fi
  # The headless driver has NO herdr dependency (agents run detached; panes are a view). Every check
  # below probes the herdr CLI/JSON contract, so under HERD_DRIVER=headless the whole preflight is
  # inapplicable — return clean rather than falsely failing the lane for a missing multiplexer.
  [ "${HERD_DRIVER:-herdr-claude}" = "headless" ] && return 0
  local brand; brand="$(_herd_brand)"

  # (a) herdr must be on PATH at all.
  if ! command -v herdr >/dev/null 2>&1; then
    {
      echo "herdr not found on PATH."
      echo "  herdr is the terminal/agent multiplexer that $brand lanes drive (tab create,"
      echo "  agent start, pane split, tab list). It is a REQUIRED dependency — without it no"
      echo "  lane can launch a tab or sub-agent."
      echo "  Fix: install herdr and ensure it is on your PATH, then retry."
      echo "  (to bypass this check in tests/CI: HERD_SKIP_PREFLIGHT=1)"
    } >&2
    return 1
  fi

  # (b) Probe the CLI/JSON contract with a read-only, side-effect-free call. Factored into
  #     _herd_herdr_contract_probe (below) so `herd_doctor` can reuse the exact same check and
  #     messages. On skew/failure it writes the actionable diagnostic to stderr and returns 1.
  _herd_herdr_contract_probe || return 1

  # (c) OPT-IN version floor (only when HERDR_MIN_VERSION is set). The shape probe above is the
  #     primary guard; this is a coarse backstop for environments that want to pin a minimum.
  if [ -n "${HERDR_MIN_VERSION:-}" ]; then
    local raw found verdict
    raw="$(herdr --version 2>/dev/null || true)"
    found="$(printf '%s' "$raw" | grep -oE '[0-9]+(\.[0-9]+){0,3}' | head -1)"  # pipe-ok: head in a command or process substitution; pipeline status not gated
    verdict="$(MIN="$HERDR_MIN_VERSION" GOT="$found" python3 -c '
import os
def parse(s):
    return [int(p) for p in s.split(".")] if s and all(p.isdigit() for p in s.split(".")) else []
g, m = parse(os.environ["GOT"]), parse(os.environ["MIN"])
if not g:
    print("bad"); raise SystemExit
n = max(len(g), len(m)); g += [0]*(n-len(g)); m += [0]*(n-len(m))
print("ok" if g >= m else "bad")
' 2>/dev/null)"
    if [ "$verdict" != "ok" ]; then
      {
        echo "herdr version check failed."
        echo "  expected: herdr >= ${HERDR_MIN_VERSION} (HERDR_MIN_VERSION pin)"
        echo "  found:    ${found:-unknown} (from \`herdr --version\`)"
        echo "  Fix: upgrade herdr, or adjust/clear HERDR_MIN_VERSION.   (bypass: HERD_SKIP_PREFLIGHT=1)"
      } >&2
      return 1
    fi
  fi

  return 0
}

# ─────────────────────────────────────────────────────────────────────────────
# _herd_herdr_contract_probe — assumes `herdr` is already on PATH. Runs the read-only
# `herdr tab list` and validates the JSON shape every lane parses (top-level result.tabs ARRAY).
# On any failure writes an actionable diagnostic to stderr and returns 1; silent + 0 on success.
# Shared by herd_preflight (fatal guard) and herd_doctor (one-pass report).
_herd_herdr_contract_probe() {
  local out diag brand; brand="$(_herd_brand)"
  if ! out="$(herdr tab list 2>/dev/null)"; then
    {
      echo "herdr CLI contract check failed."
      echo "  expected: a read-only \`herdr tab list\` to succeed and emit JSON"
      echo "  found:    \`herdr tab list\` exited non-zero"
      echo "  Your herdr looks broken or incompatible with the shape $brand's lanes parse."
      echo "  Fix: upgrade/repair herdr, then retry.   (bypass: HERD_SKIP_PREFLIGHT=1)"
    } >&2
    return 1
  fi
  # python3 here always exits 0 and reports OK / BAD:<reason> on stdout, so this stays safe under
  # the caller's `set -e` (a non-zero python exit in an assignment would otherwise abort).
  diag="$(printf '%s' "$out" | python3 -c '
import sys, json
def bad(m):
    print("BAD:" + m); sys.exit(0)
try:
    d = json.load(sys.stdin)
except Exception as e:
    bad("response was not valid JSON (%s)" % e)
if not isinstance(d, dict) or "result" not in d:
    bad("no top-level \"result\" key")
r = d["result"]
if not isinstance(r, dict) or "tabs" not in r:
    bad("no \"result.tabs\" key")
if not isinstance(r["tabs"], list):
    bad("\"result.tabs\" is not a JSON array")
print("OK")
' 2>/dev/null)"
  case "$diag" in
    OK*) return 0 ;;
    *)
      {
        echo "herdr CLI contract check failed (JSON shape skew)."
        echo "  expected: \`herdr tab list\` JSON with a top-level result.tabs array"
        echo "            (the envelope lanes parse: result.tabs / result.tab.tab_id / result.root_pane.pane_id)"
        echo "  found:    ${diag#BAD:}"
        echo "  Your herdr's output shape has skewed from what $brand's lanes expect."
        echo "  Fix: upgrade herdr to a compatible version, then retry.   (bypass: HERD_SKIP_PREFLIGHT=1)"
      } >&2
      return 1
      ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# herd_doctor — the COMPREHENSIVE dependency doctor. Unlike herd_preflight (a fast, herdr-only,
# fail-on-first guard for the lane hot-path), the doctor checks EVERY dependency in ONE pass and
# reports them all at once, so a broken environment surfaces its full picture rather than
# one-error-at-a-time. Run it at install time (advisory) and at the top of `herd init` (gate, before
# any config is written), and expose it as `herd doctor` for on-demand self-diagnosis.
#
# Dependencies are TIERED by what the invoked command actually needs (external-consumer audit,
# Leak A / ranked follow-up #1). `herd init` only writes config — it does not launch a pane, spawn
# an agent, or render an emoji label — so it must gate on the truly-required minimum and degrade the
# rest to warnings, otherwise a Go/Rust/Java consumer who never installed herdkit's own runtime is
# blocked at the very first step.
#
#   REQUIRED (hard — `herd init` cannot proceed without them, and their absence is the exit-1
#     condition callers gate on): git, gh (+ `gh auth status`).
#
#   RECOMMENDED (warn — needed to actually RUN the workflow, but checked LAZILY at point-of-use, so
#     a missing one only warns here and never blocks init): herdr (+ its JSON contract) to launch the
#     control room & drive panes (guarded by herd_preflight when a lane runs); claude to spawn a
#     Claude Code agent in a lane; python3 for the JSON/UTF-8 pane helpers. python3's UTF-8 capability
#     rides in this tier — on Windows it defaults to the cp1252 codepage and dies with
#     UnicodeEncodeError on the emoji/box-drawing pane labels herd scripts print through `python3 -c`
#     (issue #31); herdkit exports PYTHONUTF8=1 in herd-config.sh to fix this, and the doctor confirms
#     the fix takes — but a repo that never renders a herd pane is not blocked from init over it.
#
#   OPTIONAL (soft — a missing one only degrades ONE feature, never blocks): glow (backlog-view
#     pretty-print), shellcheck + bats (healthcheck lint/tests).
#
# Returns 0 when every REQUIRED dep is present and healthy (even if RECOMMENDED/OPTIONAL ones are
# missing — those only warn); non-zero only when a REQUIRED dep is missing/broken. Always prints the
# FULL one-pass per-dependency ✓/⚠/✗ report with per-platform install hints, so `herd doctor` still
# surfaces everything regardless of exit status. Human-facing output only — no machine parses it, so
# the non-ASCII marks are safe here (unlike the JSON-parse paths).
#
# Knobs:
#   HERD_SKIP_DOCTOR=1   bypass the doctor entirely (tests / CI / known-good environments).
#   HERD_DOCTOR_OS=...   override platform detection for install hints (test seam): darwin|linux|
#                        windows|other.

# _herd_doctor_os — the platform key that selects install hints. HERD_DOCTOR_OS overrides (tests).
_herd_doctor_os() {
  if [ -n "${HERD_DOCTOR_OS:-}" ]; then printf '%s' "$HERD_DOCTOR_OS"; return 0; fi
  case "$(uname -s 2>/dev/null || true)" in
    Darwin)                          printf 'darwin' ;;
    Linux)                           printf 'linux' ;;
    MINGW*|MSYS*|CYGWIN*|Windows_NT) printf 'windows' ;;
    *)                               printf 'other' ;;
  esac
}

# _herd_doctor_hint <tool> <os> — a one-line, copy-pasteable install hint for a missing dep (used by
# both the REQUIRED and RECOMMENDED tiers).
_herd_doctor_hint() {
  local tool="$1" os="$2" brand; brand="$(_herd_brand)"
  case "$tool" in
    git)
      case "$os" in
        darwin)  printf 'xcode-select --install   (or: brew install git)' ;;
        linux)   printf 'apt install git   /   dnf install git   /   pacman -S git' ;;
        windows) printf 'winget install Git.Git   (or https://git-scm.com/download/win)' ;;
        *)       printf 'install git — https://git-scm.com' ;;
      esac ;;
    gh)
      case "$os" in
        darwin)  printf 'brew install gh   then: gh auth login' ;;
        linux)   printf 'see https://github.com/cli/cli#installation   then: gh auth login' ;;
        windows) printf 'winget install GitHub.cli   then: gh auth login' ;;
        *)       printf 'install gh — https://cli.github.com   then: gh auth login' ;;
      esac ;;
    claude)
      printf 'npm install -g @anthropic-ai/claude-code   (or see https://docs.claude.com/claude-code)' ;;
    python3)
      case "$os" in
        darwin)  printf 'brew install python3   (or: xcode-select --install)' ;;
        linux)   printf 'apt install python3   /   dnf install python3' ;;
        windows) printf 'winget install Python.Python.3   (ensure the python3/py launcher is on PATH)' ;;
        *)       printf 'install Python 3.7+ — https://python.org' ;;
      esac ;;
    herdr)
      case "$os" in
        windows) printf 'run %s under WSL2 (the supported Windows path) and install the herdr CLI there — see docs/windows.md; native Git Bash is best-effort only' "$brand" ;;
        *)       printf 'install the herdr CLI (the terminal/agent multiplexer %s drives) and ensure it is on PATH' "$brand" ;;
      esac ;;
    *)
      printf 'install %s and ensure it is on PATH' "$tool" ;;
  esac
}

# _herd_doctor_python_utf8 [python-bin] — classify python3's UTF-8 capability. Echoes one of:
#   "OK <enc>"      python3 already emits UTF-8 to a pipe (nothing to fix)
#   "FIXED <enc>"   default encoding <enc> can't emit UTF-8, but PYTHONUTF8=1 fixes it (the engine
#                   exports it in herd-config.sh, so this is healthy — reported, not failed)
#   "BROKEN <enc>"  cannot emit UTF-8 even with PYTHONUTF8=1 (ancient python) — a genuine HARD fail
# The probe prints 🐑 (U+1F411, the exact pane-label emoji from issue #31) with stdout redirected to
# a non-tty, so the locale codepage — not a tty — governs, matching how the engine pipes python3.
_herd_doctor_python_utf8() {
  local py="${1:-python3}" enc
  enc="$("$py" -c 'import sys; print(sys.stdout.encoding or "unknown")' 2>/dev/null || printf 'unknown')"
  if "$py" -c 'print("\U0001F411")' >/dev/null 2>&1; then
    printf 'OK %s' "$enc"; return 0
  fi
  if PYTHONUTF8=1 "$py" -c 'print("\U0001F411")' >/dev/null 2>&1; then
    printf 'FIXED %s' "$enc"; return 0
  fi
  printf 'BROKEN %s' "$enc"
}

# _herd_doctor_soft <tool> <degradation-note> — report an OPTIONAL dep: ✓ when present, a ⚠ warning
# with the explicit fallback behavior when absent. Never affects the doctor's exit status.
_herd_doctor_soft() {
  local tool="$1" note="$2"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %s\n' "$tool"
  else
    printf '  \xe2\x9a\xa0 %s not found \xe2\x80\x94 %s\n' "$tool" "$note"
  fi
}

# _herd_soft_dep_startup_notice — OPT-IN proactive soft-dep reminder shown once on control-room
# startup (herd reload / coordinator launch). Gated behind the DOCTOR_STARTUP_HINT config key
# (HERD-45): default/unset "off" prints NOTHING, so every startup path is byte-identical unless the
# operator turns it on. When "on", print one DIM line per MISSING soft dep — each naming the single
# feature it degrades — then a dim pointer to `herd doctor` for the install command. Never red, never
# blocks (soft deps only degrade; the no-false-red rule). Mirrors the soft-dep set + degradation
# notes the doctor itself reports (_herd_doctor_soft above). Callers source herd-config.sh first, so
# the config value is already in the environment; any value other than "on" is treated as off. Always
# returns 0 — a startup reminder must never fail the launch it rides on.
_herd_soft_dep_startup_notice() {
  [ "${DOCTOR_STARTUP_HINT:-off}" = "on" ] || return 0
  local found=0 tool note
  # tool|degradation-note — one named feature each, mirroring _herd_doctor_soft's notes below.
  while IFS='|' read -r tool note; do
    [ -n "$tool" ] || continue
    command -v "$tool" >/dev/null 2>&1 && continue
    printf '\033[2m\xe2\x9a\xa0 %s not found \xe2\x80\x94 %s\033[0m\n' "$tool" "$note"
    found=1
  done <<'SOFTDEPS'
glow|backlog pane renders raw markdown instead of the pretty view
shellcheck|healthcheck skips shell lint
bats|healthcheck runs the *.sh test suite directly instead of via bats
SOFTDEPS
  [ "$found" -eq 1 ] && printf '\033[2m  run herd doctor for the install command\033[0m\n'
  return 0
}

# _herd_control_room_down_reason [panes-registry] — the DETERMINISTIC, no-LLM control-room health
# probe behind the HERD-112 startup-restore hint. Echoes a ONE-LINE human reason when the control
# room looks DOWN/degraded, and NOTHING (empty) when it looks healthy. It signals two conditions:
#
#   (a) watcher not alive / lockfile stale — the SAME liveness signal `herd status` and
#       _list_project_watchers use: the watcher is alive iff $HERD_WATCHER_LOCK holds a pid that
#       `kill -0` accepts. A missing lock, an empty/garbage pid, or a pid that no longer exists = down.
#   (b) backlog or watch pane missing — the role registry ($WORKTREES_DIR/.herd-panes, rewritten from
#       the OBSERVED panes by coordinator.sh / `herd reload`) has no `backlog ` / `watch ` row, so the
#       rebuild failed to establish that pane (e.g. a pane run that fell back headless).
#
# FAIL-SOFT + DEFAULT-SAFE (the no-false-red rule): the pane checks run ONLY when the registry file
# exists (its absence — a fresh room, a headless driver, a suppressed watch console — is NOT a down
# signal); any probe error degrades to "not down"; and it ALWAYS returns 0, so a startup summary can
# call it inline under `set -euo pipefail` with no risk of aborting the launch it rides on. The
# caller decides WHEN to probe (e.g. skip it under HERD_NO_WATCH, where no watcher is expected).
_herd_control_room_down_reason() {
  local reg="${1:-${WORKTREES_DIR:-}/.herd-panes}"

  # (a) Watcher liveness — mirror `herd status`: lockfile pid + kill -0.
  local lock="${HERD_WATCHER_LOCK:-}" wpid=""
  [ -n "$lock" ] && [ -f "$lock" ] && wpid="$(cat "$lock" 2>/dev/null || true)"
  if [ -z "$wpid" ] || ! kill -0 "$wpid" 2>/dev/null; then
    if [ -n "$wpid" ]; then
      printf 'watcher not alive (stale lock pid %s)' "$wpid"
    else
      printf 'watcher not alive (no watcher lock/pid)'
    fi
    return 0
  fi

  # (b) Pane roles — only when the OBSERVED registry exists (else no signal, never a false-red).
  if [ -n "$reg" ] && [ -f "$reg" ]; then
    grep -q '^backlog ' "$reg" 2>/dev/null || { printf 'backlog pane missing from the control room'; return 0; }
    grep -q '^watch '   "$reg" 2>/dev/null || { printf 'watch pane missing from the control room';   return 0; }
  fi

  # Healthy (or not enough signal to call it down) → say nothing.
  return 0
}

# _herd_doctor_recommend <tool> <os> <needed-for> — report a RECOMMENDED dep: ✓ (return 0) when
# present, else a ⚠ warning naming what the tool is needed FOR plus a per-platform install hint, and
# return 1 so the caller can bump its warn count (and skip any follow-on probe, e.g. herdr's JSON
# contract). Deliberately never sets hard_fail — a missing RECOMMENDED dep is checked again lazily at
# point-of-use (herd_preflight guards herdr for the lanes), so it must not block `herd init`.
_herd_doctor_recommend() {
  local tool="$1" os="$2" need="$3"
  if command -v "$tool" >/dev/null 2>&1; then
    printf '  \xe2\x9c\x93 %s\n' "$tool"
    return 0
  fi
  printf '  \xe2\x9a\xa0 %s not found \xe2\x80\x94 needed to %s (checked again at point-of-use)\n' "$tool" "$need"
  printf '      fix: %s\n' "$(_herd_doctor_hint "$tool" "$os")"
  return 1
}

# _herd_doctor_run_timeout <secs> <cmd> [args...] — run <cmd> under a HARD wall-clock timeout,
# portable across macOS/Linux. Prefers coreutils `timeout` (GNU/Linux) or `gtimeout` (macOS +
# coreutils); otherwise falls back to a pure-shell watchdog: background the command, poll up to
# <secs>, then SIGTERM→SIGKILL. stdout/stderr are suppressed. Returns 124 on timeout (matching
# coreutils' convention), else the command's own exit code. Every kill/wait/sleep is guarded so the
# helper can never abort a caller running under `set -e`. This is what stops a quarantined, hung
# claude (issue #137: com.apple.quarantine makes every exec hang in _dyld_start, `--version`
# included) from hanging the doctor itself — a timeout is REPORTED instead.
_herd_doctor_run_timeout() {
  local secs="$1"; shift
  local rc=0
  if command -v timeout >/dev/null 2>&1; then
    timeout "$secs" "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"
  fi
  if command -v gtimeout >/dev/null 2>&1; then
    gtimeout "$secs" "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"
  fi
  # Pure-shell fallback (stock macOS has neither timeout nor gtimeout). It needs a working `sleep` to
  # enforce the wall-clock bound; if `sleep` is somehow unavailable, degrade to an un-timed direct run
  # rather than busy-spin into a FALSE timeout. `sleep` is present on every real macOS/Linux (/bin,
  # /usr/bin), so this degradation only bites an artificially stripped PATH — never a live host.
  if ! sleep 0 2>/dev/null; then
    "$@" >/dev/null 2>&1 || rc=$?
    return "$rc"
  fi
  "$@" >/dev/null 2>&1 &
  local pid=$! waited=0
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$secs" ]; then
      kill -TERM "$pid" 2>/dev/null || true
      sleep 1
      kill -KILL "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited+1))
  done
  wait "$pid" 2>/dev/null || rc=$?
  return "$rc"
}

# _herd_doctor_realpath <path> — resolve a symlink chain to its final target WITHOUT `readlink -f`
# (GNU-only; stock macOS lacks it). Follows the brew shim/symlink chain (e.g.
# /opt/homebrew/bin/claude → ../Caskroom/claude-code/<ver>/bin/claude) to the real Caskroom binary so
# the quarantine check below inspects the actual on-disk file, not the shim. Bounded to 40 hops to
# defuse a symlink loop. Echoes the resolved path (or the input unchanged when it is not a symlink).
_herd_doctor_realpath() {
  local p="$1" n=0 target
  while [ -L "$p" ] && [ "$n" -lt 40 ]; do
    target="$(readlink "$p" 2>/dev/null)" || break
    [ -n "$target" ] || break
    case "$target" in
      /*) p="$target" ;;
      *)  p="$(dirname "$p")/$target" ;;
    esac
    n=$((n+1))
  done
  printf '%s' "$p"
}

# _herd_doctor_has_quarantine <path> — true when the file carries the com.apple.quarantine xattr,
# the macOS Gatekeeper flag that (after a `brew upgrade --cask`) hangs every new exec of the binary
# in _dyld_start (issue #137). Lists xattr names one-per-line and matches the exact attribute name;
# the caller guards `xattr`'s availability (darwin-only, but present on all macOS).
_herd_doctor_has_quarantine() {
  xattr "$1" 2>/dev/null | grep -q '^com\.apple\.quarantine$'  # pipe-ok: bounded command output, under a pipe buffer
}

# _herd_doctor_find_config — resolve the project's .herd/config the way herd-config.sh does
# (HERD_CONFIG_FILE env, else walk up from $PWD). Prints the path, or nothing when no project config
# is found. No dogfood fallback: if a project has no config there is nothing to lint.
_herd_doctor_find_config() {
  if [ -n "${HERD_CONFIG_FILE:-}" ]; then printf '%s' "$HERD_CONFIG_FILE"; return 0; fi
  local d="$PWD"
  while [ -n "$d" ] && [ "$d" != "/" ]; do
    [ -f "$d/.herd/config" ] && { printf '%s' "$d/.herd/config"; return 0; }
    d="$(dirname "$d")"
  done
  return 0
}

herd_doctor() {
  [ "${HERD_SKIP_DOCTOR:-}" = "1" ] && return 0

  local os hard_fail=0 warn=0 cfg_dup=0 tool brand
  brand="$(_herd_brand)"
  os="$(_herd_doctor_os)"
  printf 'herd doctor \xe2\x80\x94 checking dependencies (platform: %s)\n\n' "$os"

  # ── Tier 1: REQUIRED (git, gh + auth). These, and only these, gate `herd init`; a miss is the
  #    exit-1 condition. Collected in one pass (never fail-on-first). ────────────────────────────
  printf 'Required (herd init needs these):\n'
  for tool in git gh; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '  \xe2\x9c\x93 %s\n' "$tool"
    else
      printf '  \xe2\x9c\x97 %s not found\n' "$tool"
      printf '      fix: %s\n' "$(_herd_doctor_hint "$tool" "$os")"
      hard_fail=1
    fi
  done
  # gh auth — a present-but-unauthenticated gh breaks every PR/issue lane just as surely as an
  # absent one. Only meaningful when gh itself is installed (its absence is already reported).
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      printf '  \xe2\x9c\x93 gh auth (logged in)\n'
    else
      printf '  \xe2\x9c\x97 gh auth \xe2\x80\x94 not authenticated\n'
      printf '      fix: gh auth login\n'
      hard_fail=1
    fi
  fi

  # ── Tier 2: RECOMMENDED (herdr + JSON contract, claude, python3 + UTF-8). Needed to RUN the
  #    workflow, but checked lazily at point-of-use — a miss only WARNS here, never blocks init. ──
  printf '\nRecommended (to run the control room & spawn agents; a missing one only warns \xe2\x80\x94 herd re-checks it at point-of-use):\n'

  # herdr — presence, then (only if present) its JSON contract, since a version-skewed herdr fails
  # every lane parse cryptically. Reuse the exact preflight probe (its verbose stderr is suppressed
  # here; the doctor prints its own one-line verdict).
  if _herd_doctor_recommend herdr "$os" 'launch the control room (coordinator) & drive panes'; then
    if _herd_herdr_contract_probe 2>/dev/null; then
      printf '  \xe2\x9c\x93 herdr JSON contract\n'
    else
      printf '  \xe2\x9a\xa0 herdr JSON contract \xe2\x80\x94 `herdr tab list` failed or its JSON shape has skewed\n'
      printf '      fix: upgrade/repair herdr to a version %s lanes can parse\n' "$brand"
      warn=$((warn+1))
    fi
  else
    warn=$((warn+1))
  fi

  # claude — needed when a lane spawns a Claude Code agent. Beyond mere presence, RUN a probe under a
  # HARD TIMEOUT: a quarantined binary (com.apple.quarantine after a `brew upgrade --cask`) hangs
  # EVERY exec in _dyld_start — even `claude --version` never returns — so an un-timed probe would
  # hang the doctor itself and every spawned builder/scribe sits idle with a blank pane (issue #137).
  # The timeout turns that hang into a REPORTED failure with a fix. On darwin also xattr-check the
  # RESOLVED binary (follow the brew shim/symlink chain to the Caskroom target) and print the exact
  # one-line un-quarantine command. All of this stays in the RECOMMENDED tier (warns, never gates
  # init) — but a hang/quarantine is surfaced loudly with its remedy.
  if _herd_doctor_recommend claude "$os" 'spawn a Claude Code agent in a lane'; then
    local claude_secs="${HERD_DOCTOR_CLAUDE_TIMEOUT:-5}" claude_rc=0
    if _herd_doctor_run_timeout "$claude_secs" claude --version; then
      printf '  \xe2\x9c\x93 claude responds (claude --version returned within %ss)\n' "$claude_secs"
    else
      claude_rc=$?
      if [ "$claude_rc" -eq 124 ]; then
        printf '  \xe2\x9a\xa0 claude HUNG \xe2\x80\x94 `claude --version` did not return within %ss; the binary never finishes starting (hangs in _dyld_start), so spawned agents sit idle with blank panes\n' "$claude_secs"
        if [ "$os" = darwin ]; then
          printf '      likely the com.apple.quarantine hang after a `brew upgrade --cask` (issue #137) \xe2\x80\x94 see the quarantine line below for the exact fix\n'
        else
          printf '      fix: reinstall/repair the claude binary \xe2\x80\x94 %s\n' "$(_herd_doctor_hint claude "$os")"
        fi
        warn=$((warn+1))
      else
        printf '  \xe2\x9a\xa0 claude \xe2\x80\x94 `claude --version` exited non-zero (rc=%s); the binary may be broken\n' "$claude_rc"
        printf '      fix: %s\n' "$(_herd_doctor_hint claude "$os")"
        warn=$((warn+1))
      fi
    fi
    # darwin quarantine xattr check on the resolved Caskroom binary (guarded on `xattr` presence).
    if [ "$os" = darwin ] && command -v xattr >/dev/null 2>&1; then
      local claude_bin
      claude_bin="$(_herd_doctor_realpath "$(command -v claude)")"
      if _herd_doctor_has_quarantine "$claude_bin"; then
        printf '  \xe2\x9a\xa0 claude binary is QUARANTINED (com.apple.quarantine) \xe2\x80\x94 %s\n' "$claude_bin"
        printf '      new claude execs can hang in _dyld_start (spawned agents sit idle with blank panes, issue #137)\n'
        printf '      fix: xattr -d com.apple.quarantine %s\n' "$claude_bin"
        warn=$((warn+1))
      else
        printf '  \xe2\x9c\x93 claude binary not quarantined\n'
      fi
    fi
  else
    warn=$((warn+1))
  fi

  # python3 — the JSON/UTF-8 pane helpers. Presence, then (only if present) its UTF-8 capability
  # (issue #31): present-but-cp1252 python3 is the confirmed Windows root cause. A broken encoding
  # now WARNS (herdkit's own emoji pane labels are not a generic consumer's concern at init time).
  if _herd_doctor_recommend python3 "$os" 'run the JSON/UTF-8 pane helpers'; then
    local utf verdict enc
    utf="$(_herd_doctor_python_utf8 python3)"
    verdict="${utf%% *}"; enc="${utf#* }"
    case "$verdict" in
      OK)
        printf '  \xe2\x9c\x93 python3 UTF-8 (stdout encoding: %s)\n' "$enc" ;;
      FIXED)
        printf '  \xe2\x9c\x93 python3 UTF-8 (default encoding %s can'\''t emit UTF-8; %s exports PYTHONUTF8=1 to fix it)\n' "$enc" "$brand" ;;
      *)
        printf '  \xe2\x9a\xa0 python3 UTF-8 \xe2\x80\x94 cannot emit UTF-8 even with PYTHONUTF8=1 (encoding: %s)\n' "$enc"
        printf '      fix: upgrade to Python 3.7+ \xe2\x80\x94 herd scripts print emoji/box-drawing pane labels through python3\n'
        warn=$((warn+1)) ;;
    esac
  else
    warn=$((warn+1))
  fi

  # ── Tier 3: OPTIONAL (soft) — degrade one feature, never block. ──────────────────────────────
  printf '\nOptional (a missing one only degrades one feature):\n'
  _herd_doctor_soft glow       'backlog-view.sh renders raw markdown instead of a pretty view'
  _herd_doctor_soft shellcheck 'healthcheck skips shell lint (bash -n still runs)'
  _herd_doctor_soft bats       'healthcheck runs the *.sh test suite directly instead of via bats'

  # ── Config lint: duplicate keys in .herd/config (issue #115). .herd/config is shell-sourced, so a
  #    KEY assigned twice silently last-wins and can disable a gate — catch it PROACTIVELY here.
  #    Advisory (⚠ only; does NOT change the doctor's required-dep exit contract — `herd config lint`
  #    is the dedicated non-zero gate). Runs only when the scanner is available (herd-config.sh
  #    sourced, e.g. via `herd doctor`) and a project config exists. ─────────────────────────────
  if command -v _herd_config_dup_keys >/dev/null 2>&1; then
    local _dc_cfg; _dc_cfg="$(_herd_doctor_find_config)"
    if [ -n "$_dc_cfg" ] && [ -f "$_dc_cfg" ]; then
      printf '\nConfig (.herd/config):\n'
      local _dc_dupes; _dc_dupes="$(_herd_config_dup_keys "$_dc_cfg")"
      if [ -n "$_dc_dupes" ]; then
        printf '  \xe2\x9a\xa0 duplicate key(s) \xe2\x80\x94 shell last-wins silently overrides earlier values (can disable a gate, issue #115):\n'
        local _dc_k
        while IFS= read -r _dc_k; do
          [ -n "$_dc_k" ] && printf '      \xe2\x80\xa2 %s (last assignment wins)\n' "$_dc_k"
        done <<< "$_dc_dupes"
        printf '      fix: delete the stale duplicate line(s), or run `herd config lint`\n'
        cfg_dup=1
      else
        printf '  \xe2\x9c\x93 no duplicate keys\n'
      fi
      # HERD-47: the per-user overlay .herd/config.local is ALSO shell-sourced with last-wins, so scan
      # it for duplicate keys too (a dup WITHIN the overlay silently disables a gate exactly like one in
      # the baseline; a key set in BOTH files is an intentional override, not a dup). Note its presence
      # so the effective config is not a mystery (`herd config list` shows per-key provenance).
      local _dc_local="$(dirname "$_dc_cfg")/config.local"
      if [ -f "$_dc_local" ]; then
        local _dc_local_dupes; _dc_local_dupes="$(_herd_config_dup_keys "$_dc_local")"
        if [ -n "$_dc_local_dupes" ]; then
          printf '  \xe2\x9a\xa0 duplicate key(s) in config.local overlay \xe2\x80\x94 shell last-wins silently overrides earlier values (can disable a gate, issue #115):\n'
          local _dc_lk
          while IFS= read -r _dc_lk; do
            [ -n "$_dc_lk" ] && printf '      \xe2\x80\xa2 %s (last assignment wins)\n' "$_dc_lk"
          done <<< "$_dc_local_dupes"
          printf '      fix: delete the stale duplicate line(s), or run `herd config lint`\n'
          cfg_dup=1
        else
          printf '  \xe2\x9c\x93 config.local overlay present, no duplicate keys \xe2\x80\x94 per-user keys override the baseline (see `herd config list` for provenance)\n'
        fi
      fi
    fi
  fi

  # ── Engine version handshake (HERD-179): report the local engine level against the project's
  #    committed ENGINE_MIN floor, plus the ENGINE_AUTOUPDATE posture. ADVISORY — a stale engine is
  #    an operator action (`herd update`), not a missing dependency, so it never touches hard_fail or
  #    the warn counter and never changes the doctor's exit contract. ────────────────────────────
  if command -v herd_engine_doctor_row >/dev/null 2>&1; then
    herd_engine_doctor_row
  fi

  printf '\n'
  if [ "$cfg_dup" -ne 0 ]; then
    printf 'doctor: \xe2\x9a\xa0 .herd/config has duplicate key(s) (see Config above) \xe2\x80\x94 run `herd config lint`; shell last-wins can silently disable a gate (issue #115).\n'
  fi
  if [ "$hard_fail" -ne 0 ]; then
    printf 'doctor: \xe2\x9c\x97 a REQUIRED dependency (git / gh) is missing or broken (see \xe2\x9c\x97 above) \xe2\x80\x94 herd init cannot proceed.\n'
    printf '        (bypass this gate in tests/CI with HERD_SKIP_DOCTOR=1)\n'
    return 1
  fi
  if [ "$warn" -ne 0 ]; then
    printf 'doctor: \xe2\x9c\x93 required dependencies (git, gh) present \xe2\x80\x94 herd init can proceed.\n'
    printf '        \xe2\x9a\xa0 %d recommended dependency check(s) failed (see \xe2\x9a\xa0 above); the herd features that need them stay unavailable until you install them.\n' "$warn"
    return 0
  fi
  printf 'doctor: \xe2\x9c\x93 all required dependencies present.\n'
  return 0
}
