#!/usr/bin/env bash
# doc-drift-lint.sh — THE shared doc-drift guard (HERD-168 / extends HERD-96): every
# `herd <subcommand>` REFERENCED in README.md + docs/*.md (and every CONFIG_KEY-shaped token
# REFERENCED in README.md) must resolve to a row in templates/capabilities.tsv. A doc that
# references a command absent from the manifest is a CODE error — the docs-drift analog of the
# conformance / caps-sync ratchet.
#
# ONE implementation, sourced (never executed) by BOTH gate surfaces so they can never disagree:
#     • scripts/herd/healthcheck.sh  — the builder's LIGHT pre-PR gate (docs-only diffs run light
#                                      under HEALTHCHECK_HEAVY_GLOB, so this is the gate that
#                                      actually catches doc drift before merge)
#     • tests/test-doc-drift.sh      — the hermetic unit proof (fixtures + real-tree check)
#                                       which herd.bats / the heavy suite wraps
#
# Extraction is COMMAND-POSITION scoped (inline code spans + fenced command lines, `#` comments
# stripped) so English prose like "manage several herd projects at once" never reads as a
# command. Config keys are checked on README.md only — design docs (audits, spikes, SOPs) name
# many internal/env tokens that are not capability knobs; flagging them would false-red a clean
# tree. Commands are checked on README.md + every top-level docs/*.md.
#
# herd_doc_drift_lint [<root>]
#   Run against <root> (default: cwd). Prints DRIFT lines on stdout (one per unknown token) then
#   an ADVISORY summary (warn only). The caller owns the ❌ headline and the exit presentation.
#   Exit: 0 = clean · 1 = drift (DRIFT lines on stdout) · 2 = skipped (infra; NEVER a red).
#   On a skip, $HERD_DOC_DRIFT_SKIP_REASON carries the one-line why.
#
# herd_doc_drift_report <caps> <readme> [doc.md ...]
#   Pure-function form used by the hermetic test fixtures. Same stdout/exit contract as above
#   (no skip path — missing files are the caller's problem). Exit 0 clean / 2 if any DRIFT line.
#
# Fail-soft by construction: no capabilities.tsv / no python3 → skip, never a false red in a
# consuming project that has neither a manifest nor our docs surface. SHIP-DORMANT: a clean
# herdkit tree exits 0 with no DRIFT lines (byte-identical advisory text for the same inputs).

HERD_DOC_DRIFT_SKIP_REASON=""

# herd_doc_drift_report <caps> <readme> [doc.md ...] — pure function of the listed files.
# stdout: DRIFT lines then ADVISORY summary. exit 2 if any DRIFT, else 0.
herd_doc_drift_report() {
  local _dd_caps="${1:-}" _dd_readme="${2:-}"
  shift 2 2>/dev/null || true
  # Remaining args are extra doc files (docs/*.md). Empty is fine (README-only).
  HERD_DD_CAPS="$_dd_caps" HERD_DD_README="$_dd_readme" HERD_DD_DOCS="$(printf '%s\n' "$@")" \
    python3 - <<'PY'
import os, re, sys

caps_path = os.environ["HERD_DD_CAPS"]
readme_path = os.environ.get("HERD_DD_README") or ""
docs = [p for p in os.environ.get("HERD_DD_DOCS", "").split("\n") if p]

KEY = re.compile(r"\b([A-Z][A-Z0-9]*(?:_[A-Z0-9]+)+)\b")  # CONFIG_KEY-shaped: UPPER_SNAKE, ≥1 '_'

def strip_comment(s):
    # Drop a shell '#' comment so prose inside a fenced block never reads as a command/key.
    m = re.search(r"(^|\s)#", s)
    return s[: m.start()] if m else s

def extract(path, want_keys):
    """Command-position scoped extraction. want_keys=False skips CONFIG_KEY harvesting."""
    ref_subs, ref_keys = set(), set()
    try:
        lines = open(path, encoding="utf-8").read().split("\n")
    except OSError as e:
        print(f"DRIFT infra: cannot read {path}: {e}", file=sys.stderr)
        return ref_subs, ref_keys
    in_fence = False
    for ln in lines:
        if ln.lstrip().startswith("```"):
            in_fence = not in_fence
            continue
        if in_fence:
            code = strip_comment(ln)
            m = re.match(r"\s*(?:\$\s+)?herd ([a-z][a-z-]+)", code)
            if m:
                ref_subs.add(m.group(1))
            if want_keys:
                ref_keys |= set(KEY.findall(code))
        else:
            for span in re.findall(r"`([^`\n]+)`", ln):
                m = re.match(r"herd ([a-z][a-z-]+)", span)
                if m:
                    ref_subs.add(m.group(1))
                if want_keys:
                    ref_keys |= set(KEY.findall(span))
    return ref_subs, ref_keys

# ── The manifest ──────────────────────────────────────────────────────────────────────────────
valid_subs, valid_keys, names = set(), set(), set()
try:
    caps_lines = open(caps_path, encoding="utf-8").read().split("\n")
except OSError as e:
    print(f"DRIFT infra: cannot read {caps_path}: {e}", file=sys.stderr)
    sys.exit(2)

for row in caps_lines[1:]:
    col = row.split("\t")
    if len(col) < 2:
        continue
    name, kind = col[0], col[1]
    names.add(name)
    if kind == "command":
        m = re.match(r"herd ([a-z][a-z-]+)", name)
        if m:
            valid_subs.add(m.group(1))
    if KEY.fullmatch(name):
        valid_keys.add(name)

# ── Extract references ────────────────────────────────────────────────────────────────────────
# README: commands + config keys (HERD-96). docs/*.md: commands only (HERD-168).
ref_subs, ref_keys = set(), set()
sub_where = {}  # sub -> sorted set of short labels
if readme_path:
    s, k = extract(readme_path, want_keys=True)
    ref_subs |= s
    ref_keys |= k
    for sub in s:
        sub_where.setdefault(sub, set()).add("README")
for d in docs:
    s, _ = extract(d, want_keys=False)
    ref_subs |= s
    label = os.path.basename(d)
    for sub in s:
        sub_where.setdefault(sub, set()).add(label)

# ── RED direction: referenced-but-absent ──────────────────────────────────────────────────────
drift = []
for s in sorted(ref_subs):
    if s not in valid_subs:
        where = ", ".join(sorted(sub_where.get(s, ()))) or "?"
        drift.append(
            f"DRIFT command: `{where}` reference(s) `herd {s}` — no matching command row in capabilities.tsv"
        )
for k in sorted(ref_keys):
    if k not in names:
        drift.append(
            f"DRIFT config:  README references `{k}` — no matching row in capabilities.tsv"
        )
for d in drift:
    print(d)

# ── ADVISORY direction: documented-but-unmentioned (warn only, never affects exit) ────────────
adv_subs = sorted(valid_subs - ref_subs)
adv_keys = sorted(valid_keys - ref_keys)
print(
    f"ADVISORY: {len(adv_subs)} command(s) + {len(adv_keys)} config key(s) documented in "
    f"capabilities.tsv but not mentioned in README/docs (curated, not exhaustive — never a failure)"
)
if adv_subs:
    print("ADVISORY   commands: " + ", ".join("herd " + s for s in adv_subs))
if adv_keys:
    print("ADVISORY   keys:     " + ", ".join(adv_keys))

sys.exit(2 if drift else 0)
PY
}

# herd_doc_drift_lint [<root>] — scan the default surface under <root> (or cwd).
# Exit 0 clean / 1 drift / 2 skipped. Prints DRIFT (+ advisory) lines on stdout when not skipped.
herd_doc_drift_lint() {
  local _dd_root="${1:-.}"
  local _dd_caps _dd_readme
  local -a _dd_docs=()
  local _dd_out _dd_rc
  local _f

  HERD_DOC_DRIFT_SKIP_REASON=""

  _dd_caps="$_dd_root/templates/capabilities.tsv"
  if [ ! -f "$_dd_caps" ]; then
    HERD_DOC_DRIFT_SKIP_REASON="no templates/capabilities.tsv in this tree"
    return 2
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    HERD_DOC_DRIFT_SKIP_REASON="python3 not available"
    return 2
  fi

  _dd_readme=""
  [ -f "$_dd_root/README.md" ] && _dd_readme="$_dd_root/README.md"

  # Top-level docs/*.md only (not docs/spikes/ — design notes name many non-capability tokens and
  # aspirational commands; the operator-facing surface is README + docs/*.md).
  if [ -d "$_dd_root/docs" ]; then
    for _f in "$_dd_root"/docs/*.md; do
      [ -f "$_f" ] || continue
      _dd_docs+=("$_f")
    done
  fi

  # Nothing to scan (no README, no docs) → clean no-op (a consuming project with only a manifest).
  if [ -z "$_dd_readme" ] && [ "${#_dd_docs[@]}" -eq 0 ]; then
    HERD_DOC_DRIFT_SKIP_REASON="no README.md or docs/*.md to scan"
    return 2
  fi

  if [ "${#_dd_docs[@]}" -gt 0 ]; then
    _dd_out="$(herd_doc_drift_report "$_dd_caps" "$_dd_readme" "${_dd_docs[@]}" 2>&1)"; _dd_rc=$?
  else
    _dd_out="$(herd_doc_drift_report "$_dd_caps" "$_dd_readme" 2>&1)"; _dd_rc=$?
  fi
  printf '%s\n' "$_dd_out"
  case "$_dd_rc" in
    0) return 0 ;;
    2) return 1 ;;   # pure-function exit 2 = drift → gate red (1)
    *) HERD_DOC_DRIFT_SKIP_REASON="doc-drift report failed (rc $_dd_rc)"
       return 2 ;;
  esac
}
