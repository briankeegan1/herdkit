#!/usr/bin/env bash
# test-agent-name-sanitize.sh — hermetic proof for herd_agent_name_sanitize (HERD-418): herdr 0.7.5
# validates agent names strictly (must start with a lowercase letter; only lowercase letters, digits,
# dash, underscore; 1-32 chars), so the engine's dotted role names (resolve·<slug>, review·<slug>)
# fail outright with invalid_agent_name. This proves the ONE shared sanitizer, and that registration
# and lookup route through it identically so they can never derive a different name for the same
# request.
#
# Covers:
#   1. Pure sanitizer: dot mapping, leading-digit prefixing, over-32 deterministic truncation,
#      idempotence, and byte-identical passthrough for an already-valid name.
#   2. REGISTRATION: herd_driver_herdr_attach_agent (the attach-CLI seam) and the pre-0.7.5
#      herd_driver_launch_agent branch both register the SANITIZED name with herdr, never the raw
#      dotted request — proven against a stub herdr that would hard-fail on an invalid name.
#   3. LOOKUP: herd_driver_agent_pane_id and herd_driver_agent_liveness find the pane of an agent
#      registered under the sanitized name when QUERIED with the original dotted request — the exact
#      registration/lookup agreement HERD-418 requires.
#   4. GUARDED CLOSE (HERD-134) stays PRECISE after sanitization: herd_close_pane_verified's
#      colon-anchored ":review"/":resolve" kind closes a genuine reviewer/resolver pane (whether its
#      live identity is the sanitized agent-name form or the pretty label form) but REFUSES an
#      unrelated co-tab pane whose slug merely CONTAINS the word (e.g. a builder on "fix-resolve-race"
#      — the pre-merge review finding this test locks in).
#
# Fully hermetic: local temp dirs + a stub herdr on PATH. NO real herdr/claude/gh/network.
# Run:  bash tests/test-agent-name-sanitize.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }
[ -f "$DRIVER_SH" ] || fail "missing script: $DRIVER_SH"
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# shellcheck source=/dev/null
. "$DRIVER_SH"

# ── 1. pure sanitizer ───────────────────────────────────────────────────────────────────────────

got="$(herd_agent_name_sanitize 'resolve·x')"
[ "$got" = "resolve-x" ] || fail "dot mapping: resolve·x -> '$got', want resolve-x"
ok

got="$(herd_agent_name_sanitize 'review·init-archetypes')"
[ "$got" = "review-init-archetypes" ] || fail "dot mapping: review·init-archetypes -> '$got'"
ok
echo "PASS (1a) middle-dot maps to a single dash"

got="$(herd_agent_name_sanitize '123abc')"
case "$got" in
  [a-z]*) : ;;
  *) fail "leading digit: '123abc' -> '$got' does not start with a lowercase letter" ;;
esac
case "$got" in *123abc*) : ;; *) fail "leading digit: '$got' lost the original content" ;; esac
ok
echo "PASS (1b) a name not starting with a lowercase letter is prefixed to one"

long_in="$(python3 -c 'print("a" + "b" * 60)')"
got1="$(herd_agent_name_sanitize "$long_in")"
got2="$(herd_agent_name_sanitize "$long_in")"
[ "${#got1}" -le 32 ] || fail "truncation: '$got1' is ${#got1} chars, want <=32"
[ "$got1" = "$got2" ] || fail "truncation: not deterministic ('$got1' vs '$got2')"
ok
echo "PASS (1c) over-32-char input truncates to <=32 chars, stably"

for probe in 'resolve·x' 'review·init-archetypes' '123abc' "$long_in" 'a' '' '__weird--Name..1'; do
  once="$(herd_agent_name_sanitize "$probe")"
  twice="$(herd_agent_name_sanitize "$once")"
  [ "$once" = "$twice" ] || fail "idempotence: sanitize('$probe')='$once' but sanitize(that)='$twice'"
done
ok
echo "PASS (1d) sanitize(sanitize(x)) == sanitize(x) for every probe"

got="$(herd_agent_name_sanitize 'feature-x')"
[ "$got" = "feature-x" ] || fail "already-valid passthrough: 'feature-x' -> '$got'"
got="$(herd_agent_name_sanitize 'coord')"
[ "$got" = "coord" ] || fail "already-valid passthrough: 'coord' -> '$got'"
ok
echo "PASS (1e) an already-valid name passes through byte-identical"

# ── 2. registration: the sanitized name is what herdr actually sees ────────────────────────────

BIN="$T/bin"; mkdir -p "$BIN"
STATE="$T/state"; mkdir -p "$STATE"
cat > "$BIN/herdr" <<'STUB'
#!/usr/bin/env bash
# Records every `agent start <name>` it is asked to register; hard-fails (mirroring the REAL
# herdr 0.7.5 invalid_agent_name rejection) on any name outside [a-z][a-z0-9_-]{0,31}.
STATE="${HERDR_STUB_STATE:?HERDR_STUB_STATE unset}"
if [ "${1:-}" = "agent" ] && [ "${2:-}" = "start" ]; then
  shift 2
  if [ "${1:-}" = "--help" ]; then
    printf 'usage: herdr agent start <name> --kind <kind> --pane <id> [-- ARGS…]\n'
    exit 0
  fi
  name="$1"; shift
  case "$name" in
    [a-z]*)
      case "$name" in
        *[!a-z0-9_-]*) printf '{"error":"invalid_agent_name"}\n' >&2; exit 1 ;;
      esac
      [ "${#name}" -le 32 ] || { printf '{"error":"invalid_agent_name"}\n' >&2; exit 1; }
      ;;
    *) printf '{"error":"invalid_agent_name"}\n' >&2; exit 1 ;;
  esac
  printf '%s\n' "$name" > "$STATE/registered.name"
  pane=""
  while [ $# -gt 0 ]; do
    [ "$1" = "--pane" ] && pane="$2"
    shift
  done
  printf '{"result":{"agent":{"pane_id":"%s"}}}\n' "${pane:-p1}"
  exit 0
fi
if [ "${1:-}" = "agent" ] && [ "${2:-}" = "list" ]; then
  cat "$STATE/agents.json" 2>/dev/null || printf '{"result":{"agents":[]}}\n'
  exit 0
fi
exit 0
STUB
chmod +x "$BIN/herdr"

( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN:$PATH" HERDR_STUB_STATE="$STATE"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  # attach-CLI seam (herdr >=0.7.5): herd_driver_herdr_attach_agent is the ONE bridge every herdr-claude
  # spawn site funnels through.
  rm -f "$STATE/registered.name"
  herd_driver_herdr_attach_agent 'resolve·dotted-slug' herdr-claude p0 "$T" "" no -- claude --model opus P >/dev/null 2>&1
  got="$(cat "$STATE/registered.name" 2>/dev/null || true)"
  want="$(herd_agent_name_sanitize 'resolve·dotted-slug')"
  [ "$got" = "$want" ] || { echo "FAIL: attach-CLI registered '$got', want '$want'"; exit 1; }
  exit 0
) || fail "attach-CLI registration did not use the sanitized name"
ok
echo "PASS (2a) herd_driver_herdr_attach_agent registers the SANITIZED name with herdr"

BIN2="$T/bin2"; mkdir -p "$BIN2"
cat > "$BIN2/herdr" <<'STUB'
#!/usr/bin/env bash
# pre-0.7.5 herdr stub: `agent start --help` does NOT document --pane, so the driver falls back to
# the bare (non-attach) CLI shape.
STATE="${HERDR_STUB_STATE:?HERDR_STUB_STATE unset}"
if [ "${1:-}" = "agent" ] && [ "${2:-}" = "start" ]; then
  shift 2
  if [ "${1:-}" = "--help" ]; then
    printf 'usage: herdr agent start <name> --workspace <id> --cwd <dir> [--tab <id>] [--split r|d] [--no-focus] [--env K=V] -- <runtime>\n'
    exit 0
  fi
  name="$1"; shift
  case "$name" in
    [a-z]*)
      case "$name" in
        *[!a-z0-9_-]*) printf '{"error":"invalid_agent_name"}\n' >&2; exit 1 ;;
      esac
      ;;
    *) printf '{"error":"invalid_agent_name"}\n' >&2; exit 1 ;;
  esac
  printf '%s\n' "$name" > "$STATE/registered.name"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN2/herdr"

( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN2:$PATH" HERDR_STUB_STATE="$STATE"
  herd_resolve_workspace_id(){ printf 'ws1'; }
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  rm -f "$STATE/registered.name"
  herd_driver_launch_agent name='review·dotted-slug' workspace=ws1 cwd="$T" tab=tabA split=down \
    model=opus flags=--dangerously-skip-permissions pointer=P >/dev/null 2>&1
  got="$(cat "$STATE/registered.name" 2>/dev/null || true)"
  want="$(herd_agent_name_sanitize 'review·dotted-slug')"
  [ "$got" = "$want" ] || { echo "FAIL: pre-0.7.5 CLI registered '$got', want '$want'"; exit 1; }
  exit 0
) || fail "pre-0.7.5 CLI registration did not use the sanitized name"
ok
echo "PASS (2b) herd_driver_launch_agent's pre-0.7.5 branch registers the SANITIZED name too"

# ── 3. lookup: a dotted REQUEST finds the pane registered under the sanitized name ──────────────

( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN:$PATH" HERDR_STUB_STATE="$STATE"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  reg_name="$(herd_agent_name_sanitize 'resolve·look-me-up')"
  cat > "$STATE/agents.json" <<JSON
{"result":{"agents":[{"name":"$reg_name","agent":"","pane_id":"pane-42","agent_status":"idle"}]}}
JSON

  got="$(herd_driver_agent_pane_id 'resolve·look-me-up')"
  [ "$got" = "pane-42" ] || { echo "FAIL: herd_driver_agent_pane_id('resolve·look-me-up') = '$got', want pane-42"; exit 1; }
  exit 0
) || fail "herd_driver_agent_pane_id did not resolve the dotted request against the sanitized roster entry"
ok
echo "PASS (3a) herd_driver_agent_pane_id resolves a dotted request via the sanitized roster name"

( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN:$PATH" HERDR_STUB_STATE="$STATE"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"

  reg_name="$(herd_agent_name_sanitize 'review·look-me-up-2')"
  cat > "$STATE/agents.json" <<JSON
{"result":{"agents":[{"name":"$reg_name","agent":"","pane_id":"pane-99","agent_status":"working"}]}}
JSON
  # process-info: any herdr call not matched above (agent list handled) — 'pane process-info' isn't
  # stubbed, so it fails soft; herd_driver_agent_liveness only needs the roster match to have located
  # a pane at all (a bare failed process-info reads 'unknown', which still proves the LOOKUP matched).
  got="$(herd_driver_agent_liveness 'review·look-me-up-2')"
  case "$got" in
    alive|dead|unknown) : ;;
    missing) echo "FAIL: herd_driver_agent_liveness read 'missing' — the roster match failed (dotted request vs sanitized name disagreed)"; exit 1 ;;
    *) echo "FAIL: unexpected liveness token '$got'"; exit 1 ;;
  esac
  exit 0
) || fail "herd_driver_agent_liveness did not resolve the dotted request against the sanitized roster entry"
ok
echo "PASS (3b) herd_driver_agent_liveness resolves a dotted request via the sanitized roster name (never 'missing')"

# ── 4. guarded close stays precise: colon-anchored kind vs. a merely-substring-matching neighbour ──

BIN3="$T/bin3"; mkdir -p "$BIN3"
STATE3="$T/state3"; mkdir -p "$STATE3"
cat > "$BIN3/herdr" <<'STUB'
#!/usr/bin/env bash
STATE="${HERDR_STUB_STATE:?HERDR_STUB_STATE unset}"
if [ "${1:-}" = "agent" ] && [ "${2:-}" = "list" ]; then
  cat "$STATE/agents.json" 2>/dev/null || printf '{"result":{"agents":[]}}\n'
  exit 0
fi
if [ "${1:-}" = "pane" ] && [ "${2:-}" = "list" ]; then
  cat "$STATE/panes.json" 2>/dev/null || printf '{"result":{"panes":[]}}\n'
  exit 0
fi
if [ "${1:-}" = "pane" ] && [ "${2:-}" = "close" ]; then
  printf '%s\n' "${3:-}" >> "$STATE/closed.log"
  exit 0
fi
exit 0
STUB
chmod +x "$BIN3/herdr"

# (4a) BLOCKING finding repro: a builder pane whose SLUG merely contains "resolve" must survive a
# resolver-pane retire — a bare "resolve" kind would wrongly close it; ":resolve" must not.
( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN3:$PATH" HERDR_STUB_STATE="$STATE3"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  : > "$STATE3/closed.log"
  cat > "$STATE3/agents.json" <<'JSON'
{"result":{"agents":[{"name":"fix-resolve-race","agent":"","pane_id":"pane-builder"}]}}
JSON
  herd_close_pane_verified pane-builder ":resolve"
  rc=$?
  closed="$(cat "$STATE3/closed.log" 2>/dev/null || true)"
  if [ -n "$closed" ]; then
    echo "FAIL: an unrelated builder pane (identity agent:fix-resolve-race) was closed by kind ':resolve'"; exit 1
  fi
  [ "$rc" -ne 0 ] || { echo "FAIL: herd_close_pane_verified returned success for a non-match"; exit 1; }
  exit 0
) || fail "guarded close wrongly closed a co-tab pane whose slug merely contains the role word"
ok
echo "PASS (4a) a co-tab pane whose slug merely CONTAINS 'resolve' survives a ':resolve' guarded close"

# (4b) the real cases still work: a resolver registered under the sanitized agent-name form closes.
( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN3:$PATH" HERDR_STUB_STATE="$STATE3"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  : > "$STATE3/closed.log"
  reg_name="$(herd_agent_name_sanitize 'resolve·myslug')"
  printf '{"result":{"agents":[{"name":"%s","agent":"","pane_id":"pane-r1"}]}}\n' "$reg_name" > "$STATE3/agents.json"
  herd_close_pane_verified pane-r1 ":resolve" || { echo "FAIL: rc"; exit 1; }
  grep -qxF pane-r1 "$STATE3/closed.log" || { echo "FAIL: sanitized-agent-name resolver pane was not closed"; exit 1; }
  exit 0
) || fail "guarded close failed to close a real resolver pane registered under its sanitized agent name"
ok
echo "PASS (4b) a resolver pane registered as the SANITIZED agent name closes on ':resolve'"

# (4c) the pretty-label form (a delisted agent / the standalone fallback tab) still closes too.
( set +e
  export HERD_DRIVER="herdr-claude" PATH="$BIN3:$PATH" HERDR_STUB_STATE="$STATE3"
  # shellcheck source=/dev/null
  . "$DRIVER_SH"
  : > "$STATE3/closed.log"
  printf '{"result":{"agents":[]}}\n' > "$STATE3/agents.json"
  printf '{"result":{"panes":[{"pane_id":"pane-r2","label":"resolve·myslug"}]}}\n' > "$STATE3/panes.json"
  herd_close_pane_verified pane-r2 ":resolve" || { echo "FAIL: rc"; exit 1; }
  grep -qxF pane-r2 "$STATE3/closed.log" || { echo "FAIL: pretty-label resolver pane was not closed"; exit 1; }
  exit 0
) || fail "guarded close failed to close a resolver pane identified only by its pretty label"
ok
echo "PASS (4c) a resolver pane identified only by its pretty 'resolve·' label closes on ':resolve'"

echo "ALL PASS ($pass checks)"
