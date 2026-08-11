#!/usr/bin/env bash
# tests/lib/await-file-contains.sh — the ONE shared bounded-await helper for the fork-latency flake
# class (HERD-635; the class itself was root-caused in commit f08271b / HERD-630, see the note it left
# in tests/test-delta-review.sh before this sweep folded it into here).
#
# THE RACE: scripts/herd/agent-watch.sh backgrounds work through two seams — `_bg_new_session` (an
# external argv, via setsid) and `_spawn_inflight_bg` (an in-process bash function, via a plain `&`
# subshell) — and both seams WRITE THE MARKER AND RETURN as soon as the fork is recorded, before the
# child has necessarily been scheduled to run its first statement. Any test that dispatches through one
# of these seams (directly, or via a wrapper like `_dispatch_review` / `_review_gate_step`) and then
# immediately reads a CHILD-produced artifact — a stub's spawn log, a model-selection log, a review
# result file, a marker the child itself writes — is racing fork+exec latency, not the code under test.
# That race is invisible on an idle laptop and loses reliably on a loaded multi-way CI shard (confirmed:
# PR #742's ubuntu 3/6 shard, reproduced deterministically by delaying the stub's first statement 0.3s).
#
# THE FIX IS THE PROBE'S INVARIANT, NOT A RETRY OF THE CORRECTNESS CHECK (the health_serialized
# lesson): the assertion a caller wants is "the child DID this", and the honest observable for that is
# the artifact's content ARRIVING, not it having arrived within one scheduler quantum. A child that
# genuinely never writes still fails — it just takes the full ceiling to say so. A test's own
# SYNCHRONOUS observables (a dispatcher's echoed token, a marker the PARENT writes before returning)
# are never subject to this race and must not be routed through this helper — only a CHILD's side
# effect needs it.
#
# await_file_contains <file> <extended-regex> [ceiling-ticks=200] [interval-seconds=0.05]
#   Polls (bounded) until <file> exists and `grep -qE <extended-regex>` matches it. Returns 0 the
#   instant it matches; returns 1 once <ceiling-ticks> ticks have elapsed with no match. Defaults to a
#   200 x 0.05s = 10s ceiling, the same window HERD-630's original await_dispatch proved sufficient.
#   To await mere non-emptiness (the `[ -s file ]` shape), pass '.' as the pattern; to await an exact
#   blank line (the `grep -qx ''` shape), pass '^$'.
await_file_contains() {
  local _afc_file="$1" _afc_re="$2" _afc_ceiling="${3:-200}" _afc_interval="${4:-0.05}" _afc_n=0
  while [ "$_afc_n" -lt "$_afc_ceiling" ]; do
    grep -qE "$_afc_re" "$_afc_file" 2>/dev/null && return 0
    sleep "$_afc_interval"
    _afc_n=$(( _afc_n + 1 ))
  done
  return 1
}
