#!/usr/bin/env bash
# lever-reachability-lint.sh — THE shared INERT-LEVER guard (HERD-556): a config key documented in
# templates/capabilities.tsv must have at least one consumer the shipped engine can actually REACH.
#
# THE BUG CLASS, proven live (2026-08-05, builder health-pane-reconcile sweep):
#
#   • `HEALTH_PANE` (HERD-313) and `HEALTH_TRUST_BUILDER` (HERD-531) were both silently NO-OPS. The
#     keys existed, herd-config.sh defaulted them, capabilities.tsv described them, `herd config set`
#     accepted them, tests asserted their on/off semantics — and turning them on changed NOTHING,
#     because their only behavioral consumers sat inside `_healthcheck_gate`, a bash function that has
#     been DEFINED-BUT-NEVER-CALLED since the P5b engine port (HERD-306) moved dispatch into
#     pysrc/herd/live_runtime.py. Nothing else on the tree could see it: the key was set, the default
#     was right, the unit tests passed, and the lever was inert.
#
# This is the AMPLIFIER of every other config risk — a mis-set or inert lever is how the other
# incidents actually present — and fixing it one key at a time is whack-a-mole (HEALTH_PANE was fixed
# by HERD-554 for exactly one key). It is also herdkit's dominant defect SHAPE stated in one line: a
# rail that reports clean because the thing it depends on is not where it is looking. Same family as
# the caps-sync / doc-drift / gate-coverage / journal-emission / env-export guards below it.
#
# WHAT COUNTS AS A VIOLATION — deliberately narrow, and mechanically decidable
#
#   A key is RED iff it has at least one CONSUMER site in production bash and EVERY one of its
#   consumer sites — across production bash AND python — sits inside a bash function the production
#   ENTRYPOINTS cannot reach. That is the exact `_healthcheck_gate` shape, and nothing wider.
#
#   Deliberately NOT red (each would need judgment this lint does not have, so it stays quiet rather
#   than guess — a lint that cries wolf gets exempted into uselessness):
#     • A key with ZERO consumers anywhere. That is the "documented but never wired" class, which
#       belongs to caps-sync / doc-drift; here it is indistinguishable from a key consumed only by a
#       rendered template, a downstream project, or a `.herd/config` read this scan does not model.
#     • A key with at least ONE consumer on a live path — even if that live consumer only renders the
#       key's value into a doc while the BEHAVIORAL consumer is dead (`REVIEW_AUTOFIX` is exactly
#       this today: read by bin/herd's render_skill for the coordinator's posture prose, and by
#       `_handle_block_verdict`, which is dead). Telling "reads the value to act on it" from "reads
#       the value to print it" is not mechanically decidable, so those are reported as PARTIAL —
#       counted in the ADVISORY line and listed under HERD_LR_VERBOSE=1, never a red. The count is
#       kept in the default output ON PURPOSE: this guard's own blind edge stays visible instead of
#       reading as "nothing to see here".
#     • A python-side consumer. os.environ has no dead-function class; the port is the live path.
#
#   PARTIAL, verified (HERD-584): the three refix-bounce autofix levers — REVIEW_AUTOFIX,
#   HEALTHCHECK_AUTOFIX, STALE_BASE_AUTOFIX — read differently under python despite sharing the same
#   PARTIAL shape (a live bin/herd prose site, a dead bash `_*_autofix_enabled`/`_handle_*` site):
#     • REVIEW_AUTOFIX / HEALTHCHECK_AUTOFIX have ZERO pysrc consumers. The python decide path's
#       three-way review/health refix bounce (`LiveTick._bounce_and_wake`, HERD-358) fires
#       UNCONDITIONALLY on a BLOCK/CODEERROR verdict — it does not read either key at all — so under
#       ENGINE_IMPL=python these two levers are cosmetic no-ops: setting either true or false changes
#       nothing. journal proof the bounce itself is live regardless: tests/test_live_runtime.py's
#       TestRefixWakeVerification asserts `refix_bounce`/`refix_wake_result` for both rails on every
#       tick with a red verdict. This is a real, disclosed gap, not an oversight — herd-config.sh still
#       defaults both keys and bin/herd's posture prose still reads on them for a bash-driver project,
#       so they stay PARTIAL rather than a finding this guard cannot phrase as "inert".
#     • STALE_BASE_AUTOFIX gates a REAL python behavioral difference: `_stale_base_autofix_enabled`
#       (pysrc/herd/live_runtime.py) is read on the stale-dup gate's LIVE-ONLY path and the lever off
#       is a hard HOLD-no-bounce no-op — on drives the same three-way bounce, PLUS (HERD-584)
#       `LiveTick._stale_no_wake_fallback` dispatching the existing conflict resolver
#       (`herd-resolve.sh`) when no live builder is on the pane to bounce. journal proof:
#       tests/test_live_runtime.py's TestStaleDupGate (bounce/resolver-dispatch/escalate) and
#       TestLiveDispatchResolver (the herd-resolve.sh shell-out shape). It reads PARTIAL for the same
#       mechanical reason as its siblings (a dead bash `_stale_base_autofix_enabled` still exists in
#       agent-watch.sh) but is, unlike them, a genuinely live lever.
#
# THE SCAN SURFACE, and why it is asymmetric (a guard that scans the wrong surface reports clean while
# the defect sits in what it does not scan — the failure mode this file exists to end):
#
#   CALLERS are counted from PRODUCTION only — bin/herd, scripts/herd/**.sh, the committed gate
#   wrappers under .herd/, and the templates/*.sh shipped to consuming projects — EXCLUDING
#   scripts/herd/sim/**, scripts/herd/experiment/** and tests/**. This is the whole point: the sandbox
#   sims call `_healthcheck_gate` DIRECTLY (sandbox-concurrency-scenario.sh:411,
#   sandbox-shared-config-scenario.sh:305) and have passed green through the entire window in which
#   production stopped calling it. A test that calls a function is not a caller of it — it is a
#   fixture that keeps the corpse warm.
#
#   REACHABILITY IS TRANSITIVE, and it has to be. A one-hop "does anything call it" rule is not
#   enough, and the grounded incident is the shape that proves it: `HEALTH_PANE` is read by
#   `_effective_health_pane`, called by `_spawn_health_pane`, called by `_healthcheck_gate` — the
#   corpse. Every link has a caller, so a one-hop rule sees live-LOOKING functions all the way down
#   and reports clean on a lever that could not fire.
#   Deadness travels down a chain, so the check does too: ROOTS are every function named at TOP LEVEL
#   (outside any function body) anywhere in the production surface — bin/herd's dispatch table,
#   agent-watch.sh's main flow, each lane script's `main "$@"`, the gate wrappers' straight-line
#   bodies, top-level `trap` installs — and reachability is the closure over "function A names
#   function B in its body".
#
# WHAT COUNTS AS A CALL — generous on purpose, because over-counting callers can only SUPPRESS a red
# (never invent one), and a false red on a live lever is the one failure this guard must not have. A
# whole-word mention on any non-comment line counts as an edge: a command-position call, a
# `trap '_fn' RETURN` body, an `eval`, a `for f in a b c` dispatch list, a `$(fn)` substitution, a
# name inside a heredoc — no shell parser required, and bash's dynamic dispatch (`"$cmd" …`, herdr
# callbacks) cannot hide a caller from a rule this blunt. `_healthcheck_gate` still falls out dead
# because its only remaining production mentions are prose in full-line comments.
#
# Opt-out: tests/lever-reachability-exempt.tsv — `<KEY><TAB><reason>` rows, comment lines with `#`.
# A row is a DECISION on the record ("this bash-only lever is intentionally unreachable under the
# shipped engine, and here is why a future auditor should not re-wire it"), so the reason is
# MANDATORY: a bare row reds as EXEMPT-MALFORMED rather than silently laundering a real finding. A row
# that stops matching a finding reds as STALE-EXEMPT and must be dropped — an exemption list that
# outlives what it excused is how a ratchet quietly stops ratcheting. That file also carries the
# BASELINE: the eight levers this guard found ALREADY inert on the tree the day it landed, each filed
# for the coordinator via `herd note` and deliberately not fixed in the guard's own PR.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh   — the builder's LIGHT pre-PR gate
#     • .herd/healthcheck.project.sh  — the heavy/merge gate (authoritative)
# Sourced-library precedent: caps-sync-lint.sh / gate-coverage-lint.sh / env-export-lint.sh.
#
# Two functions:
#
# herd_lever_reachability_check <root>
#   Pure form used by hermetic fixtures. Prints one
#   'LEVER-UNREACHABLE <KEY> · only consumer(s) inside defined-never-called <fn> (<file>:<line>[, …])'
#   line per inert lever, plus 'EXEMPT-MALFORMED <key>' for a reasonless exemption and
#   'STALE-EXEMPT <key>' for one that no longer excuses anything, then an ADVISORY summary.
#   Exit: 0 = clean · 1 = finding(s) on stdout.
#
# herd_lever_reachability_lint [<root>]
#   Entrypoint for the gate surfaces. Exit: 0 = clean · 1 = finding(s) · 2 = skipped (infra; NEVER a
#   red). On a skip, $HERD_LEVER_REACHABILITY_SKIP_REASON carries the one-line why.
#
# Fail-soft by construction: a tree with no templates/capabilities.tsv + no scripts/herd (i.e. every
# CONSUMING project — the manifest is herdkit's own engine surface) skips, never a false red. Bash 3.2
# clean; python3-backed like journal-emission-lint.sh.

HERD_LEVER_REACHABILITY_SKIP_REASON=""

# herd_lever_reachability_check <root> — pure function; prints findings + ADVISORY. 0/1.
#
# The heredoc feeds python3 DIRECTLY and the function's exit status IS python3's — deliberately NOT
# wrapped in a `$(…)` here (see journal-emission-lint.sh's note: from bash 5.x a here-document nested
# in a command substitution ends at the first line whose PREFIX matches the delimiter, which silently
# turned that file's python body into shell on ubuntu while passing on macOS bash 3.2). The delimiter
# is long and prefix-unique so neither hazard can recur.
herd_lever_reachability_check() {
  python3 - "${1:-.}" <<'LEVER_REACHABILITY_LINT_PY_EOF'
import os, re, sys

root = sys.argv[1]

def rel(p):
    return os.path.relpath(p, root).replace(os.sep, "/")

def walk(sub, exts):
    """Every file under <root>/<sub> whose extension is in exts (sorted, deterministic)."""
    base = os.path.join(root, sub)
    hits = []
    for dirpath, dirnames, filenames in os.walk(base):
        dirnames.sort()
        for fn in sorted(filenames):
            if any(fn.endswith(e) for e in exts):
                hits.append(os.path.join(dirpath, fn))
    return sorted(hits)

def read(path):
    try:
        with open(path, encoding="utf-8", errors="replace") as fh:
            return fh.read().splitlines()
    except OSError:
        return []

EXCLUDED = ("scripts/herd/sim/", "scripts/herd/experiment/", "tests/")

# THIS FILE is excluded from its own scan. It names real levers in prose to explain the bug class it
# guards (and a python docstring is not a `#` comment, so the comment filter does not reach it), which
# would register the lint's own documentation as a live consumer of exactly the keys it exists to
# audit — a guard laundering its own findings. Measured, not theoretical: before this exclusion the
# header's REVIEW_AUTOFIX example alone moved that key out of the dead-only class.
SELF = "scripts/herd/lever-reachability-lint.sh"

def is_production(path):
    r = rel(path)
    return r != SELF and not any(r.startswith(x) for x in EXCLUDED)

# ── SURFACE ───────────────────────────────────────────────────────────────────────────────────────
# Bash: the engine tree, the committed gate wrappers, and the templates shipped to consuming
# projects. Python: the ported core. Sims / experiments / tests are excluded from BOTH sides.
bash_files = [p for p in (walk("scripts/herd", (".sh",)) + walk(".herd", (".sh",))
                          + walk("templates", (".sh",)) + [os.path.join(root, "bin", "herd")])
              if os.path.exists(p) and is_production(p)]
py_files = [p for p in walk("pysrc", (".py",)) if is_production(p)]

# ── FUNCTION DEFINITIONS AND THEIR EXTENTS ────────────────────────────────────────────────────────
# Extents are delimited by a closing brace in COLUMN 0 (`^}`), not by brace counting. Every function
# in this tree closes that way, and column-0 is immune to the things that break a brace counter:
# `${var}` expansions, embedded awk programs, jq filters and heredoc bodies all carry unbalanced
# braces. A miscounted extent would attribute a top-level consumer to a dead function — i.e. invent a
# red — so the robust rule is the correct trade even though it cannot see a nested function.
DEF = re.compile(r'^(?:function[ \t]+)?([A-Za-z_][A-Za-z0-9_-]*)[ \t]*\(\)[ \t]*\{?[ \t]*$')

defs = {}       # name -> [(relpath, line), …]
extents = {}    # relpath -> [(start, end, name), …]

for path in bash_files:
    lines = read(path)
    r = rel(path)
    open_fn = None          # (name, startline)
    for i, line in enumerate(lines, 1):
        if line.lstrip().startswith("#"):
            continue
        m = DEF.match(line)
        if m:
            if open_fn:      # a def with no column-0 close before it: end the previous one here
                extents.setdefault(r, []).append((open_fn[1], i - 1, open_fn[0]))
            open_fn = (m.group(1), i)
            defs.setdefault(m.group(1), []).append((r, i))
            continue
        if open_fn and line.startswith("}"):
            extents.setdefault(r, []).append((open_fn[1], i, open_fn[0]))
            open_fn = None
    if open_fn:
        extents.setdefault(r, []).append((open_fn[1], len(lines), open_fn[0]))

def enclosing(relpath, lineno):
    """The function whose extent contains this line, or None for a top-level line."""
    for (st, en, name) in extents.get(relpath, []):
        if st <= lineno <= en:
            return name
    return None

# ── THE CALLED SET: a reachability closure rooted at the production entrypoints ───────────────────
# Roots are every function named at TOP LEVEL (outside any function body) anywhere in the production
# surface: bin/herd's dispatch table, agent-watch.sh's main flow, each lane script's `main "$@"`, the
# gate wrappers' straight-line bodies, top-level `trap` installs. Edges run from a function to every
# function named inside its body. Reachable = the closure; DEAD = defined but never reached.
#
# A flat "is it mentioned anywhere" rule is NOT enough, and the grounded incident is the shape that
# proves it. HEALTH_PANE is read by `_effective_health_pane`, which is called by `_spawn_health_pane`,
# which was called by `_healthcheck_gate` — the corpse. Every link in that chain has a caller, so a
# one-hop rule sees live-LOOKING functions all the way down and reports clean on a lever that could
# not fire. Deadness travels down a chain, so the check has to as well; tests/
# test-lever-reachability-lint.sh leg (4) is the mechanical proof on exactly this shape.
#
# Generous on EDGES for the same reason the surface is asymmetric: any whole-word mention on a
# non-comment line counts — a command-position call, a `trap '_fn' RETURN` body, an `eval`, a
# `for f in a b c` dispatch list, a name inside a heredoc. No shell parser required, and a spurious
# edge can only keep something alive (suppressing a red), never invent one. `_healthcheck_gate` still
# falls out dead because its only remaining production mentions are prose in full-line comments.
IDENT = re.compile(r'[A-Za-z_][A-Za-z0-9_-]*')
roots = set()
edges = {}      # caller -> set(callee)

for path in bash_files:
    r = rel(path)
    own = dict((dl, name) for (name, sites) in defs.items() for (dr, dl) in sites if dr == r)
    for i, line in enumerate(read(path), 1):
        if line.lstrip().startswith("#"):
            continue
        here = enclosing(r, i)
        for tok in IDENT.findall(line):
            if tok not in defs or own.get(i) == tok:
                continue
            if here is None:
                roots.add(tok)
            else:
                edges.setdefault(here, set()).add(tok)

reachable = set()
frontier = [n for n in roots if n in defs]
while frontier:
    name = frontier.pop()
    if name in reachable:
        continue
    reachable.add(name)
    frontier.extend(edges.get(name, ()))

dead = set(name for name in defs if name not in reachable)

# ── THE LEVERS: the config-key rows of the capability manifest ────────────────────────────────────
# `config` rows are the .herd/config knobs; `env` rows are the ambient env levers (HEALTHCHECK_SUITE_
# WORKERS, HERD_LIMIT_DETECT, …) — same class, same failure. `lane`/`lever`/`reference`/`convention`
# rows name scripts and files, not keys, and are filtered out by the UPPER_SNAKE name shape.
KEYNAME = re.compile(r'[A-Z][A-Z0-9_]*$')
keys = []
cap = os.path.join(root, "templates", "capabilities.tsv")
for line in read(cap)[1:]:
    if not line.strip() or line.startswith("#"):
        continue
    fields = line.split("\t")
    if len(fields) < 2:
        continue
    name, kind = fields[0].strip(), fields[1].strip()
    if kind in ("config", "env") and KEYNAME.match(name) and name not in keys:
        keys.append(name)

# ── EXEMPTIONS ────────────────────────────────────────────────────────────────────────────────────
exempt = {}
malformed = []
exempt_file = os.path.join(root, "tests", "lever-reachability-exempt.tsv")
for line in read(exempt_file):
    if not line.strip() or line.lstrip().startswith("#"):
        continue
    parts = line.split("\t")
    key = parts[0].strip()
    reason = parts[1].strip() if len(parts) > 1 else ""
    if not reason:
        malformed.append(key)
        continue
    exempt[key] = reason

# ── CONSUMER SITES ────────────────────────────────────────────────────────────────────────────────
# herd-config.sh's own `: "${KEY:=default}"` / `export KEY …` lines DECLARE a key; they are the
# producer side, not a consumer, and counting them would green every key on the tree (they all sit at
# top level in that file). Continuation lines of a multi-line `export` block are declarations too —
# they do not start with `export`, and missing them would have laundered ~40 keys.
CFG = "scripts/herd/herd-config.sh"
DECL = re.compile(r'^[ \t]*(?::[ \t]+"?\$\{|export[ \t]|[A-Z][A-Z0-9_]*=)')

def strip_inline_comment(line):
    """Drop a trailing ` # …` comment when the `#` is unquoted.

    herd-config.sh documents every key in a trailing comment on its NEIGHBOUR's declaration line
    (HEALTHCHECK_AUTOFIX's comment names REVIEW_AUTOFIX and STALE_BASE_AUTOFIX), so without this a
    key is 'consumed' by the prose describing a different key. Only a `#` preceded by whitespace and
    reached with both quote styles balanced is treated as a comment; anything ambiguous is left
    alone, which keeps a real consumer visible (the safe direction — see the header)."""
    sq = dq = 0
    for i, ch in enumerate(line):
        if ch == "'" and dq % 2 == 0:
            sq += 1
        elif ch == '"' and sq % 2 == 0:
            dq += 1
        elif ch == "#" and sq % 2 == 0 and dq % 2 == 0 and i > 0 and line[i - 1] in " \t":
            return line[:i]
    return line

# One pass over the surface builds a line -> keys-mentioned map, so the cost is O(files x keys) in
# regex matches only for the lines that actually contain an UPPER_SNAKE token.
keyset = set(keys)
TOKEN = re.compile(r'[A-Z][A-Z0-9_]*')

live_sites = dict((k, []) for k in keys)     # key -> [(file, line, enclosing_fn_or_None), …]
dead_sites = dict((k, []) for k in keys)     # key -> [(file, line, dead_fn), …]

for path in bash_files + py_files:
    r = rel(path)
    ispy = path.endswith(".py")
    cont = False
    for i, line in enumerate(read(path), 1):
        if line.lstrip().startswith("#"):
            continue
        isdecl = (r == CFG and (bool(DECL.match(line)) or cont))
        if r == CFG:
            cont = isdecl and line.rstrip().endswith("\\")
        if isdecl:
            continue
        body = strip_inline_comment(line)
        hits = set(t for t in TOKEN.findall(body) if t in keyset)
        if not hits:
            continue
        fn = None if ispy else enclosing(r, i)
        for key in hits:
            if fn is not None and fn in dead:
                dead_sites[key].append((r, i, fn))
            else:
                live_sites[key].append((r, i, fn))

# ── VERDICT ───────────────────────────────────────────────────────────────────────────────────────
def is_finding(k):
    return k in dead_sites and bool(dead_sites[k]) and not live_sites[k]

unreachable = [k for k in keys if is_finding(k) and k not in exempt]
partial = [k for k in keys if dead_sites[k] and live_sites[k]]
consumed = [k for k in keys if dead_sites[k] or live_sites[k]]
silenced = [k for k in keys if is_finding(k) and k in exempt]
# An exemption that outlives the thing it excused is how a ratchet quietly stops ratcheting: once the
# key's consumer chain is reachable again (or the key is gone), the row must go with it.
stale_exempt = sorted(k for k in exempt if not is_finding(k))

# HERD_LR_VERBOSE=1 dumps what the scan actually SAW. A guard that reports clean because its scan
# surface misses the defect is the dominant failure shape in this tree, so the surface is made
# inspectable rather than taken on trust.
if os.environ.get("HERD_LR_VERBOSE"):
    for name in sorted(dead):
        print("SAW-DEAD-FN %s · %s" % (name, ", ".join("%s:%d" % s for s in defs[name][:3])))
    for key in keys:
        print("SAW-LEVER %s · live=%d dead=%d%s"
              % (key, len(live_sites[key]), len(dead_sites[key]),
                 " · EXEMPT" if key in exempt else ""))
    for key in partial:
        print("SAW-PARTIAL %s · live at %s:%d · dead at %s (%s:%d)"
              % (key, live_sites[key][0][0], live_sites[key][0][1],
                 dead_sites[key][0][2], dead_sites[key][0][0], dead_sites[key][0][1]))

for key in sorted(malformed):
    print("EXEMPT-MALFORMED %s · tests/lever-reachability-exempt.tsv row needs a TAB-separated reason"
          % key)

for key in stale_exempt:
    why = "no longer a finding" if key in keyset else "no such config-key row in capabilities.tsv"
    print("STALE-EXEMPT %s · %s — drop the tests/lever-reachability-exempt.tsv row" % (key, why))

for key in unreachable:
    seen, shown = set(), []
    for (f, ln, fn) in dead_sites[key]:
        if fn in seen:
            continue
        seen.add(fn)
        shown.append("%s (%s:%d)" % (fn, f, ln))
    print("LEVER-UNREACHABLE %s · only consumer(s) inside defined-never-called %s%s"
          % (key, ", ".join(shown[:4]), " …" if len(shown) > 4 else ""))

print("ADVISORY: %d config-key row(s), %d with a production consumer, %d dead bash function(s), "
      "%d exempt (%d silencing a finding), %d partial (a live consumer alongside a dead one), "
      "%d unreachable"
      % (len(keys), len(consumed), len(dead), len(exempt), len(silenced), len(partial),
         len(unreachable)))
sys.exit(1 if (unreachable or malformed or stale_exempt) else 0)
LEVER_REACHABILITY_LINT_PY_EOF
}

# herd_lever_reachability_lint [<root>] — gate entrypoint. 0 clean · 1 finding(s) · 2 skipped (never red).
herd_lever_reachability_lint() {
  local _lr_root="${1:-.}" _lr_out _lr_rc
  HERD_LEVER_REACHABILITY_SKIP_REASON=""
  if ! command -v python3 >/dev/null 2>&1; then
    HERD_LEVER_REACHABILITY_SKIP_REASON="python3 not available"
    return 2
  fi
  # No capability manifest + engine script tree (every CONSUMING project) → skip, never a false red.
  if [ ! -f "$_lr_root/templates/capabilities.tsv" ] || [ ! -d "$_lr_root/scripts/herd" ]; then
    HERD_LEVER_REACHABILITY_SKIP_REASON="no engine capability surface (templates/capabilities.tsv + scripts/herd)"
    return 2
  fi
  _lr_out="$(herd_lever_reachability_check "$_lr_root")"; _lr_rc=$?
  [ -n "$_lr_out" ] && printf '%s\n' "$_lr_out"
  return "$_lr_rc"
}
