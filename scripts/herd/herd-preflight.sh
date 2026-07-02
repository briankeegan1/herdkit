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

herd_preflight() {
  [ "${HERD_SKIP_PREFLIGHT:-}" = "1" ] && return 0

  # (a) herdr must be on PATH at all.
  if ! command -v herdr >/dev/null 2>&1; then
    {
      echo "herdr not found on PATH."
      echo "  herdr is the terminal/agent multiplexer that herdkit lanes drive (tab create,"
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
    found="$(printf '%s' "$raw" | grep -oE '[0-9]+(\.[0-9]+){0,3}' | head -1)"
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
  local out diag
  if ! out="$(herdr tab list 2>/dev/null)"; then
    {
      echo "herdr CLI contract check failed."
      echo "  expected: a read-only \`herdr tab list\` to succeed and emit JSON"
      echo "  found:    \`herdr tab list\` exited non-zero"
      echo "  Your herdr looks broken or incompatible with the shape herdkit's lanes parse."
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
        echo "  Your herdr's output shape has skewed from what herdkit's lanes expect."
        echo "  Fix: upgrade herdr to a compatible version, then retry.   (bypass: HERD_SKIP_PREFLIGHT=1)"
      } >&2
      return 1
      ;;
  esac
}

# ═════════════════════════════════════════════════════════════════════════════
# herd_doctor — the COMPREHENSIVE dependency doctor. Unlike herd_preflight (a fast, herdr-only,
# fail-on-first guard for the lane hot-path), the doctor checks EVERY required dependency in ONE
# pass and reports them all at once, so a broken environment surfaces its full picture rather than
# one-error-at-a-time. Run it at install time (advisory) and at the top of `herd init` (hard gate,
# before any config is written), and expose it as `herd doctor` for on-demand self-diagnosis.
#
# HARD-required (a partially-broken control room without them — the issue #31 class of silent
# failure): git, gh (+ `gh auth status`), claude, python3, herdr (+ its JSON contract). On top of
# presence, python3 must be able to emit UTF-8 to a pipe — on Windows it defaults to the cp1252
# codepage and dies with UnicodeEncodeError on the emoji/box-drawing pane labels herd scripts print
# through `python3 -c` (issue #31); herdkit exports PYTHONUTF8=1 in herd-config.sh to fix this, and
# the doctor confirms the fix actually takes.
#
# SOFT (a missing one only degrades ONE feature, never blocks): glow (backlog-view pretty-print),
# shellcheck + bats (healthcheck lint/tests).
#
# Returns 0 when every HARD dep is present and healthy; non-zero when any is missing/broken. Prints
# a per-dependency ✓/✗ report to stdout with per-platform install hints. Human-facing output only —
# no machine parses it, so the non-ASCII marks are safe here (unlike the JSON-parse paths).
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

# _herd_doctor_hint <tool> <os> — a one-line, copy-pasteable install hint for a missing HARD dep.
_herd_doctor_hint() {
  local tool="$1" os="$2"
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
      printf 'install the herdr CLI (the terminal/agent multiplexer herdkit drives) and ensure it is on PATH' ;;
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

herd_doctor() {
  [ "${HERD_SKIP_DOCTOR:-}" = "1" ] && return 0

  local os hard_fail=0 tool
  os="$(_herd_doctor_os)"
  printf 'herd doctor \xe2\x80\x94 checking dependencies (platform: %s)\n\n' "$os"
  printf 'Required:\n'

  # (1) Presence of every HARD tool — collected in one pass (never fail-on-first).
  for tool in git gh claude python3 herdr; do
    if command -v "$tool" >/dev/null 2>&1; then
      printf '  \xe2\x9c\x93 %s\n' "$tool"
    else
      printf '  \xe2\x9c\x97 %s not found\n' "$tool"
      printf '      fix: %s\n' "$(_herd_doctor_hint "$tool" "$os")"
      hard_fail=1
    fi
  done

  # (2) gh auth — a present-but-unauthenticated gh breaks every PR/issue lane just as surely as an
  #     absent one. Only meaningful when gh itself is installed (its absence is already reported).
  if command -v gh >/dev/null 2>&1; then
    if gh auth status >/dev/null 2>&1; then
      printf '  \xe2\x9c\x93 gh auth (logged in)\n'
    else
      printf '  \xe2\x9c\x97 gh auth \xe2\x80\x94 not authenticated\n'
      printf '      fix: gh auth login\n'
      hard_fail=1
    fi
  fi

  # (3) python3 UTF-8 capability (issue #31). Present-but-cp1252 python3 is the confirmed Windows
  #     root cause; verify it can actually emit the emoji pane labels the engine prints.
  if command -v python3 >/dev/null 2>&1; then
    local utf verdict enc
    utf="$(_herd_doctor_python_utf8 python3)"
    verdict="${utf%% *}"; enc="${utf#* }"
    case "$verdict" in
      OK)
        printf '  \xe2\x9c\x93 python3 UTF-8 (stdout encoding: %s)\n' "$enc" ;;
      FIXED)
        printf '  \xe2\x9c\x93 python3 UTF-8 (default encoding %s can'\''t emit UTF-8; herdkit exports PYTHONUTF8=1 to fix it)\n' "$enc" ;;
      *)
        printf '  \xe2\x9c\x97 python3 UTF-8 \xe2\x80\x94 cannot emit UTF-8 even with PYTHONUTF8=1 (encoding: %s)\n' "$enc"
        printf '      fix: upgrade to Python 3.7+ \xe2\x80\x94 herd scripts print emoji/box-drawing pane labels through python3\n'
        hard_fail=1 ;;
    esac
  fi

  # (4) herdr JSON contract — presence alone is not enough; a version-skewed herdr fails every lane
  #     parse cryptically. Reuse the exact preflight probe (its verbose stderr is suppressed here;
  #     the doctor prints its own one-line verdict).
  if command -v herdr >/dev/null 2>&1; then
    if _herd_herdr_contract_probe 2>/dev/null; then
      printf '  \xe2\x9c\x93 herdr JSON contract\n'
    else
      printf '  \xe2\x9c\x97 herdr JSON contract \xe2\x80\x94 `herdr tab list` failed or its JSON shape has skewed\n'
      printf '      fix: upgrade/repair herdr to a version herdkit lanes can parse\n'
      hard_fail=1
    fi
  fi

  # (5) SOFT deps — degrade one feature, never block.
  printf '\nOptional (a missing one only degrades one feature):\n'
  _herd_doctor_soft glow       'backlog-view.sh renders raw markdown instead of a pretty view'
  _herd_doctor_soft shellcheck 'healthcheck skips shell lint (bash -n still runs)'
  _herd_doctor_soft bats       'healthcheck runs the *.sh test suite directly instead of via bats'

  printf '\n'
  if [ "$hard_fail" -ne 0 ]; then
    printf 'doctor: \xe2\x9c\x97 one or more REQUIRED dependencies are missing or broken (see \xe2\x9c\x97 above).\n'
    printf '        (bypass this gate in tests/CI with HERD_SKIP_DOCTOR=1)\n'
    return 1
  fi
  printf 'doctor: \xe2\x9c\x93 all required dependencies present.\n'
  return 0
}
