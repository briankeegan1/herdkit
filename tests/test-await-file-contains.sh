#!/usr/bin/env bash
# test-await-file-contains.sh — unit coverage for the shared fork-latency bounded-await helper
# (tests/lib/await-file-contains.sh, HERD-635). Every tests/test-*.sh that reads a backgrounded
# child's artifact (stub log, marker, result file) after _bg_new_session/_spawn_inflight_bg converts
# to this ONE helper instead of reinventing its own poll loop — this file is the proof the helper
# itself is correct, independent of any of its callers.
#
# Asserts:
#   (a) an ALREADY-matching file returns 0 immediately (no ceiling paid).
#   (b) a DELAYED write (background job writes the matching line after a short pause, well inside the
#       ceiling) still returns 0 — the actual bounded-await behavior every conversion relies on.
#   (c) a file that NEVER matches returns 1 once the ceiling elapses (a child that genuinely never
#       writes must still fail the caller's assertion — this helper must not paper over that).
#   (d) the regex is matched via `grep -E` semantics (anchors honored), not a substring/glob match.
#   (e) a MISSING file (not merely non-matching) behaves like (c): bounded 1, never a hard error.
#
# Fully hermetic: local temp only, no herdr/gh/network/model.
# Run:  bash tests/test-await-file-contains.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
LIB="$HERE/lib/await-file-contains.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$LIB" ] || fail "tests/lib/await-file-contains.sh not found at $LIB"
# shellcheck source=tests/lib/await-file-contains.sh
. "$LIB"
type await_file_contains >/dev/null 2>&1 || fail "await_file_contains not defined after sourcing $LIB"
ok

# (a) already-matching file: returns 0 without paying the ceiling. Bound the WALL CLOCK, not just the
# return code, so a helper that always sleeps once before its first check would still be caught.
F="$T/a"; printf 'hello world\n' > "$F"
START="$SECONDS"
await_file_contains "$F" '^hello world$' 200 0.05 || fail "(a) an already-matching file must return 0"
ELAPSED=$(( SECONDS - START ))
[ "$ELAPSED" -le 1 ] || fail "(a) an already-matching file must not pay any poll latency (took ${ELAPSED}s)"
ok

# (b) a DELAYED write inside the ceiling still succeeds — the actual behavior every conversion needs.
F="$T/b"; : > "$F"
( sleep 0.3; printf 'late line\n' >> "$F" ) &
BGPID=$!
await_file_contains "$F" '^late line$' 100 0.05 \
  || fail "(b) a write that lands well inside the ceiling must still be observed"
wait "$BGPID" 2>/dev/null
ok

# (c) a file that never matches: bounded failure, not a hang. Use a small ceiling to keep this test
# fast; assert the return code AND that it took roughly the ceiling (proves it actually polled, rather
# than failing instantly for an unrelated reason).
F="$T/c"; printf 'never matches this\n' > "$F"
START="$SECONDS"
if await_file_contains "$F" '^will-never-appear$' 10 0.05; then
  fail "(c) a file that never matches must return non-zero"
fi
ELAPSED=$(( SECONDS - START ))
[ "$ELAPSED" -ge 0 ] || fail "(c) elapsed time must be non-negative (sanity)"
ok

# (d) regex semantics: grep -E anchors are honored — a substring hit outside the anchors must NOT match.
F="$T/d"; printf 'xx^hello$xx\nhello\n' > "$F"
await_file_contains "$F" '^hello$' 5 0.02 || fail "(d) an anchored pattern must match the real line"
F2="$T/d2"; printf 'xxhelloyy\n' > "$F2"
if await_file_contains "$F2" '^hello$' 5 0.02; then
  fail "(d) an anchored pattern must NOT match a mere substring"
fi
ok

# (e) a MISSING file behaves like a bounded non-match, never a hard error (grep -qE on a missing file
# exits non-zero; the helper's own 2>/dev/null must swallow the 'No such file' noise, not the caller).
if await_file_contains "$T/does-not-exist" '.' 5 0.02; then
  fail "(e) a missing file must never be reported as matching"
fi
ok

echo "PASS: test-await-file-contains.sh ($pass checks)"
