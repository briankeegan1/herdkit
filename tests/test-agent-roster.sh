#!/usr/bin/env bash
# test-agent-roster.sh — hermetic proof for the SPECIALIST AGENT ROSTER (HERD-667, epic HERD-666):
# committed definitions, the driver bindings, the two-sided empirical verify, and lane selection.
#
# The two traps this feature exists for, and where each is proved below:
#   T1 USER-SCOPE-VS-REPO — a runtime may read definitions ONLY from a user-scope dir, so PUBLISHING
#      is load-bearing. Case (5): install writes into the driver's own expanded lookup path, and is a
#      clean no-op for a driver with no lookup path at all.
#   T2 SILENT FALLBACK — an unknown agent name is silently ignored, so verification must be EMPIRICAL
#      and must be ABLE TO FAIL. Cases (6)-(9) drive verify against four fake runtimes: one that
#      really resolves, one that IGNORES --agent (trap T2 reproduced), one that echoes the sentinel
#      unconditionally (a probe that cannot discriminate), and an absent binary.
#
# Also proves the invariant every herdkit lever owes: (10) with HERD_AGENT UNSET the spawn argv and
# the task-spec concatenation are BYTE-IDENTICAL to a tree with no roster at all.
#
# Fully hermetic: temp dirs, a temp roster, and fake `stub-agent` runtimes on PATH. No real runtime,
# no herdr, no gh, no network. Run:  bash tests/test-agent-roster.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
AGENTS_SH="$ROOT/scripts/herd/agents.sh"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"
DRIVERS_DIR="$ROOT/templates/drivers"
GREP=/usr/bin/grep; command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

for f in "$AGENTS_SH" "$DRIVER_SH"; do [ -f "$f" ] || fail "missing required file: $f"; done

ROSTER="$T/roster"
mkdir -p "$ROSTER"
SENTINEL="HERD-AGENT-testing-0xSENTINEL"
cat > "$ROSTER/testing.md" <<EOF
---
name: testing
description: a test specialist
sentinel: $SENTINEL
---

You are the testing specialist. Never skip the negative control.
EOF

# roster_sh <code> — run <code> with agents.sh + driver.sh sourced, the temp roster in scope and a
# pinned pool for the verify cache. Every case runs in its own clean subshell so one case's env
# (driver, definition root, PATH) can never leak into the next.
_ROSTER_ENV=()
roster_sh() {
  env -u HERD_AGENT -u HERD_CLAUDE_FLAGS -u MODEL_QUICK \
      HERD_DRIVER="${HERD_DRIVER:-herdr-claude}" \
      HERD_AGENTS_DIR="$ROSTER" PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
      ${_ROSTER_ENV[@]+"${_ROSTER_ENV[@]}"} \
      bash -c 'set -uo pipefail; . "$1"; . "$2"; shift 2; eval "$@"' _ "$DRIVER_SH" "$AGENTS_SH" -- "$1"
}
mkdir -p "$T/proj" "$T/pool"

# ── 1. definition parsing: frontmatter fields and the body (the system prompt). ────────────────────
got="$(roster_sh 'herd_roster_field "$HERD_AGENTS_DIR/testing.md" sentinel')"
[ "$got" = "$SENTINEL" ] || fail "(1) sentinel field parsed as [$got]"
got="$(roster_sh 'herd_roster_field "$HERD_AGENTS_DIR/testing.md" description')"
[ "$got" = "a test specialist" ] || fail "(1) description parsed as [$got]"
got="$(roster_sh 'herd_roster_body "$HERD_AGENTS_DIR/testing.md"')"
case "$got" in
  *"You are the testing specialist"*) : ;;
  *) fail "(1) body did not carry the system prompt: [$got]" ;;
esac
case "$got" in *sentinel:*) fail "(1) body leaked the frontmatter block" ;; esac
got="$(roster_sh 'herd_roster_names')"
[ "$got" = "testing" ] || fail "(1) roster names = [$got]"
# A name that is not a safe definition name is refused BEFORE it can reach a filename or an argv.
roster_sh 'herd_roster_name_ok "../etc/passwd"' && fail "(1) name validation accepted a path"
roster_sh 'herd_roster_name_ok "a b"' && fail "(1) name validation accepted whitespace"
roster_sh 'herd_roster_name_ok ".hidden"' && fail "(1) name validation accepted a leading dot"
roster_sh 'herd_roster_name_ok "--dangerously-skip-permissions"' \
  && fail "(1) name validation accepted a FLAG-shaped name (it would read as an argv flag)"
pass; echo "PASS (1) definition parsing (frontmatter + body) and name validation"

# ── 2. every shipped driver binds all three roster keys, non-empty and zero-secret. ────────────────
ROSTER_KEYS="DRIVER_AGENT_DEFINITION_DIR DRIVER_AGENT_SELECT_FLAG DRIVER_AGENT_DEFINITION_MODE"
for d in herdr-claude headless codex grok stub; do
  df="$DRIVERS_DIR/$d.driver"
  [ -f "$df" ] || fail "(2) missing driver file: $df"
  ( set -euo pipefail; . "$df"
    for k in $ROSTER_KEYS; do
      [ -n "${!k+set}" ] || { echo "  $d: $k not defined" >&2; exit 1; }
      [ -n "${!k}" ]     || { echo "  $d: $k is empty" >&2; exit 1; }
    done
  ) || fail "(2) $d.driver does not bind every roster key"
  if "$GREP" -qiE '/users/|/home/|secret|password|apikey' \
       <<< "$("$GREP" -E '^DRIVER_AGENT_(DEFINITION|SELECT)[A-Z_]*=' "$df")"; then
    fail "(2) $d.driver roster bindings leak a secret or absolute host path"
  fi
  m="$(awk -F= '$1=="DRIVER_AGENT_DEFINITION_MODE"{gsub(/^.|.$/,"",$2); print $2}' "$df")"
  case "$m" in native|install|inject) : ;; *) fail "(2) $d.driver DEFINITION_MODE is '$m'" ;; esac
done
pass; echo "PASS (2) all 5 shipped drivers bind the 3 roster keys (non-empty, zero-secret, valid mode)"

# ── 3. @degrade is read as CAPABILITY ABSENT, so an unbound runtime degrades to inject. ───────────
# claude has a native repo-scope definition dir but NO by-name selector; codex has neither. Both must
# therefore report probe kind `inject` — the mechanism their lane actually uses.
for d in herdr-claude headless codex; do
  got="$(HERD_DRIVER="$d" roster_sh 'herd_roster_probe_kind')"
  [ "$got" = "inject" ] || fail "(3) $d probe kind = [$got], expected inject"
  got="$(HERD_DRIVER="$d" roster_sh 'herd_roster_select_argv testing')"
  [ -z "$got" ] || fail "(3) $d composed a select flag from a @degrade binding: [$got]"
done
# ...and the reason is reportable rather than a silent blank.
got="$(HERD_DRIVER=codex roster_sh 'herd_roster_degrade_reason DRIVER_AGENT_SELECT_FLAG')"
case "$got" in *codex*) : ;; *) fail "(3) codex degrade reason not surfaced: [$got]" ;; esac
# A runtime WITH a selector composes the flag pair, with <name> substituted.
got="$(HERD_DRIVER=stub roster_sh 'herd_roster_select_argv testing')"
[ "$got" = "--agent testing" ] || fail "(3) stub select argv = [$got]"
got="$(HERD_DRIVER=grok roster_sh 'herd_roster_select_argv testing')"
[ "$got" = "--agent testing" ] || fail "(3) grok select argv = [$got]"
got="$(HERD_DRIVER=stub roster_sh 'herd_roster_probe_kind')"
[ "$got" = "flag" ] || fail "(3) stub probe kind = [$got], expected flag"
# A name that fails validation can never inject an argv token.
got="$(HERD_DRIVER=stub roster_sh 'herd_roster_select_argv "--rm -rf /"')"
[ -z "$got" ] || fail "(3) select argv accepted an unsafe name: [$got]"
# An unknown driver (no roster bindings at all) degrades to inject, never a crash.
got="$(HERD_DRIVER=not-a-driver roster_sh 'herd_roster_mode')"
[ "$got" = "inject" ] || fail "(3) unknown driver mode = [$got], expected inject"
pass; echo "PASS (3) @degrade reads as absent → inject fallback; a real selector composes --agent <name>"

# ── 4. per-driver definition-dir resolution: repo scope vs user scope. ────────────────────────────
got="$(HERD_DRIVER=herdr-claude roster_sh 'herd_roster_definition_dir')"
[ "$got" = "$T/proj/.claude/agents" ] \
  || fail "(4) claude definition dir = [$got], expected repo-scope $T/proj/.claude/agents"
_ROSTER_ENV=(HERD_AGENT_DEFINITION_ROOT="$T/home")
got="$(HERD_DRIVER=grok roster_sh 'herd_roster_definition_dir')"
[ "$got" = "$T/home/.grok/agents" ] \
  || fail "(4) grok definition dir = [$got], expected user-scope $T/home/.grok/agents"
got="$(HERD_DRIVER=stub roster_sh 'herd_roster_definition_dir')"
[ "$got" = "$T/home/.stub-agent/agents" ] || fail "(4) stub definition dir = [$got]"
_ROSTER_ENV=()
# codex binds @degrade for the dir → no lookup path at all.
got="$(HERD_DRIVER=codex roster_sh 'herd_roster_definition_dir')"
[ -z "$got" ] || fail "(4) codex reported a definition dir it does not have: [$got]"
# A binding carrying a command substitution is REFUSED rather than evaluated.
got="$(roster_sh "_herd_roster_expand '/tmp/\$(touch $T/pwned)/agents'")"
[ -z "$got" ] || fail "(4) expansion did not refuse a command-substitution binding: [$got]"
[ -e "$T/pwned" ] && fail "(4) expansion EXECUTED a command substitution"
pass; echo "PASS (4) definition-dir resolution — repo scope, user scope, none, and a refused expansion"

# ── 5. install publishes the committed source into the runtime's OWN lookup path (trap T1). ───────
_ROSTER_ENV=(HERD_AGENT_DEFINITION_ROOT="$T/home")
out="$(HERD_DRIVER=stub roster_sh 'herd_roster_install stub')" || fail "(5) install exited non-zero: $out"
[ -f "$T/home/.stub-agent/agents/testing.md" ] || fail "(5) install did not publish into the lookup path"
cmp -s "$ROSTER/testing.md" "$T/home/.stub-agent/agents/testing.md" \
  || fail "(5) published copy differs from the committed source"
_ROSTER_ENV=()
# mode=inject has nowhere to publish: a clean, explicit no-op, never an error.
out="$(HERD_DRIVER=codex roster_sh 'herd_roster_install codex')" || fail "(5) inject-mode install exited non-zero"
case "$out" in *"no definition lookup path"*) : ;; *) fail "(5) inject-mode install did not report a no-op: $out" ;; esac
pass; echo "PASS (5) install publishes to the driver's real lookup path; a no-lookup driver is a clean no-op"

# ── fake runtimes: the stub driver's runtime is `stub-agent`, so a fake on PATH IS the runtime. ────
mkdir -p "$T/bin"
# (a) RESOLVING: honors --agent by reading the published definition — a runtime that works.
cat > "$T/bin/stub-agent" <<'EOS'
#!/usr/bin/env bash
name=""
while [ $# -gt 0 ]; do
  case "$1" in --agent) name="${2:-}"; shift 2 || shift ;; *) shift ;; esac
done
f="$FAKE_AGENT_DIR/$name.md"
if [ -n "$name" ] && [ -f "$f" ]; then
  awk '/^sentinel:[[:space:]]*/ { sub(/^sentinel:[[:space:]]*/, ""); print; exit }' "$f"
else
  echo NO-SENTINEL
fi
EOS
chmod +x "$T/bin/stub-agent"
# (b) IGNORING: accepts --agent and silently runs as a plain agent — trap T2, verbatim.
cat > "$T/bin/stub-agent-ignore" <<'EOS'
#!/usr/bin/env bash
echo "I am a plain agent with no special instructions."
EOS
chmod +x "$T/bin/stub-agent-ignore"
# (c) ALWAYS: echoes the sentinel no matter what was selected — a probe that cannot discriminate.
cat > "$T/bin/stub-agent-always" <<'EOS'
#!/usr/bin/env bash
printf '%s\n' "$FAKE_SENTINEL"
EOS
chmod +x "$T/bin/stub-agent-always"

verify_with() {   # verify_with <fake-binary> <extra-env…> → prints "<verdict>|<output>"
  local fake="$1"; shift
  mkdir -p "$T/runbin"; cp "$T/bin/$fake" "$T/runbin/stub-agent"
  env -u HERD_AGENT -u HERD_CLAUDE_FLAGS -u MODEL_QUICK \
      PATH="$T/runbin:$PATH" HERD_DRIVER=stub HERD_AGENTS_DIR="$ROSTER" \
      PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
      HERD_AGENT_DEFINITION_ROOT="$T/home" \
      FAKE_AGENT_DIR="$T/home/.stub-agent/agents" FAKE_SENTINEL="$SENTINEL" "$@" \
      bash -c 'set -uo pipefail; . "$1"; . "$2"
               herd_roster_verify testing > "$3"
               printf "%s|%s" "$HERD_ROSTER_VERDICT" "$(cat "$3")"' _ "$DRIVER_SH" "$AGENTS_SH" "$T/verify.out"
}

# ── 6. POSITIVE + NEGATIVE control both behave → ok. ──────────────────────────────────────────────
rm -f "$T/pool/.herd-agent-verify"
got="$(verify_with stub-agent)"
[ "${got%%|*}" = "ok" ] || fail "(6) resolving runtime verdict = [${got%%|*}] (out: ${got#*|})"
pass; echo "PASS (6) verify: a runtime that really resolves the definition → ok"

# ── 7. TRAP T2: a runtime that silently ignores the name → unresolved, NOT a pass. ────────────────
rm -f "$T/pool/.herd-agent-verify"
got="$(verify_with stub-agent-ignore)"
[ "${got%%|*}" = "unresolved" ] || fail "(7) silent-fallback runtime verdict = [${got%%|*}] (out: ${got#*|})"
case "${got#*|}" in *"silent-fallback"*) : ;; *) fail "(7) unresolved note does not name the trap: ${got#*|}" ;; esac
pass; echo "PASS (7) verify: a runtime that SILENTLY IGNORES the name → unresolved (trap T2 caught)"

# ── 8. A probe that cannot fail is reported as proving nothing, never as ok. ──────────────────────
rm -f "$T/pool/.herd-agent-verify"
got="$(verify_with stub-agent-always)"
[ "${got%%|*}" = "indeterminate" ] \
  || fail "(8) negative-control-also-passes verdict = [${got%%|*}] (out: ${got#*|})"
pass; echo "PASS (8) verify: negative control also passing → indeterminate (the check must be able to fail)"

# ── 9. An absent runtime binary is 'unverified' with a clear note — never a red row. ──────────────
rm -f "$T/pool/.herd-agent-verify"
got="$(env -u HERD_AGENT -u MODEL_QUICK \
        HERD_DRIVER=stub HERD_AGENTS_DIR="$ROSTER" PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
        /bin/bash -c 'set -uo pipefail; . "$1"; . "$2"
                      herd_roster_verify testing > "$3"
                      printf "%s|%s" "$HERD_ROSTER_VERDICT" "$(cat "$3")"' _ "$DRIVER_SH" "$AGENTS_SH" "$T/verify.out")"
[ "${got%%|*}" = "unverified" ] || fail "(9) absent-binary verdict = [${got%%|*}] (out: ${got#*|})"
case "${got#*|}" in *"not present"*) : ;; *) fail "(9) unverified note is not actionable: ${got#*|}" ;; esac
# A definition with no sentinel can assert nothing empirically, and says so.
cat > "$ROSTER/nosent.md" <<'EOF'
---
name: nosent
description: no sentinel declared
---

body
EOF
got="$(roster_sh 'herd_roster_verify nosent >/dev/null; printf "%s" "$HERD_ROSTER_VERDICT"')"
[ "$got" = "no-sentinel" ] || fail "(9) sentinel-less definition verdict = [$got]"
rm -f "$ROSTER/nosent.md"
pass; echo "PASS (9) absent runtime → unverified; sentinel-less definition → no-sentinel (both fail-soft)"

# ── 9b. the verdict cache is keyed by (driver, definition sha): an EDIT invalidates its own row. ──
rm -f "$T/pool/.herd-agent-verify"
verify_with stub-agent >/dev/null
got="$(HERD_DRIVER=stub roster_sh 'sha="$(herd_roster_sha "$HERD_AGENTS_DIR/testing.md")"
       herd_roster_cache_get stub testing "$sha"')"
case "$got" in ok*) : ;; *) fail "(9b) cache did not return the ok verdict: [$got]" ;; esac
printf '\nan edit that changes the definition.\n' >> "$ROSTER/testing.md"
got="$(HERD_DRIVER=stub roster_sh 'sha="$(herd_roster_sha "$HERD_AGENTS_DIR/testing.md")"
       herd_roster_cache_get stub testing "$sha"')"
[ -z "$got" ] || fail "(9b) edited definition still resolved to a cached verdict: [$got]"
# A verdict for a DIFFERENT driver never satisfies this driver's key either.
got="$(HERD_DRIVER=stub roster_sh 'sha="$(herd_roster_sha "$HERD_AGENTS_DIR/testing.md")"
       herd_roster_cache_put stub testing "$sha" ok note
       herd_roster_cache_get grok testing "$sha"')"
[ -z "$got" ] || fail "(9b) a stub verdict satisfied the grok key: [$got]"
pass; echo "PASS (9b) verdict cache is keyed by (driver, definition sha) — an edit invalidates it"

# ── 10. THE LEVER INVARIANT: HERD_AGENT unset ⇒ byte-identical spawn argv AND task spec. ──────────
# Mirrors the lanes exactly: derive the permission flags from the resolved driver, append the roster's
# select flags, compose the spawn argv; and concatenate the task spec with the roster's spec block.
lane_probe='
lane_argv() {
  local drv="$1" agent="$2" mdl flags sel
  mdl="$(herd_model_for_spawn "" )" || true
  flags="$(herd_driver_lane_permission_flags "$drv")"
  sel=""
  if [ -n "$agent" ]; then sel="$(herd_roster_lane_select_flags "$agent" "$drv")"; fi
  if [ -n "$sel" ]; then flags="$flags $sel"; fi
  local -a a=(); local t
  while IFS= read -r -d "" t; do a+=("$t"); done < <(herd_driver_agent_spawn_argv "$drv" "m1" "$flags" PTR)
  printf "%s" "${a[*]}"
}
lane_spec() {
  local drv="$1" agent="$2" blk=""
  if [ -n "$agent" ]; then blk="$(herd_roster_lane_spec_block "$agent" "$drv")"; fi
  printf "RULES%s\n\nTASK" "$blk"
}
'
for d in herdr-claude headless codex grok stub; do
  base="$(HERD_DRIVER="$d" roster_sh "$lane_probe"' lane_argv '"$d"' ""')"
  # A tree with NO roster at all must compose the same argv as a tree WITH one and HERD_AGENT unset.
  none="$(env -u HERD_DRIVER -u HERD_AGENT -u HERD_CLAUDE_FLAGS HERD_AGENTS_DIR="$T/empty-roster" \
            PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
            bash -c 'set -uo pipefail; . "$1"; . "$2"; shift 2; eval "$@"' _ "$DRIVER_SH" "$AGENTS_SH" -- \
            "$lane_probe lane_argv $d \"\"")"
  [ "$base" = "$none" ] || fail "(10) $d argv differs with/without a roster when HERD_AGENT is unset"
  case "$base" in *--agent*) fail "(10) $d composed a select flag with HERD_AGENT unset: $base" ;; esac
  spec="$(HERD_DRIVER="$d" roster_sh "$lane_probe"' lane_spec '"$d"' ""')"
  [ "$spec" = "$(printf 'RULES\n\nTASK')" ] || fail "(10) $d task spec is not byte-identical with HERD_AGENT unset"
done
pass; echo "PASS (10) HERD_AGENT unset → byte-identical spawn argv and task spec on every shipped driver"

# ── 11. HERD_AGENT set: exactly ONE mechanism engages, and it is the right one per runtime. ───────
# A select-flag runtime gets the flag in the argv and NOTHING in the spec; an inject runtime gets the
# definition body in the spec and NOTHING in the argv. Never both, never neither.
got="$(HERD_DRIVER=stub roster_sh "$lane_probe"' lane_argv stub testing')"
case "$got" in *"--agent testing"*) : ;; *) fail "(11) stub argv missing the select flag: $got" ;; esac
got="$(HERD_DRIVER=stub roster_sh "$lane_probe"' lane_spec stub testing')"
[ "$got" = "$(printf 'RULES\n\nTASK')" ] || fail "(11) stub (a select-flag runtime) ALSO injected the body"
got="$(HERD_DRIVER=codex roster_sh "$lane_probe"' lane_argv codex testing')"
case "$got" in *--agent*) fail "(11) codex argv grew a select flag it has no binding for: $got" ;; esac
got="$(HERD_DRIVER=codex roster_sh "$lane_probe"' lane_spec codex testing')"
case "$got" in
  *"specialist agent: testing"*"testing specialist"*) : ;;
  *) fail "(11) codex did not inject the definition body into the task spec: $got" ;;
esac
# An UNKNOWN name engages neither mechanism (and the lane warns loudly — checked below).
got="$(HERD_DRIVER=stub roster_sh "$lane_probe"' lane_argv stub no-such-agent')"
case "$got" in *--agent*) fail "(11) an unknown name composed a select flag: $got" ;; esac
got="$(HERD_DRIVER=codex roster_sh "$lane_probe"' lane_spec codex no-such-agent')"
[ "$got" = "$(printf 'RULES\n\nTASK')" ] || fail "(11) an unknown name injected something into the spec"
pass; echo "PASS (11) HERD_AGENT set → exactly one mechanism engages, matched to the runtime"

# ── 12. An unresolved / unknown name WARNS LOUDLY but never blocks. ───────────────────────────────
out="$(HERD_DRIVER=stub roster_sh 'herd_roster_lane_warn no-such-agent stub' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(12) lane warn returned non-zero (it must never block a spawn)"
case "$out" in *"no definition"*) : ;; *) fail "(12) unknown name produced no warning: [$out]" ;; esac
out="$(HERD_DRIVER=stub roster_sh '
        sha="$(herd_roster_sha "$HERD_AGENTS_DIR/testing.md")"
        herd_roster_cache_put stub testing "$sha" unresolved "the runtime ignored it"
        herd_roster_lane_warn testing stub' 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(12) lane warn returned non-zero for an unresolved verdict"
case "$out" in *unresolved*) : ;; *) fail "(12) unresolved verdict produced no warning: [$out]" ;; esac
# An OK verdict is silent — a warning that fires on every spawn trains everyone to ignore it.
out="$(HERD_DRIVER=stub roster_sh '
        sha="$(herd_roster_sha "$HERD_AGENTS_DIR/testing.md")"
        herd_roster_cache_put stub testing "$sha" ok fine
        herd_roster_lane_warn testing stub' 2>&1)"
[ -z "$out" ] || fail "(12) an ok verdict still warned: [$out]"
pass; echo "PASS (12) an unresolved/unknown name warns loudly, returns 0, and an ok verdict is silent"

# ── 13. the LANES and the QUEUE are actually wired (structural — the seams exist where claimed). ──
for lane in herd-feature.sh herd-quick.sh; do
  f="$ROOT/scripts/herd/$lane"
  "$GREP" -q 'agents\.sh' "$f" || fail "(13) $lane does not source agents.sh"
  "$GREP" -q 'herd_roster_lane_select_flags' "$f" || fail "(13) $lane does not append the select flags"
  "$GREP" -q 'herd_roster_lane_spec_block' "$f" || fail "(13) $lane does not inject the spec block"
  "$GREP" -q 'herd_roster_lane_warn' "$f" || fail "(13) $lane does not warn on an unresolved agent"
  # BOTH seams must be guarded by HERD_AGENT, or the lever is not really off when it is off.
  "$GREP" -q 'if \[ -n "\${HERD_AGENT:-}" \]' "$f" || fail "(13) $lane does not guard the seams on HERD_AGENT"
done
"$GREP" -q 'INTENT_ID.agent' "$ROOT/scripts/herd/spawn.sh" \
  || fail "(13) spawn.sh does not record the agent sidecar"
"$GREP" -q 'agent' <<< "$("$GREP" -E '^IQ_SIDECARS=' "$ROOT/scripts/herd/intent-queue.sh")" \
  || fail "(13) the .agent sidecar is not GC'd with its intent (IQ_SIDECARS)"
"$GREP" -q '_drain_lane_agent' "$ROOT/scripts/herd/agent-watch.sh" \
  || fail "(13) the watcher drain does not read the agent sidecar"
"$GREP" -q 'export HERD_AGENT=' "$ROOT/scripts/herd/agent-watch.sh" \
  || fail "(13) the watcher drain does not re-export HERD_AGENT to the lane"
pass; echo "PASS (13) lanes source + guard the roster seams; the queue threads .agent through the drain"

# ── 14. the drain's sidecar read re-validates the name (a queue file is untrusted input). ─────────
# Extract the function alone — the same hermetic-extraction shape the other drain tests use.
drain_fn="$(awk '/^_drain_lane_agent\(\) \{/,/^\}/' "$ROOT/scripts/herd/agent-watch.sh")"
[ -n "$drain_fn" ] || fail "(14) could not extract _drain_lane_agent"
mkdir -p "$T/q"
printf 'testing\n' > "$T/q/i1.agent"; : > "$T/q/i1.req.mine"
got="$(bash -c 'set -uo pipefail; '"$drain_fn"'; _drain_lane_agent "$1"' _ "$T/q/i1.req.mine")"
[ "$got" = "testing" ] || fail "(14) drain did not read a valid sidecar: [$got]"
printf -- '--dangerously-skip-permissions\n' > "$T/q/i2.agent"; : > "$T/q/i2.req.mine"
got="$(bash -c 'set -uo pipefail; '"$drain_fn"'; _drain_lane_agent "$1"' _ "$T/q/i2.req.mine")"
[ -z "$got" ] || fail "(14) drain accepted an argv-shaped sidecar value: [$got]"
: > "$T/q/i3.req.mine"
got="$(bash -c 'set -uo pipefail; '"$drain_fn"'; _drain_lane_agent "$1"' _ "$T/q/i3.req.mine")"
[ -z "$got" ] || fail "(14) drain invented an agent for an intent with no sidecar: [$got]"
pass; echo "PASS (14) the drain re-validates the .agent sidecar and reads empty for an ordinary intent"

# ── 15. list / show / scaffold, and the doctor leg reads the CACHE (it never spawns). ─────────────
out="$(HERD_DRIVER=stub roster_sh 'herd_roster_list')"
case "$out" in *testing*) : ;; *) fail "(15) list did not show the roster entry: $out" ;; esac
case "$out" in *"definition-mode: install"*) : ;; *) fail "(15) list did not report the definition mode: $out" ;; esac
out="$(roster_sh 'herd_roster_show testing')"
case "$out" in *"$SENTINEL"*) : ;; *) fail "(15) show did not print the definition" ;; esac
roster_sh 'herd_roster_show no-such-agent' >/dev/null 2>&1 && fail "(15) show of an unknown name exited 0"
NEWROSTER="$T/newroster"
out="$(env -u HERD_DRIVER HERD_AGENTS_DIR="$NEWROSTER" PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
        bash -c 'set -uo pipefail; . "$1"; . "$2"; herd_roster_scaffold fresh' _ "$DRIVER_SH" "$AGENTS_SH")" \
  || fail "(15) scaffold failed: $out"
[ -f "$NEWROSTER/fresh.md" ] || fail "(15) scaffold wrote no definition"
"$GREP" -q '^name: fresh' "$NEWROSTER/fresh.md" || fail "(15) scaffold did not substitute the name"
"$GREP" -qE '^sentinel: HERD-AGENT-fresh-[0-9]+' "$NEWROSTER/fresh.md" \
  || fail "(15) scaffold did not write a unique sentinel (the definition would be unverifiable)"
"$GREP" -q '{{' "$NEWROSTER/fresh.md" && fail "(15) scaffold left an unsubstituted {{token}}"
env -u HERD_DRIVER HERD_AGENTS_DIR="$NEWROSTER" PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
  bash -c 'set -uo pipefail; . "$1"; . "$2"; herd_roster_scaffold fresh' _ "$DRIVER_SH" "$AGENTS_SH" \
  >/dev/null 2>&1 && fail "(15) scaffold overwrote an existing definition"
# doctor's roster leg: advisory, always 0, and readable from the cache with NO runtime on PATH.
out="$(env -u HERD_AGENT HERD_DRIVER=stub \
         HERD_AGENTS_DIR="$ROSTER" PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
         /bin/bash -c 'set -uo pipefail; . "$1"; . "$2"; herd_roster_doctor_section; echo "RC=$?"' \
         _ "$DRIVER_SH" "$AGENTS_SH")"
case "$out" in *"RC=0"*) : ;; *) fail "(15) doctor roster leg did not exit 0: $out" ;; esac
case "$out" in *testing*) : ;; *) fail "(15) doctor roster leg did not report the entry: $out" ;; esac
# ...and it is byte-inert when the project has no roster at all.
out="$(env -u HERD_AGENT HERD_AGENTS_DIR="$T/empty-roster" PROJECT_ROOT="$T/proj" WORKTREES_DIR="$T/pool" \
         bash -c 'set -uo pipefail; . "$1"; . "$2"; herd_roster_doctor_section' _ "$DRIVER_SH" "$AGENTS_SH")"
[ -z "$out" ] || fail "(15) doctor roster leg is not byte-inert without a roster: [$out]"
pass; echo "PASS (15) list/show/new behave; the doctor leg is advisory, cache-only and byte-inert when empty"

echo "ALL PASS ($PASS checks)"
