#!/usr/bin/env bash
# test-healthcheck-project-env-manifest.sh — closes a manifest-scan blind spot (HERD-497).
#
# tests/test-config-manifest.sh's GHOST scan (check b) is deliberately scoped to "the engine":
# scripts/herd/*.sh (+ backends/work-units) and bin/herd — see its engine_files(). That scope is
# correct for the engine's OWN config surface, but .herd/healthcheck.project.sh is NOT engine
# surface: it is a PER-PROJECT file `herd init` seeds from a stack template (healthcheck.node.sh /
# .go.sh / .rust.sh / .java.sh / .docs.sh / the python/unknown default), so a knob it reads is
# specific to THIS project's own copy, never the shared templates/capabilities.tsv every herdkit
# install reads from $HERDKIT_HOME/templates. Because it sits outside engine_files(), a
# `${KEY:-default}` env read added there is invisible to check (b) no matter how undocumented it
# is — exactly the "guard reports clean because its scan surface misses where the defect lives"
# shape (HERD-497 swept and found five such reads already unmanifested: HEALTHCHECK_SUITE_WORKERS,
# HEALTHCHECK_SUITE_TIMEOUT, HERD_SHELLCHECK_RETRY_SECS, HEALTHCHECK_BATS_REAP_GRACE,
# HERD_LEAKGUARD_SETTLE_SECS — now documented as kind=env rows in templates/capabilities.tsv).
#
# This test scans .herd/*.sh directly (currently .herd/healthcheck.project.sh and
# .herd/claude-hardcode-lint.sh — herdkit's own dogfood project files) and requires every
# non-exempt `${KEY:-…}` / `${KEY:=…}` read to be a DECLARED row (any kind) in
# templates/capabilities.tsv, or be in EXEMPT_NAMES below with a one-line reason. Mirrors
# test-config-manifest.sh's comment/local-var discipline so the two scans can never disagree on
# what counts as a "read", and carries the same "scan still bites" probe discipline (HERD-203)
# so this can never decay into a vacuous pass.
#
# Run:  bash tests/test-healthcheck-project-env-manifest.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
CAPS="$ROOT/templates/capabilities.tsv"

[ -f "$CAPS" ] || { echo "FAIL: missing $CAPS" >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }

ROOT="$ROOT" CAPS="$CAPS" python3 - <<'PY'
import os, re, sys, glob

ROOT = os.environ["ROOT"]
CAPS = os.environ["CAPS"]

failures = []
def check(name, ok, detail=""):
    if ok:
        print(f"PASS ({name})")
    else:
        failures.append(name)
        print(f"FAIL ({name}) {detail}", file=sys.stderr)

# ── Declared keys: ANY row name in capabilities.tsv, regardless of kind (env rows count) ──────────
DECLARED = set()
with open(CAPS, encoding="utf-8") as f:
    f.readline()  # header
    for line in f:
        c = line.rstrip("\n").split("\t")
        if c and c[0]:
            DECLARED.add(c[0])

# ── The scan surface: herdkit's own per-project .herd/*.sh dogfood files ───────────────────────────
def project_files():
    return sorted(f for f in glob.glob(os.path.join(ROOT, ".herd/*.sh")) if os.path.isfile(f))

def strip_comments(text):
    return "\n".join("" if re.match(r'^\s*#', ln) else ln for ln in text.split("\n"))

# ── Vars a `${KEY:-…}` read here is NOT a .herd/config-shaped knob for, with the reason ─────────────
EXEMPT_NAMES = {
    "TMPDIR",         # POSIX shell-standard env var, not a herdkit knob
    "HERMETIC_TEST",  # cross-suite test-identity seam var (tests/test-*.sh export it themselves,
                       # dozens of call sites — see tests/test-daemon-hermeticity.sh), never a
                       # .herd/config knob an operator would set
    "BATS_TEST_TIMEOUT",  # bats-core's OWN recognized per-test-timeout env var; herdkit only reads
                           # an operator override and re-exports it down to bats, it does not own it
}

def scan_ghosts(files):
    found = {}
    for f in files:
        text = strip_comments(open(f, encoding="utf-8", errors="replace").read())
        for m in re.finditer(r'\$\{([A-Z][A-Z0-9_]+):[-=]', text):
            k = m.group(1)
            if k in DECLARED or k in EXEMPT_NAMES:
                continue
            found.setdefault(k, os.path.relpath(f, ROOT))
    return found

ghosts = scan_ghosts(project_files())
check("a: every .herd/*.sh env read is a declared manifest key or an explicit exemption",
      not ghosts, "undeclared reads: " + ", ".join(f"{k} ({v})" for k, v in sorted(ghosts.items())))

# ── The scan still BITES (HERD-203 discipline): synthetic probes that must trip it ─────────────────
FAKE = "__probe.sh"
probes = [
    ("undeclared, non-exempt key",  '[ -n "${HERD_497_NO_SUCH_KEY:-}" ]',        "HERD_497_NO_SUCH_KEY"),
    ("comment is not a read",       '# echo "${HERD_497_NO_SUCH_KEY:-}"',        None),
]
missed = []
for label, body, want in probes:
    text = strip_comments(body)
    found = {}
    for m in re.finditer(r'\$\{([A-Z][A-Z0-9_]+):[-=]', text):
        k = m.group(1)
        if k in DECLARED or k in EXEMPT_NAMES:
            continue
        found[k] = FAKE
    if want is None:
        if found:
            missed.append(f"{label} (flagged {sorted(found)})")
    elif want not in found:
        missed.append(f"{label} ({want})")
# a currently-declared real key must NOT be flagged even though it matches the read shape
_real = sorted(DECLARED)[0] if DECLARED else None
if _real:
    text = strip_comments(f'x="${{{_real}:-4}}"')
    found = {}
    for m in re.finditer(r'\$\{([A-Z][A-Z0-9_]+):[-=]', text):
        k = m.group(1)
        if k in DECLARED or k in EXEMPT_NAMES:
            continue
        found[k] = FAKE
    if _real in found:
        missed.append(f"a declared key ({_real}) was misjudged a ghost")
check("a': the scan still catches real ghosts and never flags a declared/exempt/comment name",
      not missed, "misjudged: " + ", ".join(missed))

print()
if failures:
    print(f"{len(failures)} CHECK(S) FAILED: {', '.join(failures)}", file=sys.stderr)
    sys.exit(1)
print("ALL PASS (2 checks: .herd/*.sh env-knob manifest coverage)")
PY
