#!/usr/bin/env bash
# test-cli-approve.sh — hermetic test of the `herd approve` subcommand alias (HERD-200).
#
# The contract: `herd approve …` is a pure dispatch alias for scripts/herd/herd-approve.sh — it
# duplicates no approval logic, so its output must be byte-identical to invoking the script directly.
# The one shaping rule is that a first arg which is not one of the script's own verbs
# (list/approve/why/override) is treated as the argument of `approve` — that is the papercut
# (`herd approve 294` used to print the top-level help) this alias exists to fix.
#
# No network, no gh, no claude, no herdr. Run:  bash tests/test-cli-approve.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$HERE/.."
HERD="$ROOT/bin/herd"
APPROVE_SH="$ROOT/scripts/herd/herd-approve.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }

git -C "$T" init -q
git -C "$T" config user.email t@t.t; git -C "$T" config user.name t
( cd "$T" && git commit -q --allow-empty -m init )
( cd "$T" && HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init >/dev/null ) || fail "herd init failed"

# `gh` must never be reached on any path exercised here (no PR rows exist) — shadow it so a
# regression that starts shelling out to the network fails loudly instead of hanging.
mkdir -p "$T/bin"
printf '#!/bin/sh\necho "gh was invoked" >&2\nexit 127\n' > "$T/bin/gh"; chmod +x "$T/bin/gh"
export PATH="$T/bin:$PATH" NO_COLOR=1

# 1. `herd approve list` is byte-identical to the script's own `list` (the alias adds nothing).
( cd "$T" && bash "$HERD" approve list >"$T/via-cli.out" 2>"$T/via-cli.err" ); cli_rc=$?
( cd "$T" && bash "$APPROVE_SH" list   >"$T/direct.out" 2>"$T/direct.err" ); dir_rc=$?
[ "$cli_rc" -eq "$dir_rc" ] || fail "herd approve list exit $cli_rc != herd-approve.sh list exit $dir_rc"
diff -q "$T/via-cli.out" "$T/direct.out" >/dev/null || fail "herd approve list stdout differs from the script's"
diff -q "$T/via-cli.err" "$T/direct.err" >/dev/null || fail "herd approve list stderr differs from the script's"
grep -q "No PRs awaiting approval" "$T/via-cli.out" || fail "herd approve list did not render the empty-queue line"

# 2. bare `herd approve` (no args) falls through to the script's default verb, which is `list`.
( cd "$T" && bash "$HERD" approve >"$T/bare.out" 2>&1 )
diff -q "$T/bare.out" "$T/direct.out" >/dev/null || fail "bare 'herd approve' is not the script's default 'list'"

# 3. THE PAPERCUT: `herd approve <pr#>` reaches the script's `approve` verb — it must NOT print the
#    top-level herd help, and must say the same thing the explicit `approve <pr#>` path says.
( cd "$T" && bash "$HERD" approve 99999 >"$T/bare-pr.out" 2>&1 ); bare_rc=$?
( cd "$T" && bash "$APPROVE_SH" approve 99999 >"$T/direct-pr.out" 2>&1 ); dpr_rc=$?
[ "$bare_rc" -eq "$dpr_rc" ] || fail "herd approve 99999 exit $bare_rc != herd-approve.sh approve 99999 exit $dpr_rc"
diff -q "$T/bare-pr.out" "$T/direct-pr.out" >/dev/null || fail "herd approve 99999 differs from herd-approve.sh approve 99999"
grep -q "No awaiting approval record found for PR #99999" "$T/bare-pr.out" \
  || fail "herd approve 99999 did not reach the approve verb: $(cat "$T/bare-pr.out")"
grep -q "Engine scripts:" "$T/bare-pr.out" && fail "herd approve 99999 printed the top-level herd help"

# 4. an explicit verb is passed through verbatim (not re-wrapped in `approve`): `why`/`override`
#    with no argument surface the SCRIPT's usage line, not herd's.
( cd "$T" && bash "$HERD" approve why >"$T/why.out" 2>&1 ); why_rc=$?
[ "$why_rc" -ne 0 ] || fail "herd approve why (no pr#) should exit non-zero"
grep -q "Usage: herd-approve.sh why <pr#>" "$T/why.out" || fail "herd approve why did not passthrough to the script's why verb"

# 5. flags after a bare pr# survive the rewrite (--sha pins the approval to a reviewed commit).
( cd "$T" && bash "$HERD" approve 99999 --sha deadbeef >"$T/sha.out" 2>&1 )
( cd "$T" && bash "$APPROVE_SH" approve 99999 --sha deadbeef >"$T/sha-direct.out" 2>&1 )
diff -q "$T/sha.out" "$T/sha-direct.out" >/dev/null || fail "herd approve <pr#> --sha does not match the script's"

# 6. `herd approve --help` documents the alias without touching the ledgers.
( cd "$T" && bash "$HERD" approve --help >"$T/help.out" 2>&1 ) || fail "herd approve --help exited non-zero"
grep -q "usage: herd approve" "$T/help.out" || fail "herd approve --help missing usage line"

# 7. the alias is reachable from `herd help` (discoverability is the whole point).
bash "$HERD" help 2>&1 | grep -q "herd approve" || fail "herd help does not list 'herd approve'"

echo "ALL PASS"
