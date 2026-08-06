#!/usr/bin/env bash
# test-sim-journal-hermeticity.sh — hermetic-suite guard (HERD-562): no scripts/herd/sim/*.sh may
# reach the LIVE project journal.
#
# THE LEAK THIS CATCHES. retirement-invariant-sim.sh sources agent-watch.sh in LIB mode
# (AGENT_WATCH_LIB=1) and drives retirement_tick with HERD_CONFIG_FILE pointed at a deliberately
# absent "$scn/no-config" (the documented sim convention in herd-config.sh's "hermetic test/sim seam"
# comment). With no config file to source, WORKTREES_DIR fell through to herd-config.sh's
# REPO-DEFAULT fallback — the real tree the sim happened to be checked out in — because, unlike every
# sibling sim in this directory, it never pinned JOURNAL_FILE. Its SLUG=retiree fixture then landed
# real reap/merge events for that slug in the LIVE project journal, and journal-audit.sh's
# known-fixture-slug check found them there days later and filed a tracker item about it
# (audit_acted class=fixture_slug key=fixture_slug|retiree) — a fixture leaking into production
# through the one seam (HERD-223's journal-hermeticity guard) that only protects processes carrying a
# HERMETIC_TEST-class signal, which a bare `bash scripts/herd/sim/*.sh` run never sets.
#
# tests/test-journal-hermeticity.sh already proves the LIBRARY guard (journal.sh's fail-safe redirect)
# is correct in isolation. This file proves the OTHER half: that every sim script which can reach that
# library actually ARMS the guard (JOURNAL_FILE, or one of the HERMETIC_TEST-class signals) somewhere
# in the file — a static scan, so a NEW sim that reintroduces the pattern reds here before it ever gets
# the chance to pollute a real journal.
#
# Run:  bash tests/test-sim-journal-hermeticity.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SIM_DIR="$ROOT/scripts/herd/sim"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS + 1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"
[ -d "$SIM_DIR" ] || fail "scripts/herd/sim not found at $SIM_DIR"

# scan <dir> — print one violator basename per line: a *.sh file whose content can reach the journal
# (sources agent-watch.sh in LIB mode, sources journal.sh/retirement.sh directly, or calls
# journal_append) but never arms the journal-hermeticity guard anywhere in the file.
scan() {
  python3 - "$1" <<'PY'
import os, re, sys

sim_dir = sys.argv[1]
# A guard is anything that keeps journal.sh's _journal_file() off the herd-config.sh REPO-DEFAULT
# fallback: JOURNAL_FILE (the direct override), one of the HERMETIC_TEST-class signals _journal_file()
# checks itself, or WORKTREES_DIR set directly by the sim (sandbox-*-scenario.sh's own convention —
# _journal_file() derives the journal path from WORKTREES_DIR before it ever reaches the fallback, so
# a sim that already pins WORKTREES_DIR to an isolated temp dir never exercises that fallback at all).
GUARD = ("JOURNAL_FILE=", "HERMETIC_TEST=", "HERD_HERMETIC_GUARD=", "HERD_JOURNAL_HERMETIC=",
         "WORKTREES_DIR=")
RISK_LIB = re.compile(r'\.\s+"[^"]*\b(?:journal|retirement)\.sh"')

violators = []
for fn in sorted(os.listdir(sim_dir)):
    if not fn.endswith(".sh"):
        continue
    path = os.path.join(sim_dir, fn)
    try:
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
    except OSError:
        continue
    risky = ("AGENT_WATCH_LIB=1" in text) or ("journal_append" in text) or RISK_LIB.search(text)
    if not risky:
        continue
    if any(sig in text for sig in GUARD):
        continue
    violators.append(fn)

for v in violators:
    print(v)
PY
}

# ── (1) the REAL tree is clean ───────────────────────────────────────────────
real_violators="$(scan "$SIM_DIR")"
[ -z "$real_violators" ] || fail "(1) scripts/herd/sim/*.sh reaching the journal without a hermeticity guard: $real_violators"
pass
echo "PASS (1) every scripts/herd/sim/*.sh that can reach the journal arms a hermeticity guard"

# ── (2) the scan itself: proven against synthetic fixtures ──────────────────
FIX="$T/sim"; mkdir -p "$FIX"

# leaky.sh: sources agent-watch.sh in LIB mode, no guard anywhere → MUST be flagged.
cat > "$FIX/leaky.sh" <<'SH'
#!/usr/bin/env bash
HERD_CONFIG_FILE="$scn/no-config" \
  AGENT_WATCH_LIB=1 bash -c '. "$WATCH_SH"; retirement_tick' _
SH

# clean.sh: same risk shape, but pins JOURNAL_FILE → must NOT be flagged.
cat > "$FIX/clean.sh" <<'SH'
#!/usr/bin/env bash
HERD_CONFIG_FILE="$scn/no-config" JOURNAL_FILE="$scn/journal.jsonl" \
  AGENT_WATCH_LIB=1 bash -c '. "$WATCH_SH"; retirement_tick' _
SH

# clean-via-hermetic-test.sh: guarded via the OTHER signal (HERMETIC_TEST) → must NOT be flagged.
cat > "$FIX/clean-via-hermetic-test.sh" <<'SH'
#!/usr/bin/env bash
HERD_CONFIG_FILE="$scn/no-config" HERMETIC_TEST="clean-via-hermetic-test.sh" \
  AGENT_WATCH_LIB=1 bash -c '. "$WATCH_SH"; retirement_tick' _
SH

# clean-via-worktrees-dir.sh: guarded by pinning WORKTREES_DIR directly (the sandbox-*-scenario.sh
# convention) → must NOT be flagged.
cat > "$FIX/clean-via-worktrees-dir.sh" <<'SH'
#!/usr/bin/env bash
export WORKTREES_DIR="$TREES"
export AGENT_WATCH_LIB=1
. "$WATCH_SH"
retirement_tick
SH

# harmless.sh: never reaches the journal at all (no AGENT_WATCH_LIB, no journal_append, no library
# source) → must NOT be flagged regardless of HERD_CONFIG_FILE shape.
cat > "$FIX/harmless.sh" <<'SH'
#!/usr/bin/env bash
HERD_CONFIG_FILE="$scn/no-config" echo "just a stub gh/herdr binary, never touches the journal"
SH

got="$(scan "$FIX")"
[ "$got" = "leaky.sh" ] || fail "(2) expected exactly 'leaky.sh' flagged, got: [$got]"
pass
echo "PASS (2) the scan flags an unguarded risky sim and clears guarded/harmless ones"

echo "ALL PASS ($PASS checks) — sim journal hermeticity (HERD-562)."
