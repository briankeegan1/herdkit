#!/usr/bin/env bash
# journal-emission-lint.sh — THE shared CONSUMER-ONLY EVENT guard (HERD-442): every journal event
# name a CONSUMER parses must have a live PRODUCER somewhere in the engine.
#
# The bug this guard exists to stop (proven twice, live):
#
#   • `human_verify_policy` — journal-audit.sh (:33/:567) parsed it and fixture_extract.py (:230)
#     mapped it to HV_HOLD per docs/engine-contract.md §5.4, and NOTHING produced it. The producer
#     died with the bash action pass at `ede7d45` (HERD-306 P5b) and the Python port never re-emitted
#     it, so a `HUMAN_VERIFY_POLICY=auto` merge of a PR with declared-but-never-executed manual steps
#     left no trace at all. Restored in PR #560 — 19 days after the loss, and only because a test
#     audit stumbled on it.
#   • `hold_released` — `herd why` (bin/herd + pysrc/herd/why.py) and the fleet inbox/digest
#     (fleet.sh) all still read it; its only producer was the same deleted action pass, so every held
#     PR that was later approved and merged stayed `held` forever in the fleet view.
#   • `merged_external` — the fleet digest's cross-seat-merge leg (HERD-291) shipped a CONSUMER with
#     no producer AT ALL: the post-merge sweep emits `merge_observed`, never `merged_external`. The
#     leg had never once fired in production.
#
# All three are the same defect: a consumer silently reading an event nobody writes. It is invisible
# to every other rail — the journal is best-effort, so a missing event is indistinguishable from "it
# just did not happen this run", and no test asserts the absence of an absence. This lint is the
# mechanical check that would have caught all three the day they landed.
#
# THE SCAN SURFACE, and why it is asymmetric (a lint that scans the wrong surface reports clean while
# the defect sits in what it does not scan — the failure mode this file is guarding against):
#
#   PRODUCERS are counted from PRODUCTION code only — `bin/herd`, `scripts/herd/**.sh`,
#   `pysrc/herd/*.py` — EXCLUDING `scripts/herd/sim/**`, `scripts/herd/experiment/**` and `tests/**`.
#   A sim that journals an event itself and then asserts it is present is a self-fulfilling guard,
#   not a producer: `sandbox-resolver-respawn-scenario.sh` mirrors the deleted `resolver_respawn`
#   emission with its own `journal_append`, so it has passed green through the entire window in which
#   production stopped emitting it.
#
#   CONSUMERS are counted from every surface that PARSES an event name: journal-audit.sh, fleet.sh,
#   bin/herd (`herd why` / `herd log`), pysrc/herd/*.py (why / log / fixture_extract / parity),
#   the sims and experiments (their assertions ARE consumers), and the §3.4 event catalog in
#   docs/engine-contract.md.
#
# Dynamic producers are resolved, not ignored: `journal_append "$1"` inside a wrapper is resolved
# through its call sites, and `journal_append "$var"` through the literal assignments to `$var` in the
# same file, so `control_pane_mutation_refused` (context-guard.sh) and `healthcheck_retried`
# (agent-watch.sh `record_healthcheck`) are correctly seen as PRODUCED. A `"prefix_$kind"` form
# registers a PREFIX producer, so `retire_converged` matches `retire_`'s dynamic emitter.
#
# Opt-out: an event that is deliberately consumer-only lives in the ALLOWLIST below, WITH ITS REASON.
# The allowlist is the record of a decision ("this was dropped on purpose"), which is exactly what
# docs/engine-contract.md §3.5 documents in prose — keep the two in step.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh   — the builder's LIGHT pre-PR gate
#     • .herd/healthcheck.project.sh  — the heavy/merge gate (authoritative)
# Sourced-library precedent: caps-sync-lint.sh / gate-coverage-lint.sh / pipe-safety-lint.sh.
#
# Two functions:
#
# herd_journal_emission_check <root>
#   Pure form used by hermetic fixtures. Prints one
#   'EMISSION-ORPHAN <event> · consumed at <file>:<line>[, …]' line per orphan on stdout, then an
#   ADVISORY summary. Exit: 0 = clean · 1 = orphan(s) on stdout.
#
# herd_journal_emission_lint [<root>]
#   Entrypoint for the gate surfaces. Exit: 0 = clean · 1 = orphan(s) · 2 = skipped (infra; NEVER a
#   red). On a skip, $HERD_JOURNAL_EMISSION_SKIP_REASON carries the one-line why.
#
# Fail-soft by construction: a tree with no `pysrc/herd` + no `scripts/herd/journal.sh` (i.e. every
# CONSUMING project — this is herdkit's own engine surface) skips, never a false red. Bash 3.2 clean.

HERD_JOURNAL_EMISSION_SKIP_REASON=""

# ── ALLOWLIST — deliberately consumer-only, with the reason. Format: '<event>|<reason>'. ───────────
# Keep in step with docs/engine-contract.md §3.5. Adding a row is a DECISION, not a silencer: it says
# "no producer, on purpose, and here is why a future auditor should not re-add one".
HERD_JOURNAL_EMISSION_ALLOW='
resolver_respawn|HERD-442: the bash resolve pass journaled this when re-dispatching a resolver for a new sha; the Python core owns dispatch now and does not re-emit it. The RESPAWN BEHAVIOR is alive (spawn_resolver has live callers) — only the forensic line is gone. Restoring it needs the round/old_sha ledger reads the port has not ported; tracked separately, not re-added blind.
cross_seat_block_honored|HERD-442: bash journaled this from two stages (setter + merge). Both call sites died with the bash action pass / the now-callerless bash post_gate_status; the Python core carries no cross-seat BLOCK precedence check at all (HERD-247 is unenforced in the port). The event must NOT be re-added without the guard it records — a forensic line for a check that does not run is worse than silence.
gate_default|contract §3.2 documents this verdict PROVENANCE as latent-by-design: there is no live call site and a no-verdict run is treated as INFRA (retry), never a default BLOCK. Documented, deliberately unproduced.
'

# herd_journal_emission_check <root> — pure function; prints EMISSION-ORPHAN lines + ADVISORY. 0/1.
herd_journal_emission_check() {
  local _je_root="${1:-.}" _je_out _je_rc
  _je_out="$(HERD_JE_ALLOW="$HERD_JOURNAL_EMISSION_ALLOW" python3 - "$_je_root" <<'PY'
import os, re, sys

root = sys.argv[1]

def rel(p):
    return os.path.relpath(p, root)

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

def is_production(path):
    r = rel(path).replace(os.sep, "/")
    return not any(r.startswith(x) for x in EXCLUDED)

NAME = r"[a-z][a-z0-9_]*"
Q = "[\"']"                      # either quote style, spelled once (kept free of backslash-quotes so
                                 # this script's heredoc never confuses a shell's `$(…)` scanner)

# ── PRODUCERS ─────────────────────────────────────────────────────────────────────────────────────
producers = set()      # exact event names
prefixes = set()       # dynamic "prefix_$var" emitters

bash_files = [p for p in (walk("scripts/herd", (".sh",)) + [os.path.join(root, "bin", "herd")])
              if os.path.exists(p) and is_production(p)]

LIT = re.compile(r'(?<![\w-])journal_append\s+"?(' + NAME + r')"?')
DYN_POS = re.compile(r'(?<![\w-])journal_append\s+"\$\{?([1-9])\}?"')
DYN_VAR = re.compile(r'(?<![\w-])journal_append\s+"\$\{?([A-Za-z_][A-Za-z0-9_]*)\}?"')
DYN_PFX = re.compile(r'(?<![\w-])journal_append\s+"(' + NAME + r'_)\$')
FUNC = re.compile(r'^([A-Za-z_][A-Za-z0-9_]*)\(\)\s*\{')

wrapper_args = {}      # function name -> set of positional indexes it forwards as the event name
dyn_vars = {}          # file -> set of variable names used as the event name

for path in bash_files:
    lines = read(path)
    fn = None
    for line in lines:
        m = FUNC.match(line)
        if m:
            fn = m.group(1)
        if line.lstrip().startswith("#"):
            continue
        for m in LIT.finditer(line):
            producers.add(m.group(1))
        for m in DYN_PFX.finditer(line):
            prefixes.add(m.group(1))
        for m in DYN_POS.finditer(line):
            if fn:
                wrapper_args.setdefault(fn, set()).add(int(m.group(1)))
        for m in DYN_VAR.finditer(line):
            if not m.group(1).isdigit():
                dyn_vars.setdefault(path, set()).add(m.group(1))

# resolve wrapper call sites: `_wrapper <literal> …` anywhere in production bash
for name, positions in wrapper_args.items():
    call = re.compile(r'(?:^|[;&|(]|\bif\s|\bthen\s|\belse\s|\bdo\s|\|\|\s|&&\s|!\s)\s*'
                      + re.escape(name) + r'\s+(.+)$')
    for path in bash_files:
        for line in read(path):
            if line.lstrip().startswith("#"):
                continue
            m = call.search(line)
            if not m:
                continue
            args = m.group(1).split()
            for pos in positions:
                if len(args) >= pos:
                    tok = args[pos - 1].strip('"').strip("'")
                    if re.fullmatch(NAME, tok):
                        producers.add(tok)

# resolve `journal_append "$var"` through literal assignments to $var in the SAME file
for path, names in dyn_vars.items():
    lines = read(path)
    for var in names:
        assign = re.compile(r'(?:^|\s|;)' + re.escape(var) + r'=(' + NAME + r')\s*$')
        for line in lines:
            if line.lstrip().startswith("#"):
                continue
            m = assign.search(line.rstrip())
            if m:
                producers.add(m.group(1))

PY_APPEND = re.compile(r"journal\.append\(\s*" + Q + "(" + NAME + ")" + Q)
PY_ENCODE = re.compile(r"encode_event\(\s*" + Q + "(" + NAME + ")" + Q)
py_files = [p for p in walk("pysrc", (".py",)) if is_production(p)]
for path in py_files:
    # Matched over the WHOLE file, not line by line: a long emit routinely wraps the event name onto
    # the line after `journal.append(`, and a per-line scan would silently miss it — a producer this
    # guard cannot see is indistinguishable from one that does not exist, which is the entire bug
    # class here. Full-line comments are dropped first so a commented-out emit never counts.
    body = "\n".join(l for l in read(path) if not l.lstrip().startswith("#"))
    for rx in (PY_APPEND, PY_ENCODE):
        for m in rx.finditer(body):
            producers.add(m.group(1))

# ── CONSUMERS ─────────────────────────────────────────────────────────────────────────────────────
consumers = {}         # event -> [ "file:line", … ]

def note(name, path, lineno):
    consumers.setdefault(name, [])
    site = "%s:%d" % (rel(path).replace(os.sep, "/"), lineno)
    if site not in consumers[name]:
        consumers[name].append(site)

CMP = re.compile(r"(?:\bev\b|\bevent\b|get\(\s*" + Q + "event" + Q + r"\s*\)(?:\s*or\s*"
                 + Q + Q + r")?\s*\)?)\s*(?:==|!=)\s*" + Q + "(" + NAME + ")" + Q)
# `ev in ("a", "b")` is a membership TEST on a parsed event. `for ev in (…)` is an ITERATION over a
# literal vocabulary (shadow_runtime.py builds its lifecycle transition table that way) — not a
# consumer of the journal, so the `for` form is excluded.
IN = re.compile(r"(?<!for )(?:\bev\b|get\(\s*" + Q + "event" + Q + r"\s*\))\s*(?:not\s+)?in\s*"
                r"[\(\{\[]([^)\}\]]*)[\)\}\]]")
JSONISH = re.compile(Q + "event" + Q + r"\s*:\s*\\?" + Q + "(" + NAME + ")")
# A QUALIFIED set/dict of event names (CANDIDATE_EVENTS, STEP_EVENTS, TERMINALS, …) is a consumer.
# The BARE `EVENTS` tuple is deliberately NOT matched: statemachine.py / shadow_runtime.py use it for
# the LIFECYCLE TRANSITION ALPHABET (`health_clean`, `decide_merge`, `approved`, …), which is an
# internal state-machine vocabulary, never a journal event name — nothing ever writes those to JSONL.
SETLIKE = re.compile(r"(?:\b[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*_EVENTS\b|\bTERMINALS\b)"
                     r"[^\n]*[\(\{\[]")
QUOTED = re.compile(Q + "(" + NAME + ")" + Q)

consumer_files = []
for cand in ("scripts/herd/journal-audit.sh", "scripts/herd/fleet.sh", "bin/herd"):
    p = os.path.join(root, cand)
    if os.path.exists(p):
        consumer_files.append(p)
consumer_files += [p for p in walk("pysrc", (".py",))]
consumer_files += [p for p in walk("scripts/herd/sim", (".sh",))]
consumer_files += [p for p in walk("scripts/herd/experiment", (".sh",))]

for path in consumer_files:
    lines = read(path)
    depth = 0
    for i, line in enumerate(lines, 1):
        if depth > 0:
            for m in QUOTED.finditer(line):
                note(m.group(1), path, i)
            depth += line.count("(") + line.count("{") + line.count("[")
            depth -= line.count(")") + line.count("}") + line.count("]")
            if depth <= 0:
                depth = 0
            continue
        for m in CMP.finditer(line):
            note(m.group(1), path, i)
        for m in JSONISH.finditer(line):
            note(m.group(1), path, i)
        for m in IN.finditer(line):
            for n in re.findall(Q + "(" + NAME + ")" + Q, m.group(1)):
                note(n, path, i)
        if SETLIKE.search(line):
            for m in QUOTED.finditer(line):
                note(m.group(1), path, i)
            depth = (line.count("(") + line.count("{") + line.count("[")
                     - line.count(")") - line.count("}") - line.count("]"))
            if depth < 0:
                depth = 0

# the §3.4 event catalog in docs/engine-contract.md — a documented event is a consumer contract
contract = os.path.join(root, "docs", "engine-contract.md")
if os.path.exists(contract):
    inside = False
    for i, line in enumerate(read(contract), 1):
        if line.startswith("### 3.4"):
            inside = True
            continue
        if inside and line.startswith("#"):
            break                        # any following heading ends the catalog (§3.5 is prose)
        if not inside or not line.startswith("|"):
            continue
        cell = line.split("|")[1] if line.count("|") >= 2 else ""
        for m in re.finditer(r'`(' + NAME + r')`', cell):
            note(m.group(1), contract, i)

# ── VERDICT ───────────────────────────────────────────────────────────────────────────────────────
allow = {}
for row in (os.environ.get("HERD_JE_ALLOW") or "").splitlines():
    row = row.strip()
    if not row or "|" not in row:
        continue
    name, reason = row.split("|", 1)
    allow[name.strip()] = reason.strip()

def produced(name):
    if name in producers:
        return True
    return any(name.startswith(p) for p in prefixes)

orphans = []
for name in sorted(consumers):
    if produced(name) or name in allow:
        continue
    orphans.append(name)

# HERD_JE_VERBOSE=1 dumps what the scan actually SAW. A guard that reports clean because its scan
# surface misses the defect is the dominant failure shape in this tree, so the surface is made
# inspectable: HERD_JE_VERBOSE=1 lists every name the scan saw on both sides.
# (NB: this heredoc body must stay free of unbalanced apostrophes — the shell scans it for the
# closing paren of the enclosing command substitution.)
if os.environ.get("HERD_JE_VERBOSE"):
    for name in sorted(producers):
        print("SAW-PRODUCER %s" % name)
    for name in sorted(consumers):
        print("SAW-CONSUMER %s · %s" % (name, ", ".join(consumers[name][:4])))

for name in orphans:
    sites = consumers[name]
    print("EMISSION-ORPHAN %s · consumed at %s%s"
          % (name, ", ".join(sites[:4]), " …" if len(sites) > 4 else ""))

print("ADVISORY: %d producer name(s), %d consumer-parsed name(s), %d allowlisted, %d orphan(s)"
      % (len(producers), len(consumers), len(allow), len(orphans)))
sys.exit(1 if orphans else 0)
PY
)"; _je_rc=$?
  [ -n "$_je_out" ] && printf '%s\n' "$_je_out"
  return "$_je_rc"
}

# herd_journal_emission_lint [<root>] — gate entrypoint. 0 clean · 1 orphan(s) · 2 skipped (never red).
herd_journal_emission_lint() {
  local _je_root="${1:-.}" _je_out _je_rc
  HERD_JOURNAL_EMISSION_SKIP_REASON=""
  if ! command -v python3 >/dev/null 2>&1; then
    HERD_JOURNAL_EMISSION_SKIP_REASON="python3 not available"
    return 2
  fi
  # No engine journal surface (every CONSUMING project) → skip, never a false red.
  if [ ! -f "$_je_root/scripts/herd/journal.sh" ] || [ ! -d "$_je_root/pysrc/herd" ]; then
    HERD_JOURNAL_EMISSION_SKIP_REASON="no engine journal surface (scripts/herd/journal.sh + pysrc/herd)"
    return 2
  fi
  _je_out="$(herd_journal_emission_check "$_je_root")"; _je_rc=$?
  [ -n "$_je_out" ] && printf '%s\n' "$_je_out"
  return "$_je_rc"
}
