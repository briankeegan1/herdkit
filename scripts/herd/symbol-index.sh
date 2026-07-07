#!/usr/bin/env bash
# symbol-index.sh — bespoke, bash-native def→caller index behind `herd symbol-index`. The companion
# to codemap.sh: where codemap maps FILE-level structure (module roles, who-sources-whom, config
# wiring), this maps FUNCTION-level structure — for every shell function defined under bin/ and
# scripts/herd/ (incl. scripts/herd/backends/), its definition site(s) and every CROSS-FILE call
# site. It fills the gap graphify leaves in this bash-heavy tree (measured: zero cross-file call
# links resolved in the big engine scripts), so a builder can answer "who calls _backend_update_state"
# with one lookup instead of a grep-and-read session, and the coordinator can sharpen its pre-spawn
# overlap read from file-level to symbol-level when two items touch the same file.
#
# Invoked by bin/herd (cmd_symbol_index runs `bash "$SCRIPTS_DIR/symbol-index.sh"`); also
# standalone-runnable (`bash scripts/herd/symbol-index.sh`) and driven that way by
# tests/test-symbol-index.sh. Like codemap.sh it maps the ENGINE repo it ships in (root derived from
# this file's location, never a consuming project's config) and takes NO model calls.
#
# DETERMINISM is the hard contract (identical to codemap.sh): no timestamps, no absolute paths,
# LC_ALL=C sorts everywhere — two runs on an unchanged tree produce a byte-identical
# docs/symbol-index.md, and the file is rewritten only when its content actually changes (so an
# up-to-date run leaves it and its mtime alone). Cheap enough to re-run per merge alongside the
# codemap: a handful of single-pass awk programs, no fork-per-file.
#
# HONEST SCOPE (the same posture as graphify's honest-scope note — see the artifact header): this is
# a HEURISTIC bash scanner, not a parser. It cannot resolve which same-named definition a call binds
# to (e.g. _backend_update_state is defined in every backend), and its call detection is a
# command-position token match that can miss or over-count around heredocs, quoted strings, dynamic
# dispatch (`$cmd`), and inline `# comments`. It is a navigation aid, not ground truth. The limits
# are spelled out verbatim in the emitted file so a reader never over-trusts it.
set -u
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
# Source herd-config.sh the way siblings do (its PYTHONUTF8 guard + shared discovery). We do NOT read
# its PROJECT_ROOT: the index always covers the engine repo this script ships in, resolved from HERE.
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"

# Root of the tree to scan (the engine repo: two dirs up from scripts/herd/). Overridable for tests.
ROOT="${HERD_SYMBOL_INDEX_ROOT:-$(cd "$HERE/../.." && pwd)}"
OUT="${HERD_SYMBOL_INDEX_OUT:-$ROOT/docs/symbol-index.md}"

# ── Scanners (one awk process each; all paths relative to the cwd, which _si_render sets to ROOT so
#    nothing absolute ever reaches the index) ───────────────────────────────────────────────────────

# _si_defs <file>... — emit `name<TAB>path<TAB>line` for every shell function DEFINITION: the two
# portable bash forms `name() {` (optional space before the parens) and `function name`. Comment
# lines are skipped. A function may be emitted more than once when defined in several files (the
# honest same-name case, e.g. _backend_update_state per backend); the caller sorts + groups.
_si_defs() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      if (match($0, /^[[:space:]]*function[[:space:]]+[A-Za-z_][A-Za-z0-9_-]*/)) {
        s=substr($0,RSTART,RLENGTH); sub(/^[[:space:]]*function[[:space:]]+/,"",s)
        print s "\t" FILENAME "\t" FNR
      } else if (match($0, /^[[:space:]]*[A-Za-z_][A-Za-z0-9_-]*[[:space:]]*\(\)/)) {
        s=substr($0,RSTART,RLENGTH); sub(/[[:space:]]*\(\)[[:space:]]*$/,"",s); sub(/^[[:space:]]*/,"",s)
        print s "\t" FILENAME "\t" FNR
      }
    }
  ' "$@"
}

# _si_calls <defs-file> <file>... — emit `name<TAB>path<TAB>line` for every CROSS-FILE call site.
# The defs file (name<TAB>path<TAB>line, passed as BOTH the first arg and read via NR==FNR) seeds the
# set of known function names and, per name, the set of files that DEFINE it. Then for each scanned
# file we find tokens in COMMAND POSITION — the first word of a simple command, detected by mapping
# command separators (`; | & ( ) { } $( ` and the keywords then/do/else/elif/time) to a marker and
# reading the identifier that follows it — and emit one row when that token is a known function AND
# the current file is NOT one of its definers. (Legacy `` `cmd` `` substitution is not a separator:
# this tree uses `$(...)` exclusively, so backticks here are only ever prose inside strings/heredocs —
# treating them as command openers would false-count doc mentions like the one in this very comment.)
# the current file is NOT one of its definers (a same-file call is not "cross-file"). Comment-only
# lines are skipped. Unordered; the caller sorts + dedups.
_si_calls() {
  awk -F'\t' '
    NR==FNR { isfunc[$1]=1; deffiles[$1]=deffiles[$1] " " $2; next }
    {
      if ($0 ~ /^[[:space:]]*#/) next
      s=$0
      gsub(/\$\(/, ";", s)                              # command substitution opens a command
      gsub(/[|&;(){}]/, ";", s)                         # pipeline / list / group separators
      gsub(/[ \t](then|do|else|elif|time)[ \t]/, " ; ", s)   # keywords that precede a command
      s=";" s                                           # line start is a command position
      while (match(s, /;[ \t]*[A-Za-z_][A-Za-z0-9_-]*/)) {
        tok=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
        sub(/^;[ \t]*/,"",tok)                          # tok = the bare identifier
        if (tok in isfunc && index(" " deffiles[tok] " ", " " FILENAME " ")==0)
          print tok "\t" FILENAME "\t" FNR
      }
    }
  ' "$@"
}

# ── Report body — run with cwd == ROOT so every emitted path is repo-relative, never absolute ─────
_si_render() {
  local f defs calls nnames ncallers ncollide
  local files=()
  [ -f bin/herd ] && files+=(bin/herd)
  for f in scripts/herd/*.sh;          do [ -f "$f" ] && files+=("$f"); done
  for f in scripts/herd/backends/*.sh; do [ -f "$f" ] && files+=("$f"); done

  # Two sorted, deterministic streams: definitions and cross-file call sites (line-numeric key so
  # sites read top-to-bottom within a file, LC_ALL=C so ordering is machine-independent).
  defs="$(_si_defs "${files[@]}" | sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3n)"
  calls="$(_si_calls <(printf '%s\n' "$defs") "${files[@]}" \
             | sort -t"$(printf '\t')" -k1,1 -k2,2 -k3,3n -u)"

  nnames="$(printf '%s\n'   "$defs"  | cut -f1 | sort -u | grep -c .)"
  ncollide="$(printf '%s\n' "$defs"  | cut -f1 | sort   | uniq -d | grep -c .)"
  ncallers="$(printf '%s\n' "$calls" | cut -f1 | sort -u | grep -c .)"

  printf '# herdkit symbol index\n\n'
  printf '> Generated by `herd symbol-index` — a native, function-level def→caller scan of the engine\n'
  printf '> tree (`bin/herd` + `scripts/herd/**`). **Do not edit by hand;** run `herd symbol-index` to\n'
  printf '> refresh. Deterministic: an unchanged tree yields a byte-identical index. Companion to\n'
  printf '> `docs/codemap.md`, which maps the same tree at FILE level.\n\n'
  printf '> **Honest scope — a heuristic, not a parser.** This is a bash-native token scan, so:\n'
  printf '> • It cannot tell which same-named definition a call binds to — a name defined in several\n'
  printf '>   files (e.g. `_backend_update_state`, one per backend) lists every def site, and its\n'
  printf '>   callers are every use outside *any* definer.\n'
  printf '> • Callers are detected in **command position** (first word of a simple command). Calls\n'
  printf '>   built by dynamic dispatch (`"$cmd" ...`), and tokens inside heredoc bodies, quoted\n'
  printf '>   strings, or trailing `# comments`, may be missed or over-counted.\n'
  printf '> • Same-file calls are omitted by design — this indexes CROSS-file reach only.\n'
  printf '> Treat it as a navigation aid (jump to a def, find likely callers), never as ground truth.\n\n'
  printf -- '- Functions indexed: %s (defined in >1 file: %s) · with cross-file callers: %s\n\n' \
    "$nnames" "$ncollide" "$ncallers"

  printf '## Functions (def → cross-file callers)\n\n'
  printf 'Each entry: the function, its definition site(s), and every cross-file call site. A `—` for\n'
  printf 'callers means no cross-file call was found (an internal helper, or a dynamic-dispatch caller\n'
  printf 'this scan cannot see).\n\n'

  # Merge the two sorted streams into one line per unique name, in the (already alphabetical) order
  # names first appear in the defs stream. One awk over two inputs — arrays are always associative.
  awk -F'\t' '
    NR==FNR {                                           # input 1: defs (sorted by name)
      if (!($1 in seen)) { order[++n]=$1; seen[$1]=1 }
      def[$1]=(def[$1]=="" ? "" : def[$1] ", ") "`" $2 ":" $3 "`"
      next
    }
    { call[$1]=(call[$1]=="" ? "" : call[$1] ", ") "`" $2 ":" $3 "`" }   # input 2: call sites
    END {
      for (i=1;i<=n;i++) {
        nm=order[i]; c=(nm in call) ? call[nm] : "\342\200\224"
        print "- `" nm "` \342\200\224 def " def[nm] " \342\200\224 callers: " c
      }
    }
  ' <(printf '%s\n' "$defs") <(printf '%s\n' "$calls")
}

# ── Refresh (default) / --check (read-only staleness probe) ────────────────────────────────────────
# main [--check]
#   (no arg) REFRESH: regenerate the index and write $OUT only when its content actually changed.
#   --check  PROBE:   regenerate to a temp file and diff it against the committed $OUT WITHOUT ever
#                     writing $OUT — exit 0 when the committed index is byte-identical to a fresh scan
#                     (fresh), non-zero when it is missing or drifted (stale). Mirrors codemap.sh's
#                     side-effect-free guard, for the watcher's post-merge refresh + a status row.
main() {
  local mode="refresh" tmp outlabel delta
  case "${1:-}" in
    --check) mode="check" ;;
    "")      : ;;
    *)       printf 'symbol-index.sh: unknown argument: %s (expected --check or none)\n' "$1" >&2; return 2 ;;
  esac

  tmp="$(mktemp)"
  ( cd "$ROOT" && _si_render ) > "$tmp"
  outlabel="${OUT#"$ROOT"/}"

  if [ "$mode" = "check" ]; then
    # READ-ONLY: never write $OUT, never mkdir its dir. Report fresh/stale and set the exit code.
    if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
      rm -f "$tmp"
      printf '%s — fresh\n' "$outlabel"
      return 0
    fi
    rm -f "$tmp"
    if [ -f "$OUT" ]; then
      printf '%s — STALE (out of date; run `herd symbol-index` to refresh)\n' "$outlabel" >&2
    else
      printf '%s — STALE (missing; run `herd symbol-index` to generate)\n' "$outlabel" >&2
    fi
    return 1
  fi

  mkdir -p "$(dirname "$OUT")"
  if [ -f "$OUT" ] && cmp -s "$tmp" "$OUT"; then
    rm -f "$tmp"
    printf '%s — up to date\n' "$outlabel"
    return 0
  fi
  if [ -f "$OUT" ]; then
    delta="$(diff "$OUT" "$tmp" 2>/dev/null | grep -c '^[<>]' || true)"
    mv "$tmp" "$OUT"
    printf '%s — updated (%s line(s) changed)\n' "$outlabel" "$delta"
  else
    mv "$tmp" "$OUT"
    printf '%s — created\n' "$outlabel"
  fi
}

main "$@"
