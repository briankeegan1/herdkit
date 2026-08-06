#!/usr/bin/env bash
# test-sim-journal-hermeticity.sh — hermetic-suite guard (HERD-562/HERD-597): no scripts/herd/sim/*.sh
# or tests/*.sh may reach the LIVE project journal.
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
# THE SECOND LEAK (HERD-597) — the one check (1)/(2) below MISSED. tests/test-retirement-invariant.sh
# has the exact same shape (AGENT_WATCH_LIB=1 + an absent HERD_CONFIG_FILE), and DID eventually pin
# JOURNAL_FILE — just ~380 lines after its (11)/(13)/(15) cases already drove retirement_tick_one for
# slug=conv and slug=stuck. "does a guard signal appear ANYWHERE in the file" said clean; the real
# question is "does it appear before the first line that can reach the journal" — those two slugs
# landed real reap/retire_converged/retire_stuck events in the LIVE journal on 2026-08-04 and again on
# 2026-08-05. Check (3)/(4) below close that gap: for any file that drives a literal known-fixture slug
# (the journal-audit.sh HERD-223 pollution set: retiree/conv/stuck/hd) through AGENT_WATCH_LIB=1, a
# hermeticity guard appearing merely SOMEWHERE is not enough — it must appear BEFORE that risk point.
# This check is intentionally narrower than (1)/(2) (scoped to fixture-slug carriers, not every risky
# file): most tests/*.sh rely on the OFFICIAL runner (scripts/ci/run-suite.sh /
# .herd/healthcheck.project.sh) exporting HERMETIC_TEST before invoking them, which is a legitimate,
# well-established pattern this file must not blanket-red — the narrow, well-justified risk is
# specifically a fixture carrying a slug the live auditor is watching for.
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
TESTS_DIR="$ROOT/tests"

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

# scan_order <dir>... — print one "<dir>/<file>" violator per line: a *.sh file that drives a literal
# known-fixture slug (retiree/conv/stuck/hd — journal-audit.sh's HERD_JOURNAL_AUDIT_FIXTURE_SLUGS
# default) through AGENT_WATCH_LIB=1, where no hermeticity guard signal appears BEFORE that risk point
# (a guard appearing later, or only somewhere else in the file, does not count — see the file header).
scan_order() {
  python3 - "$@" <<'PY'
import os, re, sys

SLUG_RE = re.compile(r'(?:\bmkwt\s+|\bslug\s+|"slug"\s*:\s*")(retiree|conv|stuck|hd)\b')
RISK_RE = re.compile(r'AGENT_WATCH_LIB=1')
GUARD_RE = re.compile(r'\b(?:JOURNAL_FILE|HERMETIC_TEST|HERD_HERMETIC_GUARD|HERD_JOURNAL_HERMETIC|WORKTREES_DIR)=')

for d in sys.argv[1:]:
    if not os.path.isdir(d):
        continue
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".sh"):
            continue
        path = os.path.join(d, fn)
        try:
            with open(path, encoding="utf-8", errors="replace") as f:
                text = f.read()
        except OSError:
            continue
        if not SLUG_RE.search(text):
            continue                       # never drives a known-fixture slug — out of scope for (3)
        risk_m = RISK_RE.search(text)
        if not risk_m:
            continue                       # can't reach agent-watch.sh's journal seam at all
        guard_positions = [m.start() for m in GUARD_RE.finditer(text)]
        if not any(p < risk_m.start() for p in guard_positions):
            print("%s/%s" % (os.path.basename(d), fn))
PY
}

# ── (3) every fixture-slug carrier arms its guard BEFORE it can reach the journal (HERD-597) ──────
# THIS file is excluded from its own scan: the synthetic fixtures check (4) below writes are literal
# text inside single-quoted heredocs (never executed, never sourced) that deliberately contains both
# a known-fixture slug and the AGENT_WATCH_LIB=1 string to prove the scanner's positive/negative cases
# — matching them here would be the scanner flagging its own test data, not a real risk.
order_violators="$(scan_order "$SIM_DIR" "$TESTS_DIR" | grep -v '^tests/test-sim-journal-hermeticity\.sh$' || true)"
[ -z "$order_violators" ] || fail "(3) known-fixture-slug fixtures reach AGENT_WATCH_LIB=1 before arming a hermeticity guard: $order_violators"
pass
echo "PASS (3) every fixture-slug-carrying test/sim arms its hermeticity guard before it can reach the journal"

# ── (4) the order scan itself: proven against synthetic fixtures ────────────────────────────────
FIX2="$T/order"; mkdir -p "$FIX2"

# order-violator.sh: drives slug=conv through AGENT_WATCH_LIB=1, THEN pins JOURNAL_FILE (the exact
# tests/test-retirement-invariant.sh shape before this fix) → MUST be flagged.
cat > "$FIX2/order-violator.sh" <<'SH'
#!/usr/bin/env bash
HERD_CONFIG_FILE="$scn/no-config" AGENT_WATCH_LIB=1 bash -c '. "$WATCH_SH"; retirement_tick_one conv "$W/conv" feat/conv' _
JOURNAL_FILE="$scn/journal.jsonl"; : > "$JOURNAL_FILE"
mkwt conv
SH

# order-clean.sh: pins JOURNAL_FILE FIRST, then reaches AGENT_WATCH_LIB=1 with slug=stuck → must NOT
# be flagged (the fix this test file ships for tests/test-retirement-invariant.sh).
cat > "$FIX2/order-clean.sh" <<'SH'
#!/usr/bin/env bash
export JOURNAL_FILE="$T/journal.jsonl"
mkwt stuck
HERD_CONFIG_FILE="$scn/no-config" AGENT_WATCH_LIB=1 bash -c '. "$WATCH_SH"; retirement_tick_one stuck "$W/stuck" feat/stuck' _
SH

# order-clean-hermetic-test.sh: guarded via the OTHER signal (HERMETIC_TEST), also before the risk →
# must NOT be flagged.
cat > "$FIX2/order-clean-hermetic-test.sh" <<'SH'
#!/usr/bin/env bash
export HERMETIC_TEST="order-clean-hermetic-test.sh"
mkwt hd
AGENT_WATCH_LIB=1 bash -c '. "$WATCH_SH"; retirement_tick_one hd "$W/hd" feat/hd' _
SH

# no-fixture-slug.sh: reaches AGENT_WATCH_LIB=1 with NO guard anywhere, but never drives a
# known-fixture slug (an ordinary test's own slug names, e.g. "ok-slug") → out of scope for this
# NARROWER check, must NOT be flagged (checks (1)/(2) above are what would catch a *sim* like this;
# tests/*.sh in general are covered by the official runner's HERMETIC_TEST export, not this check).
cat > "$FIX2/no-fixture-slug.sh" <<'SH'
#!/usr/bin/env bash
AGENT_WATCH_LIB=1 bash -c '. "$WATCH_SH"; retirement_tick_one ok-slug "$W/ok-slug" feat/ok-slug' _
SH

got2="$(scan_order "$FIX2")"
want2="$(printf 'order/order-violator.sh\n')"
[ "$got2" = "$want2" ] || fail "(4) expected exactly 'order/order-violator.sh' flagged, got: [$got2]"
pass
echo "PASS (4) the order scan flags a guard-arrives-too-late fixture and clears guard-first/no-fixture-slug files"

echo "ALL PASS ($PASS checks) — sim + test journal hermeticity (HERD-562/HERD-597)."
