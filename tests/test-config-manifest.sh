#!/usr/bin/env bash
# test-config-manifest.sh — SELF-ENFORCEMENT lint for the config manifest (HERD-161).
#
# templates/capabilities.tsv (kind==config rows) is the single manifest of every .herd/config knob:
# its declared reader, scope, and governance classification. Nothing keeps that manifest honest — a
# key can be documented but never read (a DEAD key), read but never documented (a GHOST key), or
# mis-scoped so `herd config set` routes it to the wrong file / a governance doc adopts a per-machine
# knob. This test turns those invariants into a hard gate so the manifest can never silently drift
# from the code that reads it. Six checks:
#
#   (a) DEAD keys      — every manifest config key is READ at least once under bin/ + scripts/.
#   (b) GHOST keys     — every ${UPPER_CASE:-…} config read in the engine is a DECLARED manifest key
#                        (or an explicitly-exempt internal/env/secret/test-seam var, see EXEMPT below).
#   (c) machine list   — the machine-scoped keys enumerated in the .herd/config.local manifest row
#                        equal EXACTLY the set of scope=machine config keys (the list `herd config set`
#                        auto-routes to the per-user overlay). Keeps the doc from lying about routing.
#   (d) governance sep — no scope=machine key appears in templates/governance-map.tsv: a per-machine
#                        knob is an operator preference, never a project GOVERNANCE policy a CLAUDE.md
#                        statement can adopt.
#   (e) watcher reqs   — every manifest key READ by agent-watch.sh or dep-watcher.sh carries
#                        requires=watcher, so `herd config set` restarts the watcher for it to take.
#   (f) default drift  — every config key documented in templates/config.example with a literal value
#                        matches that key's fallback in herd-config.sh (docs never drift from code).
#
# Fully hermetic: reads the repo's own committed files; NO herdr, gh, network, or model.
# Run:  bash tests/test-config-manifest.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CAPS="$ROOT/templates/capabilities.tsv"
GOVMAP="$ROOT/templates/governance-map.tsv"
CFG_EXAMPLE="$ROOT/templates/config.example"
LOADER="$ROOT/scripts/herd/herd-config.sh"

for f in "$CAPS" "$GOVMAP" "$CFG_EXAMPLE" "$LOADER"; do
  [ -f "$f" ] || { echo "FAIL: missing required file: $f" >&2; exit 1; }
done
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

ROOT="$ROOT" CAPS="$CAPS" GOVMAP="$GOVMAP" CFG_EXAMPLE="$CFG_EXAMPLE" LOADER="$LOADER" python3 - <<'PY'
import os, re, sys, glob

ROOT        = os.environ["ROOT"]
CAPS        = os.environ["CAPS"]
GOVMAP      = os.environ["GOVMAP"]
CFG_EXAMPLE = os.environ["CFG_EXAMPLE"]
LOADER      = os.environ["LOADER"]

failures = []
def check(name, ok, detail=""):
    if ok:
        print(f"PASS ({name})")
    else:
        failures.append(name)
        print(f"FAIL ({name}) {detail}", file=sys.stderr)

# ── Parse the manifest: kind==config rows → {name: {requires, scope, governance, description}} ─────
COLS = {}
with open(CAPS, encoding="utf-8") as f:
    header = f.readline().rstrip("\n").split("\t")
    idx = {h: i for i, h in enumerate(header)}
    for line in f:
        c = line.rstrip("\n").split("\t")
        if len(c) < 2 or c[1] != "config":
            continue
        def col(n):
            i = idx.get(n, -1)
            return c[i] if 0 <= i < len(c) else ""
        COLS[c[0]] = {
            "requires":    col("requires"),
            "scope":       col("scope"),
            "governance":  col("governance"),
            "description": col("description"),
        }
KEYS = set(COLS)

# Also grab the .herd/config.local row (kind==lever) — it enumerates the machine-routed key list.
CONFIG_LOCAL_DESC = ""
with open(CAPS, encoding="utf-8") as f:
    for line in f:
        c = line.rstrip("\n").split("\t")
        if c and c[0] == ".herd/config.local":
            CONFIG_LOCAL_DESC = c[2] if len(c) > 2 else ""
            break

# ── Engine source: the files that read .herd/config knobs (exclude sim/ + experiment/ scaffolding) ─
def engine_files():
    fs = glob.glob(os.path.join(ROOT, "scripts/herd/*.sh"))
    fs += glob.glob(os.path.join(ROOT, "scripts/herd/backends/*.sh"))
    herd = os.path.join(ROOT, "bin/herd")
    if os.path.isfile(herd):
        fs.append(herd)
    return [f for f in fs if os.path.isfile(f)]

ENGINE = engine_files()
SRC = {f: open(f, encoding="utf-8", errors="replace").read() for f in ENGINE}
ALL_SRC = "\n".join(SRC.values())

def is_read(key, text):
    # A genuine variable READ: ${KEY...} or $KEY at a word boundary (not a bare comment mention).
    return re.search(r'\$\{?' + re.escape(key) + r'(?![A-Za-z0-9_])', text) is not None

# ── (a) DEAD keys: every manifest config key is read somewhere in the engine ───────────────────────
dead = sorted(k for k in KEYS if not is_read(k, ALL_SRC))
check("a: no DEAD (declared-but-unread) keys", not dead,
      "unread manifest keys: " + ", ".join(dead))

# ── (b) GHOST keys: every ${UPPER:-…} config read is a declared manifest key, or explicitly exempt ─
# The engine reads MANY UPPER_SNAKE vars that are NOT .herd/config knobs — runtime/CLI/test overrides
# (the HERD_* namespace), backend secrets (JIRA_*/LINEAR_* live in .herd/secrets), theme palette
# colors (C_*), tool-internal namespaces, and computed locals. Those are EXEMPT by the rules below.
# Everything else read with a `:-`/`:=` default must be a declared manifest key. Adding a new engine
# read of an undeclared, non-exempt var trips this — forcing a deliberate declare-or-exempt choice.
EXEMPT_PREFIX = (
    "HERD_",            # engine runtime/CLI/test-seam namespace (real HERD_ config keys are declared)
    "JIRA_", "LINEAR_", # tracker-backend secrets — sourced from .herd/secrets, never .herd/config
    "C_",               # theme palette color vars (theme.sh)
    "HANDOFF_",         # handoff.sh capture fields
    "SWEEP_",           # backlog-reconcile-sweep.sh scoring seams
    "EMIT_",            # backlog-reconcile-sweep.sh output-format seams
    "BACKLOG_VIEW_",    # backlog viewer pane internals
    "TASK_PANE_VIEW_",  # task-spec viewer pane internals
    "AGENT_WATCH_",     # agent-watch.sh dry-run / lib-mode test seams
)
# HERD_BRAND is the one HERD_-namespaced value that IS a real config knob (declared) — never exempt it.
EXEMPT_PREFIX_EXCEPTIONS = {"HERD_BRAND"}
# Explicit internal/computed vars (paths, ids, models resolved in-engine, single-word locals).
EXEMPT_NAMES = {
    "ADVISE_MODEL", "AGENTS_JSON", "BLOCKED", "CELEBRATE", "DEPS_FILE", "DEP_STATES_FILE",
    "DEP_WATCHER_LIB", "DRYRUN", "HERDKIT_HOME", "HERDR_MIN_VERSION", "ITEM_STATE", "ITEM_UPDATED",
    "JOURNAL_FILE", "JOURNAL_MAX_BYTES", "LEDGER_FILE", "LOG", "MAIN_HEALTH", "NO_COLOR", "PASTURE",
    "PR", "RESEARCH_HEARTBEAT", "RESEARCH_INBOX", "RESEARCH_MODEL", "RESEARCH_QUEUE",
    "RESEARCH_REPORTS", "RESEARCH_TAB", "RESEARCH_TREES", "RESOLVER_MODEL", "ROOT",
    "SCRIBE_BACKEND_DIR", "SCRIBE_MODEL", "SCRIBE_TAB", "SLUG", "SPAWN_HOLDS", "STATES_FILE",
    "TAB", "TEMPLATES_DIR", "TMPDIR", "TRACKER_DRIFT", "TREES", "TSWEEP_LIMIT", "WPANE",
}
def exempt(k):
    if k in KEYS:            # already declared → not a ghost
        return True
    if k in EXEMPT_PREFIX_EXCEPTIONS:
        return False
    if k.startswith(EXEMPT_PREFIX):
        return True
    return k in EXEMPT_NAMES

ghosts = {}
for f, text in SRC.items():
    for m in re.finditer(r'\$\{([A-Z][A-Z0-9_]+):[-=]', text):
        k = m.group(1)
        if not exempt(k):
            ghosts.setdefault(k, os.path.basename(f))
check("b: no GHOST (read-but-undeclared) keys", not ghosts,
      "undeclared reads: " + ", ".join(f"{k} ({v})" for k, v in sorted(ghosts.items())))

# ── (c) config.local machine list == the scope=machine key set ─────────────────────────────────────
machine = {k for k, v in COLS.items() if v["scope"] == "machine"}
# Extract the machine-key list the doc row enumerates: manifest-key tokens named in its description.
listed = {t for t in re.findall(r'[A-Z][A-Z0-9_]+', CONFIG_LOCAL_DESC) if t in KEYS}
missing_from_doc = sorted(machine - listed)
extra_in_doc     = sorted(listed - machine)
check("c: config.local row lists exactly the scope=machine keys",
      not missing_from_doc and not extra_in_doc,
      f"machine keys absent from the row: {missing_from_doc}; non-machine keys listed: {extra_in_doc}")

# ── (d) no scope=machine key is a governance-map adoption target ────────────────────────────────────
gov_keys = set()
with open(GOVMAP, encoding="utf-8") as f:
    for line in f:
        parts = line.rstrip("\n").split("\t")
        if len(parts) >= 3 and parts[1] == "config-key":
            m = re.match(r'([A-Z][A-Z0-9_]+)=', parts[2])
            if m:
                gov_keys.add(m.group(1))
machine_in_gov = sorted(machine & gov_keys)
check("d: no scope=machine key appears in governance-map.tsv", not machine_in_gov,
      "machine keys wrongly in governance-map: " + ", ".join(machine_in_gov))

# ── (e) every agent-watch/dep-watcher-read manifest key carries requires=watcher ───────────────────
watch_src = ""
for name in ("agent-watch.sh", "dep-watcher.sh"):
    p = os.path.join(ROOT, "scripts/herd", name)
    if os.path.isfile(p):
        watch_src += "\n" + open(p, encoding="utf-8", errors="replace").read()
bad_requires = sorted(k for k in KEYS if is_read(k, watch_src) and COLS[k]["requires"] != "watcher")
check("e: watcher-read keys carry requires=watcher", not bad_requires,
      "read by agent-watch/dep-watcher but requires!=watcher: "
      + ", ".join(f"{k} (requires='{COLS[k]['requires']}')" for k in bad_requires))

# ── (f) config.example MODEL tier defaults match herd-config.sh fallbacks ──────────────────────────
# NOTE on scope: templates/config.example is an EXAMPLE, not a pure defaults dump — it intentionally
# carries illustrative non-default values for project-specific keys (HERD_REPO, DENY_PATHS, MERGE_POLICY,
# HERD_THEME, …), so a blanket example==fallback compare would false-flag by design. The keys with a
# STRICT default-parity contract are the model tiers: the value config.example seeds a fresh project is
# exactly what herd-config.sh must fall back to when the key is unset. This guards the "Opus is an
# escalation tier, not a default" migration (HERD-161) from drifting the loader fallback out of the docs.
loader = open(LOADER, encoding="utf-8").read()
# herd-config.sh declares each fallback via `: "${KEY:="v"}"`. The eco block (TOKEN_MODE=eco) assigns
# some MODEL_* FIRST; the unconditional STANDARD defaults come LATER and are what an unset config
# resolves to — iterate in source order and keep the LAST literal def per key.
fallback = {}
for m in re.finditer(r'^\s*:\s*"\$\{([A-Z][A-Z0-9_]+):="([^"$]*)"\}"', loader, re.M):
    fallback[m.group(1)] = m.group(2)  # `[^"$]` skips dynamic `$VAR` fallbacks (e.g. MODEL_ADVISE:=$MODEL_FEATURE)

# config.example lists each MODEL role; prefer the ACTIVE (uncommented) assignment over a commented
# illustration (e.g. the `# MODEL_QUICK="headless:…"` driver-prefix example above the real default).
example_active = {}
example_any = {}
for line in open(CFG_EXAMPLE, encoding="utf-8"):
    m = re.match(r'^(\s*#?\s*)([A-Z][A-Z0-9_]+)="([^"]*)"', line)
    if not m:
        continue
    commented = "#" in m.group(1)
    k, v = m.group(2), m.group(3)
    example_any.setdefault(k, v)
    if not commented:
        example_active.setdefault(k, v)

MODEL_TIERS = [k for k in KEYS if k.startswith("MODEL_")]
drift = []
for k in sorted(MODEL_TIERS):
    ev = example_active.get(k, example_any.get(k))
    if ev is None or k not in fallback:
        continue  # not documented with a literal in config.example, or dynamic fallback — nothing to compare
    if fallback[k] != ev:
        drift.append(f"{k}: config.example='{ev}' vs herd-config.sh fallback='{fallback[k]}'")
check("f: config.example model-tier defaults match herd-config.sh fallbacks", not drift,
      "; ".join(drift))

print()
if failures:
    print(f"{len(failures)} CHECK(S) FAILED: {', '.join(failures)}", file=sys.stderr)
    sys.exit(1)
print("ALL PASS (6 manifest self-enforcement checks)")
PY
