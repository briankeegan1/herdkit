#!/usr/bin/env bash
# handoff.sh — the shared format + emitter for the BUILDER HANDOFF SUMMARY (HERD-106, research G4).
#
# When a builder finishes, the coordinator/watcher want a concise, STRUCTURED account of what was
# built — not a scrape of the multi-KB transcript. This file is the single source of truth for a
# compact (~1K-token) completion report the builder emits at the END of its run, embedded in the PR
# body as a fenced block the watcher/coordinator can read deterministically:
#
#   <!-- herd-handoff:v1 -->
#   ### 🐑 Builder handoff
#   - **Changed:** one-line summary of what this PR does
#   - **Files:** scripts/herd/handoff.sh, tests/test-handoff-summary.sh
#   - **Decisions:** self-contained script over editing the shared lane preamble; fenced block reused
#   - **Verification:** bash scripts/herd/healthcheck.sh <dir> → PASS
#   - **Follow-ups:** none  (or: see the HUMAN-VERIFY block above)
#   <!-- /herd-handoff:v1 -->
#
# The five fields map 1:1 to the report contract: what changed + file surface (Changed + Files), key
# decisions/tradeoffs (Decisions), the verification run + its result (Verification), and any
# HUMAN-VERIFY / follow-ups (Follow-ups). The sentinels are HTML comments, so the block is invisible
# in the rendered PR yet trivially machine-locatable; a version tag (:v1) lets the format evolve.
#
# Two usages, one file — exactly like human-verify.sh:
#
#   SOURCED (never executed) by a consumer AFTER herd-config.sh — the read side:
#       . "$HERE/handoff.sh"
#       body="$(gh pr view "$pr" --json body -q .body)"
#       if printf '%s' "$body" | handoff_has; then
#         printf '%s' "$body" | handoff_fields      # key=value lines for the coordinator/watcher
#       fi
#
#   EXECUTED as a CLI — the write side the builder calls at the end of its run:
#       bash handoff.sh emit <pr#> \
#         --changed "…" --files "a.sh, b.sh" --decisions "…" \
#         --verification "healthcheck → PASS" --followups "none"
#     'emit' UPSERTS the block into the PR body (replaces an existing one, else appends), so a
#     re-emission is idempotent. 'render' prints the block to stdout without touching any PR.
#
# CONTRACT (why this is safe to add everywhere):
#   • ADDITIVE + FAIL-SOFT: absent a handoff block, every parser returns empty / non-zero and callers
#     see byte-identical behavior. Nothing in the engine REQUIRES a handoff; it only enriches the
#     coordinator/watcher view when present.
#   • BEST-EFFORT PARSE: any parse failure (no python3, malformed body) prints nothing rather than
#     erroring, so a consumer under `set -euo pipefail` is never broken.
#   • ONE BLOCK PER BODY: the parser reads the FIRST block; emit collapses to a single block.

# ── Read side (sourceable parser) ────────────────────────────────────────────────────────────────

# handoff_extract — read a PR body on stdin; print the handoff block verbatim (both sentinels
# inclusive), or nothing when the body carries no block. Best-effort: any failure prints nothing.
handoff_extract() {
  python3 -c '
import sys, re
lines = sys.stdin.read().splitlines()
begin = re.compile(r"^\s*<!--\s*herd-handoff(?::v\d+)?\s*-->\s*$", re.IGNORECASE)
end   = re.compile(r"^\s*<!--\s*/\s*herd-handoff(?::v\d+)?\s*-->\s*$", re.IGNORECASE)
b = None
for i, ln in enumerate(lines):
    if begin.match(ln):
        b = i
        break
if b is None:
    sys.exit(0)
e = None
for j in range(b + 1, len(lines)):
    if end.match(lines[j]):
        e = j
        break
if e is None:
    sys.exit(0)
print("\n".join(lines[b:e + 1]))
' 2>/dev/null || true
}

# handoff_has — read a PR body on stdin; return 0 iff it carries a complete handoff block (both
# sentinels present, in order). A bare/half-open marker is NOT a block.
handoff_has() {
  local _out
  _out="$(handoff_extract)"
  [ -n "$_out" ]
}

# handoff_fields — read a PR body on stdin; print the block's fields as `key=value` lines (lowercased,
# de-bulleted keys: changed, files, decisions, verification, followups). Nothing when no block. This
# is the machine surface the coordinator/watcher consume instead of scraping the transcript.
handoff_fields() {
  python3 -c '
import sys, re
lines = sys.stdin.read().splitlines()
begin = re.compile(r"^\s*<!--\s*herd-handoff(?::v\d+)?\s*-->\s*$", re.IGNORECASE)
end   = re.compile(r"^\s*<!--\s*/\s*herd-handoff(?::v\d+)?\s*-->\s*$", re.IGNORECASE)
bullet = re.compile(r"^\s*(?:[-*+]\s+|\d+[.)]\s+)")
b = e = None
for i, ln in enumerate(lines):
    if b is None and begin.match(ln):
        b = i; continue
    if b is not None and end.match(ln):
        e = i; break
if b is None or e is None:
    sys.exit(0)
for ln in lines[b + 1:e]:
    s = bullet.sub("", ln).strip()
    s = s.replace("**", "")
    if ":" not in s:
        continue
    k, v = s.split(":", 1)
    k = re.sub(r"[^a-z0-9]+", "", k.strip().lower())
    v = v.strip()
    if k:
        print("%s=%s" % (k, v))
' 2>/dev/null || true
}

# handoff_field <key> — read a PR body on stdin; print the value of one field (e.g. `changed`),
# empty when absent. Convenience over handoff_fields for a single lookup.
handoff_field() {
  local _key="${1:-}"
  [ -n "$_key" ] || return 0
  _key="$(printf '%s' "$_key" | tr '[:upper:]' '[:lower:]' | tr -cd 'a-z0-9')"
  handoff_fields | sed -n "s/^${_key}=//p" | head -n1  # pipe-ok: head in a command or process substitution; pipeline status not gated
}

# ── Write side (rendering) ───────────────────────────────────────────────────────────────────────

# _handoff_oneline — collapse a field value to a single line (newlines/tabs → spaces, squeezed), so
# the one-line-per-field parse contract holds even if a caller passes a multi-line value.
_handoff_oneline() {
  printf '%s' "${1:-}" | tr '\n\t' '  ' | tr -s ' ' | sed 's/^ *//; s/ *$//'
}

# handoff_render — print a well-formed handoff block from the HANDOFF_* env vars (set by the CLI arg
# parser below): HANDOFF_CHANGED, HANDOFF_FILES, HANDOFF_DECISIONS, HANDOFF_VERIFICATION,
# HANDOFF_FOLLOWUPS. Empty fields render as an em dash so the block is always shape-complete.
handoff_render() {
  local changed files decisions verification followups
  changed="$(_handoff_oneline "${HANDOFF_CHANGED:-}")"
  files="$(_handoff_oneline "${HANDOFF_FILES:-}")"
  decisions="$(_handoff_oneline "${HANDOFF_DECISIONS:-}")"
  verification="$(_handoff_oneline "${HANDOFF_VERIFICATION:-}")"
  followups="$(_handoff_oneline "${HANDOFF_FOLLOWUPS:-}")"
  printf '%s\n' '<!-- herd-handoff:v1 -->'
  printf '%s\n' '### 🐑 Builder handoff'
  printf -- '- **Changed:** %s\n'      "${changed:-—}"
  printf -- '- **Files:** %s\n'        "${files:-—}"
  printf -- '- **Decisions:** %s\n'    "${decisions:-—}"
  printf -- '- **Verification:** %s\n' "${verification:-—}"
  printf -- '- **Follow-ups:** %s\n'   "${followups:-—}"
  printf '%s\n' '<!-- /herd-handoff:v1 -->'
}

# handoff_upsert_body — read a PR body on stdin; print it with the handoff block set to a fresh
# render: any existing block (first sentinel through its close) is REMOVED, then the freshly rendered
# block is appended after a blank-line separator. Idempotent — re-emitting replaces, never stacks.
handoff_upsert_body() {
  local _body _stripped _rendered
  _body="$(cat)"
  _rendered="$(handoff_render)"
  _stripped="$(printf '%s' "$_body" | python3 -c '
import sys, re
lines = sys.stdin.read().splitlines()
begin = re.compile(r"^\s*<!--\s*herd-handoff(?::v\d+)?\s*-->\s*$", re.IGNORECASE)
end   = re.compile(r"^\s*<!--\s*/\s*herd-handoff(?::v\d+)?\s*-->\s*$", re.IGNORECASE)
out, i, n = [], 0, len(lines)
while i < n:
    if begin.match(lines[i]):
        j = i + 1
        while j < n and not end.match(lines[j]):
            j += 1
        i = j + 1 if j < n else n          # drop the block (and its close, if found)
        continue
    out.append(lines[i]); i += 1
# trim trailing blank lines left behind so we control the single separator below
while out and out[-1].strip() == "":
    out.pop()
print("\n".join(out))
' 2>/dev/null || printf '%s' "$_body")"
  if [ -n "$_stripped" ]; then
    printf '%s\n\n%s\n' "$_stripped" "$_rendered"
  else
    printf '%s\n' "$_rendered"
  fi
}

# ── CLI ──────────────────────────────────────────────────────────────────────────────────────────

# _handoff_parse_flags — consume the shared --changed/--files/--decisions/--verification/--followups
# flags into the HANDOFF_* env vars. Unknown flags are ignored (forward-compatible). Sets a global
# array _HANDOFF_REST with any leftover positional args (unused today).
_handoff_parse_flags() {
  export HANDOFF_CHANGED="${HANDOFF_CHANGED:-}"
  export HANDOFF_FILES="${HANDOFF_FILES:-}"
  export HANDOFF_DECISIONS="${HANDOFF_DECISIONS:-}"
  export HANDOFF_VERIFICATION="${HANDOFF_VERIFICATION:-}"
  export HANDOFF_FOLLOWUPS="${HANDOFF_FOLLOWUPS:-}"
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --changed)            HANDOFF_CHANGED="${2:-}";      shift 2 || shift ;;
      --files)              HANDOFF_FILES="${2:-}";        shift 2 || shift ;;
      --decisions)          HANDOFF_DECISIONS="${2:-}";    shift 2 || shift ;;
      --verification|--verify) HANDOFF_VERIFICATION="${2:-}"; shift 2 || shift ;;
      --followups|--follow-ups) HANDOFF_FOLLOWUPS="${2:-}";   shift 2 || shift ;;
      *) shift ;;
    esac
  done
}

_handoff_cli() {
  local cmd="${1:-}"; shift || true
  case "$cmd" in
    render)
      _handoff_parse_flags "$@"
      handoff_render
      ;;
    emit)
      local pr="${1:-}"; shift || true
      case "$pr" in ''|*[!0-9]*) echo "usage: handoff.sh emit <pr#> [--changed … --files … --decisions … --verification … --followups …]" >&2; return 2 ;; esac
      _handoff_parse_flags "$@"
      command -v gh >/dev/null 2>&1 || { echo "handoff: gh not found — cannot emit to PR #$pr" >&2; return 1; }
      local body new tmp
      body="$(gh pr view "$pr" --json body -q .body 2>/dev/null || true)"
      new="$(printf '%s' "$body" | handoff_upsert_body)"
      tmp="$(mktemp)"; printf '%s\n' "$new" > "$tmp"
      if gh pr edit "$pr" --body-file "$tmp" >/dev/null 2>&1; then
        rm -f "$tmp"
        echo "🐑 handoff emitted to PR #$pr"
      else
        rm -f "$tmp"
        echo "handoff: gh pr edit failed for PR #$pr" >&2
        return 1
      fi
      ;;
    show)
      local pr="${1:-}"
      case "$pr" in ''|*[!0-9]*) echo "usage: handoff.sh show <pr#>" >&2; return 2 ;; esac
      command -v gh >/dev/null 2>&1 || { echo "handoff: gh not found" >&2; return 1; }
      gh pr view "$pr" --json body -q .body 2>/dev/null | handoff_extract
      ;;
    fields)
      # Read a PR body on stdin (or, with a numeric arg, fetch it via gh) → key=value lines.
      local pr="${1:-}"
      if [ -n "$pr" ]; then
        case "$pr" in *[!0-9]*) echo "usage: handoff.sh fields [<pr#>]  (else reads body on stdin)" >&2; return 2 ;; esac
        command -v gh >/dev/null 2>&1 || { echo "handoff: gh not found" >&2; return 1; }
        gh pr view "$pr" --json body -q .body 2>/dev/null | handoff_fields
      else
        handoff_fields
      fi
      ;;
    ''|-h|--help|help)
      cat >&2 <<'USAGE'
handoff.sh — builder handoff summary (HERD-106)
  render  [flags]           print a handoff block to stdout
  emit    <pr#> [flags]     upsert the block into a PR body (idempotent)
  show    <pr#>             print the handoff block from a PR body
  fields  [<pr#>]           print key=value fields (from a PR, or a body on stdin)
flags: --changed  --files  --decisions  --verification  --followups
USAGE
      return 2
      ;;
    *) echo "handoff: unknown command '$cmd' (try: render|emit|show|fields)" >&2; return 2 ;;
  esac
}

# Executed (not sourced) → run the CLI. Sourced → only the functions above are defined.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  _handoff_cli "$@"
fi
