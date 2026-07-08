#!/usr/bin/env bash
# backlog-reconcile.sh — keep BACKLOG.md coherent when a PR MOVES or RENAMES the things backlog
# items point at (file paths, function names, section headers). When such a PR lands, entries that
# reference the OLD path/name dangle silently. This pass diffs the PR's rename/move surface, finds
# the backlog entries that still reference moved things, and (scribe-driven) enqueues ONE targeted
# scribe request so the scribe updates or flags each dangling entry — exactly like do_merge already
# enqueues a "reap" for the shipped item (agent-watch.sh), but for stale references instead.
#
# It NEVER edits BACKLOG.md itself (the coordinator owns the backlog, the scribe is the one writer)
# and it never merges or touches git history. The coordinator runs it as part of landing a
# cutover/extraction/rename PR:
#
#     bash scripts/herd/backlog-reconcile.sh run <pr# | <git-range>>
#
# Subcommands (surface/scan are the pure, hermetic seams the tests drive):
#   surface <range>   print the rename/move surface as TSV: <kind>\t<old>\t<new>
#                     kind ∈ rename (file moved) · delete (file removed) · symbol (def/header
#                     that existed before the PR and is gone after — renamed away or removed).
#   scan <range>      compute the surface, match it against $BACKLOG_FILE, print the DANGLING
#                     report (TSV: <kind>\t<old>\t<new>\t<lineno>\t<entry text>) or "NONE".
#   run <range>       scan; if anything dangles, enqueue ONE scribe request describing the surface
#                     + the affected entries; otherwise a clean no-op. Default when no subcommand.
#
# <range> is either a PR number (123 or #123 — resolved to the PR's base..head via gh, or a merge
# commit that names it) or anything `git diff` accepts (A..B, a commit, HEAD~1..HEAD, …).
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/herd-config.sh"
REPO="$PROJECT_ROOT"
BACKLOG="$REPO/$BACKLOG_FILE"
PY="$(command -v python3 || true)"

_recon_die() { echo "backlog-reconcile: $1" >&2; exit "${2:-1}"; }
[ -n "$PY" ] || _recon_die "python3 is required" 1

# ── backend gating (mirror tracker-state-sweep.sh:66-78, inverted) ────────────
# backlog-reconcile updates BACKLOG.md's prose references — the FILE backend's domain. A backend that
# dispatches state to an EXTERNAL tracker (linear/github/changelog: it defines _backend_update_state)
# is the source of truth instead of BACKLOG.md, so there are no dangling prose references to reconcile
# and the reconcile is INERT there — exactly _reconcile_via_ref's / tracker-state-sweep's backend-
# scoping, inverted (the sweep runs FOR tracker backends; reconcile runs AGAINST the file backend).
# SCRIBE_BACKEND_DIR overrides the backend dir (the same seam scribe-step.sh / tracker-state-sweep use).
BACKEND_DIR="${SCRIBE_BACKEND_DIR:-$HERE/backends}"
BACKEND_FILE="$BACKEND_DIR/${SCRIBE_BACKEND:-file}.sh"

# _recon_backend_manages_backlog — success (run) iff the active backend keeps BACKLOG.md as its source
# of truth (the file backend: no _backend_update_state op). A tracker backend (op present) → failure
# (inert). Sourced in an isolated subshell so the _backend_* funcs never leak. An unreadable/absent
# backend impl assumes the file-shaped default (run) so today's behaviour is unchanged for it.
_recon_backend_manages_backlog() {
  [ -f "$BACKEND_FILE" ] || return 0
  ! (
    # shellcheck source=/dev/null
    . "$BACKEND_FILE" 2>/dev/null || exit 1
    command -v _backend_update_state >/dev/null 2>&1
  )
}

# _resolve_range <arg> — turn a PR number or a git range into a range `git diff` understands.
# A bare/`#`-prefixed integer is a PR number: ask gh for its base..head oids (the PR's true change
# surface, merge-method-independent); fall back to a merge/commit whose message names the PR.
_resolve_range() {
  local arg="$1"
  case "$arg" in
    '#'[0-9]*|[0-9]*)
      local pr="${arg#\#}" pair m
      pair="$(cd "$REPO" && gh pr view "$pr" --json baseRefOid,headRefOid \
                -q '.baseRefOid + ".." + .headRefOid' 2>/dev/null || true)"
      if [ -n "$pair" ] && [ "$pair" != ".." ]; then printf '%s' "$pair"; return 0; fi
      # gh unavailable/offline: a merge commit that references "#<pr>" is the next-best anchor.
      m="$(git -C "$REPO" log --grep "#$pr\b" -n1 --format='%H' 2>/dev/null || true)"
      [ -n "$m" ] || _recon_die "could not resolve PR #$pr to a git range (no gh access, no commit referencing it)" 1
      printf '%s^!' "$m"; return 0 ;;
    *) printf '%s' "$arg"; return 0 ;;
  esac
}

# _surface <range> — emit the rename/move surface as TSV. Two grounded signals, both from the diff:
#   1. file renames/removals — git's own rename detection (`-M`) over --name-status.
#   2. symbol/header renames — definitions (shell `foo()`, `def`/`class`, markdown `##` headers)
#      that appear on a removed line and NOT on any added line = gone after the PR. The scribe
#      resolves the new name from the PR; we only need to surface that the OLD token moved.
_surface() {
  local range="$1" status old new
  # (1) file renames + deletions. -M30% is deliberately lenient: a cutover/extraction PR that both
  # moves a file AND edits it in the same commit can fall under git's default 50% rename score, so a
  # real move would otherwise register as delete+add and lose the new-path half of the mapping.
  while IFS=$'\t' read -r status old new; do
    [ -n "${status:-}" ] || continue
    case "$status" in
      R*) [ -n "${new:-}" ] && printf 'rename\t%s\t%s\n' "$old" "$new" ;;
      D*) printf 'delete\t%s\t\n' "$old" ;;
    esac
  done < <(git -C "$REPO" diff -M30% --name-status "$range" 2>/dev/null || true)

  # (2) symbol/header renames — parse the unified diff (context-free: --unified=0).
  git -C "$REPO" diff -M --unified=0 "$range" 2>/dev/null | "$PY" -c '
import sys, re
DEF = [
    re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_-]*)\s*\(\)"),          # shell: foo() {
    re.compile(r"^\s*function\s+([A-Za-z_][A-Za-z0-9_-]*)"),      # shell: function foo
    re.compile(r"^\s*(?:def|class)\s+([A-Za-z_][A-Za-z0-9_]*)"),  # python: def/class foo
]
HDR = re.compile(r"^#{1,6}\s+(.+?)\s*$")                          # markdown: ## Header
removed, added = {}, set()
for line in sys.stdin.read().splitlines():
    if not line or line[0] not in "+-":            continue
    if line[:3] in ("---", "+++"):                 continue      # diff file headers
    sign, body = line[0], line[1:]
    names = [m.group(1) for p in DEF for m in [p.match(body)] if m]
    hm = HDR.match(body)
    if hm: names.append(hm.group(1).strip())
    for n in names:
        (added.add(n) if sign == "+" else removed.setdefault(n, True))
seen = set()
for n in removed:
    if n in added or len(n) < 4 or n in seen:      continue      # still-defined / too-generic
    seen.add(n)
    sys.stdout.write("symbol\t%s\t\n" % n)
' 2>/dev/null || true
}

# _scan <range> — match the surface against the backlog. Prints the DANGLING report (TSV) or NONE.
_scan() {
  local range="$1" surface
  surface="$(_surface "$range")"
  if [ -z "$surface" ] || [ ! -f "$BACKLOG" ]; then echo "NONE"; return 0; fi
  SURFACE="$surface" BACKLOG="$BACKLOG" "$PY" -c '
import sys, os, re
surface = [ln for ln in os.environ["SURFACE"].splitlines() if ln.strip()]
backlog = open(os.environ["BACKLOG"], encoding="utf-8").read().splitlines()

def patterns(kind, old):
    pats = []
    if kind in ("rename", "delete"):
        pats.append(re.compile(re.escape(old)))                  # full path: specific enough raw
        base = os.path.basename(old)
        if "." in base and base != old:                          # basename only if it has an ext
            pats.append(re.compile(r"(?<![\w./-])" + re.escape(base) + r"(?![\w-])"))
    else:                                                        # symbol/header: whole-token match
        pats.append(re.compile(r"(?<![\w-])" + re.escape(old) + r"(?![\w-])"))
    return pats

seen, out = set(), []
for ln in surface:
    parts = ln.split("\t")
    kind = parts[0]
    old  = parts[1] if len(parts) > 1 else ""
    new  = parts[2] if len(parts) > 2 else ""
    if not old: continue
    pats = patterns(kind, old)
    for i, text in enumerate(backlog, start=1):
        if any(p.search(text) for p in pats):
            key = (kind, old, i)
            if key in seen: continue
            seen.add(key)
            out.append("%s\t%s\t%s\t%d\t%s" % (kind, old, new, i, text.strip()))
if out:
    sys.stdout.write("\n".join(out) + "\n")
else:
    sys.stdout.write("NONE\n")
' 2>/dev/null || echo "NONE"
}

# _build_request <label> <verify-cmd> <report> — turn a DANGLING report into ONE scribe prompt
# describing the rename surface and the entries that reference the old names, with a precise
# update-or-flag rule. <verify-cmd> is how the scribe confirms the new target (e.g. "gh pr diff 72").
_build_request() {
  local label="$1" verify="$2" report="$3" line kind old new lno text
  local files="" syms="" refs=""
  # Parse each TSV row with cut, NOT `read -d IFS=tab`: the `new` field is empty for delete/symbol
  # rows, and tab is IFS-whitespace, so a read loop would COLLAPSE the empty field and shift lno/text.
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    kind="$(printf '%s' "$line" | cut -f1)"
    old="$(printf '%s' "$line"  | cut -f2)"
    new="$(printf '%s' "$line"  | cut -f3)"
    lno="$(printf '%s' "$line"  | cut -f4)"
    text="$(printf '%s' "$line" | cut -f5-)"
    case "$kind" in
      rename) files="${files}  - ${old} → ${new}"$'\n' ;;
      delete) files="${files}  - ${old} → (removed — no rename pair)"$'\n' ;;
      symbol) syms="${syms}  - ${old} (defined before ${label}, gone after — renamed or removed)"$'\n' ;;
    esac
    refs="${refs}  - ${BACKLOG_FILE}:${lno} references '${old}' → ${text}"$'\n'
  done <<EOF
$report
EOF
  # De-duplicate the surface lists (a token can match several backlog lines). awk strips the
  # trailing newline, so each section's format string restores one.
  files="$(printf '%s' "$files" | awk 'NF && !seen[$0]++')"
  syms="$(printf '%s' "$syms"  | awk 'NF && !seen[$0]++')"

  printf 'Reconcile %s against %s'"'"'s rename/move surface. That PR moved or renamed things some backlog entries still point at, so those references now dangle.\n\n' "$BACKLOG_FILE" "$label"
  [ -n "$files" ] && printf 'RENAMED/MOVED/REMOVED FILES:\n%s\n\n' "$files"
  [ -n "$syms" ]  && printf 'RENAMED/REMOVED SYMBOLS OR SECTION HEADERS:\n%s\n\n' "$syms"
  printf 'DANGLING BACKLOG REFERENCES:\n%s\n' "$refs"
  printf 'For EACH referenced entry: if the item is still valid and you can confirm the new path/name (check `%s` or the live repo), UPDATE the stale reference to the new location with a TARGETED edit. If you cannot confidently map old→new, do NOT guess — instead append " ⚠️ (dangling ref: <old> moved/removed in %s — verify)" to that entry so it is visibly stale for a human. Leave references that live inside already-shipped (✅) historical prose untouched (they describe what shipped, not live targets). Edit ONLY %s and touch nothing else.' "$verify" "$label" "$BACKLOG_FILE"
}

cmd="${1:-run}"; shift || true
case "$cmd" in
  surface)
    range="$(_resolve_range "${1:?usage: backlog-reconcile.sh surface <pr#|range>}")"
    _surface "$range" ;;
  scan)
    range="$(_resolve_range "${1:?usage: backlog-reconcile.sh scan <pr#|range>}")"
    _scan "$range" ;;
  run)
    arg="${1:?usage: backlog-reconcile.sh run <pr#|range>}"
    # Backend-gate BEFORE any work: a tracker backend has no BACKLOG.md prose to reconcile, so go inert
    # (never enqueue a file-edit scribe request the tracker backend would only mis-file or skip).
    if ! _recon_backend_manages_backlog; then
      echo "backlog-reconcile: backend '${SCRIBE_BACKEND:-file}' is a tracker backend (BACKLOG.md is not its source of truth) — nothing to reconcile; inert."
      exit 0
    fi
    range="$(_resolve_range "$arg")"
    # A human-readable label + the command the scribe uses to confirm new targets.
    case "$arg" in
      '#'[0-9]*|[0-9]*) pr="${arg#\#}"; label="PR #${pr}";     verify="gh pr diff ${pr}" ;;
      *)                                label="range ${arg}";  verify="git diff ${arg}"  ;;
    esac
    report="$(_scan "$range")"
    if [ "$report" = "NONE" ] || [ -z "$report" ]; then
      echo "backlog-reconcile: no dangling backlog references to ${label}'s rename surface — nothing to enqueue."
      exit 0
    fi
    n="$(printf '%s\n' "$report" | grep -c $'\t' || true)"
    req="$(_build_request "$label" "$verify" "$report")"
    # Enqueue via the async scribe (the one backlog writer). HERD_RECONCILE_SCRIBE overrides the
    # enqueue command — the hermetic test seam, and a hook for projects with a non-standard scribe.
    bash "${HERD_RECONCILE_SCRIBE:-$HERE/scribe.sh}" "$req" >/dev/null 2>&1 \
      || _recon_die "failed to enqueue the reconcile scribe request" 1
    echo "✍️  backlog-reconcile: enqueued a scribe request for ${n} dangling reference(s) to ${label}'s rename surface."
    ;;
  *) echo "usage: backlog-reconcile.sh <surface|scan|run> <pr#|git-range>" >&2; exit 2 ;;
esac
