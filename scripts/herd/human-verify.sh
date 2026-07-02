#!/usr/bin/env bash
# human-verify.sh — the shared parser for the per-PR HUMAN-VERIFY hold convention.
#
# A builder that opens a PR but could NOT itself run a required manual step (a live smoke test, a
# UI/pane check, anything needing a running app or human eyes) declares each such step in the PR
# body under a `HUMAN-VERIFY:` marker, one step per line:
#
#   HUMAN-VERIFY:
#   - run coordinator.sh and confirm .herd-panes appears
#   - reload and confirm the panes refresh
#
# The watcher (agent-watch.sh) parses open PR bodies for this block: a PR that declares one switches
# from auto-merge to an approve-style hold — every gate still runs, but the merge WAITS on a
# sha-keyed approval (herd-approve.sh approve <pr#>), REUSING the MERGE_POLICY=approve ledger. This
# file is the single source of truth for what the block looks like, sourced (never executed) by both
# agent-watch.sh (presence) and herd-approve.sh (surfacing the steps to the operator).
#
# Sourced AFTER herd-config.sh, exactly like journal.sh:
#   . "$HERE/human-verify.sh"
#
# Parse contract:
#   • The block opens at the first line whose text (after optional markdown bullet/heading/bold
#     decoration) is `HUMAN-VERIFY:` — case-insensitive. Any text after the colon on that same line
#     is treated as the first step (supports the one-liner `HUMAN-VERIFY: <single step>` form).
#   • Following non-blank lines are additional steps, until the first blank line or end of body.
#   • Each step is de-bulleted (`- `, `* `, `+ `, `1.`, `1)`) and whitespace-trimmed; empties drop.
#   • A bare marker with NO steps is NOT a hold — there is nothing for a human to verify, so it must
#     never trip the gate. human_verify_has returns false in that case.

# human_verify_steps — read a PR body on stdin; print the declared steps, one per line (nothing when
# the body has no HUMAN-VERIFY block or the block lists no steps). Best-effort: any failure prints
# nothing rather than erroring, so a caller under strict mode is never broken.
human_verify_steps() {
  python3 -c '
import sys, re
lines = sys.stdin.read().splitlines()
# Marker: optional leading bullet/heading/bold decoration, then HUMAN-VERIFY:, then the rest.
marker = re.compile(r"^[\s>*#`]*HUMAN-VERIFY\s*:\s*(.*)$", re.IGNORECASE)
bullet = re.compile(r"^\s*(?:[-*+]\s+|\d+[.)]\s+)")
def clean(s):
    s = s.strip()
    s = bullet.sub("", s).strip()
    return s
steps = []
n = len(lines)
for i in range(n):
    m = marker.match(lines[i])
    if not m:
        continue
    rest = m.group(1).strip().strip("*").strip()   # drop trailing **bold** wrapping on the marker
    if rest:
        c = clean(rest)
        if c:
            steps.append(c)
    j = i + 1
    while j < n and lines[j].strip() != "":
        c = clean(lines[j])
        if c:
            steps.append(c)
        j += 1
    break
for s in steps:
    print(s)
' 2>/dev/null || true
}

# human_verify_has — read a PR body on stdin; return 0 iff it declares a NON-EMPTY HUMAN-VERIFY
# block (at least one step). A bare marker with no steps returns non-zero (not a hold).
human_verify_has() {
  local _hv_out
  _hv_out="$(human_verify_steps)"
  [ -n "$_hv_out" ]
}
