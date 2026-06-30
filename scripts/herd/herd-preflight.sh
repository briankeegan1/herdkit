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

  # (b) Probe the CLI/JSON contract with a read-only, side-effect-free call. `herdr tab list`
  #     returns the same shape envelope every lane relies on; if it errors or the JSON shape has
  #     skewed, every later `herdr tab create`/`agent start` parse would fail cryptically.
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

  # Validate the shape: parseable JSON with a top-level result.tabs ARRAY (the envelope all lanes
  # share). python3 here always exits 0 and reports OK / BAD:<reason> on stdout, so this stays safe
  # under the caller's `set -e` (a non-zero python exit in an assignment would otherwise abort).
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
    OK*) ;;
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
