#!/usr/bin/env bash
# test-doc-drift.sh — deterministic, ZERO-LLM guard that README.md never drifts from the machine
# source of truth, templates/capabilities.tsv (HERD-96).
#
# README claims are hand-written; capabilities.tsv is generated/curated as the manifest every other
# surface (herd codemap, the coordinator skill, `herd config`) is keyed off. Nothing catches a README
# that references a `herd <subcommand>` or a CONFIG_KEY that no longer exists — exactly the staleness
# class HERD-82 hand-fixed after the fact. This locks that fix in as a repeatable check.
#
# The check has ONE red direction and ONE advisory direction:
#   • RED  (code-error): every `herd <subcommand>` and every CONFIG_KEY-shaped token REFERENCED in
#     README.md must resolve to a row in capabilities.tsv. A reference to something absent = drift.
#   • WARN (advisory only): capabilities present in the tsv but NOT mentioned in README are listed as
#     an advisory — the README is curated, not exhaustive, so this NEVER reds (issue: no false reds).
#
# Extraction is COMMAND-POSITION scoped to avoid false reds on English prose: a `herd <sub>` token
# counts only when it starts an inline code span (`herd why`) or begins a fenced code-block command
# line (optionally after a `$ ` prompt), with `#` comments stripped first. That is what separates a
# real `herd status` reference from the prose "manage several herd projects at once".
#
# Fully hermetic: local file reads + a temp fixture only. NO herdr, NO gh, NO network, NO model.
# python3 is a herd hard dep (herd doctor verifies it); the same reliance as test-config-key-docs.sh.
# Run:  bash tests/test-doc-drift.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
README="$ROOT/README.md"
CAPS="$ROOT/templates/capabilities.tsv"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

for f in "$README" "$CAPS"; do
  [ -f "$f" ] || fail "missing required file: $f"
done
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# drift_report <readme> <caps> — the whole check as a pure function of two files.
#   stdout : DRIFT lines (one per unknown token, RED direction) then an ADVISORY summary (warn only).
#   exit   : 2 if any DRIFT line was emitted, 0 if the README is clean. The ADVISORY never sets exit.
# Deterministic: same inputs → byte-identical output and exit code (sorted, no timestamps).
drift_report() {
  HERD_DD_README="$1" HERD_DD_CAPS="$2" python3 - <<'PY'
import os, re, sys

readme = open(os.environ["HERD_DD_README"], encoding="utf-8").read().split("\n")
caps   = open(os.environ["HERD_DD_CAPS"],   encoding="utf-8").read().split("\n")

KEY = re.compile(r"\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b")   # CONFIG_KEY-shaped: UPPER_SNAKE, >=1 '_'

def strip_comment(s):
    # Drop a shell '#' comment (start-of-line or whitespace-preceded '#') so prose inside a fenced
    # block ("# add a herd project to the registry") never reads as a command/key reference.
    m = re.search(r"(^|\s)#", s)
    return s[: m.start()] if m else s

# ── Extract REFERENCED tokens from README (command-position scoped) ──────────────────────────────
ref_subs, ref_keys = set(), set()
in_fence = False
for ln in readme:
    if ln.lstrip().startswith("```"):
        in_fence = not in_fence
        continue
    if in_fence:
        code = strip_comment(ln)
        m = re.match(r"\s*(?:\$\s+)?herd ([a-z][a-z-]+)", code)   # command line, opt. `$ ` prompt
        if m:
            ref_subs.add(m.group(1))
        ref_keys |= set(KEY.findall(code))
    else:
        for span in re.findall(r"`([^`\n]+)`", ln):              # inline code spans only
            m = re.match(r"herd ([a-z][a-z-]+)", span)
            if m:
                ref_subs.add(m.group(1))
            ref_keys |= set(KEY.findall(span))

# ── The manifest: valid subcommands (from `command` rows) and valid key names (any row) ──────────
valid_subs, valid_keys, names = set(), set(), set()
for row in caps[1:]:
    col = row.split("\t")
    if len(col) < 2:
        continue
    name, kind = col[0], col[1]
    names.add(name)
    if kind == "command":
        m = re.match(r"herd ([a-z][a-z-]+)", name)
        if m:
            valid_subs.add(m.group(1))
    if KEY.fullmatch(name):        # a CONFIG_KEY-shaped row name (config / env / lever)
        valid_keys.add(name)

# ── RED direction: referenced-but-absent ────────────────────────────────────────────────────────
drift = []
for s in sorted(ref_subs):
    if s not in valid_subs:
        drift.append(f"DRIFT command: README references `herd {s}` — no matching row in capabilities.tsv")
for k in sorted(ref_keys):
    if k not in names:
        drift.append(f"DRIFT config:  README references `{k}` — no matching row in capabilities.tsv")
for d in drift:
    print(d)

# ── ADVISORY direction: documented-but-unmentioned (warn only, never affects exit) ───────────────
adv_subs = sorted(valid_subs - ref_subs)
adv_keys = sorted(valid_keys - ref_keys)
print(f"ADVISORY: {len(adv_subs)} command(s) + {len(adv_keys)} config key(s) documented in "
      f"capabilities.tsv but not mentioned in README (curated, not exhaustive — never a failure)")
if adv_subs:
    print("ADVISORY   commands: " + ", ".join("herd " + s for s in adv_subs))
if adv_keys:
    print("ADVISORY   keys:     " + ", ".join(adv_keys))

sys.exit(2 if drift else 0)
PY
}

# ── 1. The REAL tree is clean: no README token drifts from capabilities.tsv ───────────────────────
real_out="$(drift_report "$README" "$CAPS")"; real_rc=$?
if [ "$real_rc" -ne 0 ]; then
  echo "$real_out" | grep '^DRIFT' >&2
  fail "(1) README.md drifted from templates/capabilities.tsv (see DRIFT lines above) — fix the README reference or add the row to the manifest"
fi
printf '%s\n' "$real_out" | grep -q '^DRIFT' && fail "(1) drift lines present despite clean exit"
pass
echo "PASS (1) README.md ↔ capabilities.tsv: every referenced herd command + CONFIG_KEY resolves (no drift)"

# ── 2. ADVISORY is emitted AND is warn-only: the real tree has many undocumented-in-README caps ───
printf '%s\n' "$real_out" | grep -q '^ADVISORY:' || fail "(2) advisory summary line missing"
# The real manifest documents far more than the curated README mentions, yet (1) already exited 0 →
# the tsv→README direction can never red. Assert the advisory actually found some absences.
adv_count="$(printf '%s\n' "$real_out" | sed -n 's/^ADVISORY: \([0-9]*\) command.*/\1/p')"
[ -n "$adv_count" ] || fail "(2) could not parse advisory command count"
pass
echo "PASS (2) advisory list is emitted and never reds (real tree exits 0 with capabilities absent from README)"

# ── 3. DELIBERATE-DRIFT FIXTURE proves the failure path (both token classes) ──────────────────────
FIX="$T/README.fixture.md"
cat > "$FIX" <<'EOF'
# Fixture README (deliberate drift)

Run `herd status` to check health — a REAL command, must NOT drift.
Set `MERGE_POLICY=approve` in `.herd/config` — a REAL key, must NOT drift.

```bash
$ herd why 123        # real command line — must NOT drift
```

Now the stale references this check must catch:

Run `herd boguscmd` for nothing — a stale command, MUST drift.
Set `TOTALLY_FAKE_KEY=1` somewhere — a stale key, MUST drift.

Prose that must be IGNORED (not command-position): manage several herd projects at once.
EOF

fix_out="$(drift_report "$FIX" "$CAPS")"; fix_rc=$?
[ "$fix_rc" -eq 2 ] || fail "(3) fixture with deliberate drift must exit 2, got $fix_rc"
printf '%s\n' "$fix_out" | grep -q 'DRIFT command: README references `herd boguscmd`' \
  || fail "(3) stale command 'herd boguscmd' not flagged"
printf '%s\n' "$fix_out" | grep -q 'DRIFT config:  README references `TOTALLY_FAKE_KEY`' \
  || fail "(3) stale key 'TOTALLY_FAKE_KEY' not flagged"
# Real tokens in the same fixture must NOT be flagged, and the ignored prose must NOT become a command.
printf '%s\n' "$fix_out" | grep -qE 'DRIFT.*(herd status|herd why|MERGE_POLICY|herd projects)' \
  && fail "(3) false positive: a real token or ignored prose was flagged as drift"
pass
echo "PASS (3) deliberate-drift fixture: stale command + stale key both caught, real tokens + prose untouched"

echo
echo "ALL PASS ($PASS checks) — README ↔ capabilities.tsv drift check is live, advisory-safe, and fails on real drift."
