#!/usr/bin/env bash
# codemap.sh — bespoke, bash-native repo mapper behind `herd codemap`. Scans the herdkit ENGINE
# tree (bin/herd, scripts/herd/*.sh, templates/) and regenerates docs/codemap.md: a compact,
# DETERMINISTIC, diff-friendly map — module roles, who-sources-whom, and config-key → consumer
# wiring — that a coordinator/builder agent loads as context instead of re-exploring the repo each
# session. NO external code-graph dependency: this repo is bash-heavy, so the whole scan is native
# grep/awk/sort.
#
# Invoked by bin/herd (cmd_codemap runs `bash "$SCRIPTS_DIR/codemap.sh"`); also standalone-runnable
# (`bash scripts/herd/codemap.sh`) and driven that way by tests/test-codemap.sh. Sourced siblings
# read the consuming project's config; codemap instead maps the ENGINE repo it lives in, so it
# derives its own root from this file's location and never reads a project config value.
#
# DETERMINISM is the hard contract: no timestamps, no absolute paths, LC_ALL=C sorts everywhere —
# running it twice on an unchanged tree produces a byte-identical docs/codemap.md. The file is only
# rewritten when its content actually changes, so an up-to-date run leaves it (and its mtime) alone.
#
# PERFORMANCE: the scan is done in a handful of single-pass awk programs (each handling ALL files in
# one process) rather than a fork per file/key — process spawning is expensive (especially on
# Windows), so the batched passes keep a full refresh to a few seconds.
set -u
export LC_ALL=C
HERE="$(cd "$(dirname "$0")" && pwd)"
# Source herd-config.sh the way siblings do (its PYTHONUTF8 guard + shared discovery). We do NOT
# read its PROJECT_ROOT: the map always covers the engine repo this script ships in, resolved from
# HERE, regardless of the cwd `herd codemap` was invoked from.
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"

# Root of the tree to map (the engine repo: two dirs up from scripts/herd/). Overridable for tests.
ROOT="${HERD_CODEMAP_ROOT:-$(cd "$HERE/../.." && pwd)}"
OUT="${HERD_CODEMAP_OUT:-$ROOT/docs/codemap.md}"

# ── Batched scanners (one awk process each; all paths relative to the cwd, which _cm_render sets to
#    ROOT so nothing absolute ever reaches the map) ────────────────────────────────────────────────

# _cm_module_lines <file>... — for each file, emit `path<TAB>role`: the role is the first descriptive
# top-of-file comment, its leading '#'/whitespace stripped, a redundant "<basename> — " (or "-")
# prefix trimmed, and an extension label substituted when the file opens with no comment (e.g. a
# .tsv). Output order follows the argument order. One awk process for the whole group.
_cm_module_lines() {
  awk '
    function base(p,  n,a){ n=split(p,a,"/"); return a[n] }
    FNR==1 { order[++nf]=FILENAME; if ($0 ~ /^#!/) next }
    {
      fn=FILENAME
      if (done[fn]) next
      s=$0
      if (s ~ /^[[:space:]]*#/) {
        sub(/^[[:space:]]*#+[[:space:]]?/,"",s)
        if (s ~ /^shellcheck/) next
        if (s=="") next
        role[fn]=s; done[fn]=1; next
      }
      if (s ~ /^[[:space:]]*$/) next
      role[fn]=""; done[fn]=1
    }
    END {
      for (i=1;i<=nf;i++){
        f=order[i]; r=role[f]; b=base(f); bn=b; sub(/\.sh$/,"",bn)
        sub(/[[:space:]]+$/,"",r)
        if      (index(r,b  " \342\200\224 ")==1) r=substr(r,length(b  " \342\200\224 ")+1)
        else if (index(r,bn " \342\200\224 ")==1) r=substr(r,length(bn " \342\200\224 ")+1)
        else if (index(r,b  " - ")==1)            r=substr(r,length(b  " - ")+1)
        else if (index(r,bn " - ")==1)            r=substr(r,length(bn " - ")+1)
        if (r=="") {
          if      (b ~ /\.tsv$/)     r="(tab-separated manifest \342\200\224 no header comment)"
          else if (b ~ /\.tmpl$/)    r="(render template \342\200\224 no header comment)"
          else if (b ~ /\.example$/) r="(example file \342\200\224 no header comment)"
          else                       r="(no header comment)"
        }
        print f "\t" r
      }
    }
  ' "$@"
}

# _cm_source_edges <file>... — emit `sourcer-path<TAB>sourced-basename` for every static `.`/`source`
# of a literal *.sh, deduped. Reads the token AFTER the source operator, so a `[ -f x.sh ] && . x.sh`
# guard never leaks the guard path as its own edge; dynamic `. "$var"` sources (no literal .sh)
# produce nothing. Comment lines are skipped. Unordered; the caller sorts + filters.
_cm_source_edges() {
  awk '
    /^[[:space:]]*#/ { next }
    {
      if (match($0,/(^|[[:space:]])(\.|source)[[:space:]]/)) {
        rest=substr($0,RSTART+RLENGTH)
        if (match(rest,/[A-Za-z0-9_.-]+\.sh/)) {
          tgt=substr(rest,RSTART,RLENGTH); e=FILENAME SUBSEP tgt
          if (!(e in seen)) { seen[e]=1; print FILENAME "\t" tgt }
        }
      }
    }
  ' "$@"
}

# _cm_config_pairs <caps> <file>... — emit `KEY<TAB>consumer-path` for every kind=config KEY (from
# the caps manifest, passed as BOTH the first file arg and -v caps=) that appears as a whole word in
# a NON-COMMENT line of a scanned file, deduped. Whole-word by construction (tokens are matched as
# [A-Za-z_][A-Za-z0-9_]*), so WATCHER_VIEW never matches WATCHER_VIEW_AUTHOR; comment-only mentions
# do not count as consumption. One awk process for every key × file.
_cm_config_pairs() {
  local caps="$1"; shift
  awk -F'\t' -v caps="$caps" '
    FILENAME==caps { if ($2=="config" && $1!="name" && $1!="") iscfg[$1]=1; next }
    /^[[:space:]]*#/ { next }
    {
      line=$0
      while (match(line,/[A-Za-z_][A-Za-z0-9_]*/)) {
        w=substr(line,RSTART,RLENGTH); line=substr(line,RSTART+RLENGTH)
        if (w in iscfg) { e=w SUBSEP FILENAME
          if (!(e in seen)) { seen[e]=1; print w "\t" FILENAME } }
      }
    }
  ' "$caps" "$@"
}

# ── Report body — run with cwd == ROOT so every emitted path is repo-relative, never absolute ─────
_cm_render() {
  local f role path tgt key lbl cur targets
  local caps="templates/capabilities.tsv"

  printf '# herdkit codemap\n\n'
  printf '> Generated by `herd codemap` — a native scan of the engine tree. **Do not edit by hand;**\n'
  printf '> run `herd codemap` to refresh. Deterministic: an unchanged tree yields a byte-identical map.\n\n'

  # 1. Module roles.
  printf '## Modules\n\n'
  printf 'Role summarized from each file'"'"'s top-of-file comment.\n\n'
  printf '### CLI\n\n'
  [ -f bin/herd ] && _cm_module_lines bin/herd | while IFS=$'\t' read -r f role; do
    printf -- '- `%s` — %s\n' "$f" "$role"
  done
  printf '\n### Engine scripts (`scripts/herd/`)\n\n'
  _cm_module_lines scripts/herd/*.sh | while IFS=$'\t' read -r f role; do
    printf -- '- `%s` — %s\n' "${f##*/}" "$role"
  done
  # Templates: the top-level render surface only (skip drivers/ and themes/ subdirs).
  local tmpl=(); for f in templates/*; do [ -f "$f" ] && tmpl+=("$f"); done
  printf '\n### Templates (`templates/`)\n\n'
  if [ "${#tmpl[@]}" -gt 0 ]; then
    _cm_module_lines "${tmpl[@]}" | while IFS=$'\t' read -r f role; do
      printf -- '- `%s` — %s\n' "${f##*/}" "$role"
    done
  fi

  # 2. Who sources whom (edges to real engine scripts only; sorted by sourcer then target).
  # Membership is a space-delimited basename list, NOT an associative array: macOS ships bash 3.2
  # (no declare -A), and under 3.2 an assoc subscript like agent-watch.sh is arithmetic-evaluated —
  # an unbound-variable abort mid-render. Basenames never contain spaces, so the case match is exact.
  printf '\n## Who sources whom\n\n'
  printf 'Static `.`/`source` edges between shell files (dynamic `. "$var"` sources omitted).\n\n'
  local _scripts=" "
  for f in scripts/herd/*.sh; do _scripts="${_scripts}${f##*/} "; done
  cur=""; targets=""
  while IFS=$'\t' read -r path tgt; do
    [ -n "$path" ] || continue
    case "$_scripts" in *" $tgt "*) ;; *) continue ;; esac
    if [ "$path" != "$cur" ]; then
      if [ -n "$cur" ] && [ -n "$targets" ]; then
        case "$cur" in bin/herd) lbl="bin/herd" ;; *) lbl="${cur##*/}" ;; esac
        printf -- '- `%s` → %s\n' "$lbl" "$targets"
      fi
      cur="$path"; targets=""
    fi
    targets="${targets:+$targets, }\`$tgt\`"
  done < <(_cm_source_edges bin/herd scripts/herd/*.sh | sort)
  if [ -n "$cur" ] && [ -n "$targets" ]; then
    case "$cur" in bin/herd) lbl="bin/herd" ;; *) lbl="${cur##*/}" ;; esac
    printf -- '- `%s` → %s\n' "$lbl" "$targets"
  fi

  # 3. Config key → consumers.
  printf '\n## Config key → consumers\n\n'
  printf 'Which script(s) reference each `kind=config` key from `templates/capabilities.tsv`. The\n'
  printf 'loader `herd-config.sh` (which only sets defaults) is omitted, so this shows real consumers.\n\n'
  if [ -f "$caps" ]; then
    # Files scanned for consumers: bin/herd + every engine script EXCEPT the loader itself.
    local scan=(bin/herd)
    for f in scripts/herd/*.sh; do
      case "$f" in scripts/herd/herd-config.sh) continue ;; esac
      scan+=("$f")
    done
    # Aggregate consumers per key and emit every config key in sorted order (a key with no consumer
    # shows an em-dash). The aggregation lives in awk, not a bash associative array: macOS bash 3.2
    # has no declare -A (see the who-sources-whom note above). PAIR rows (sorted key→path pairs)
    # stream in first to build each key's consumer list; KEY rows (the sorted manifest keys) then
    # emit one line per key, preserving the exact output shape.
    { _cm_config_pairs "$caps" "${scan[@]}" | sort | awk '{print "PAIR\t" $0}'
      awk -F'\t' '$2=="config" && $1!="name" && $1!="" {print $1}' "$caps" | sort -u \
        | awk '{print "KEY\t" $0}'
    } | awk -F'\t' '
      $1=="PAIR" {
        lbl=$3
        if (lbl!="bin/herd") { n=split(lbl,a,"/"); lbl=a[n] }
        cons[$2] = (cons[$2]=="" ? "" : cons[$2] ", ") "`" lbl "`"
        next
      }
      $1=="KEY" {
        c=cons[$2]; if (c=="") c="—"
        printf "- `%s` → %s\n", $2, c
      }
    '
  fi
}

# ── Refresh: write only when the content changed; report what happened ────────────────────────────
main() {
  local tmp outlabel delta
  tmp="$(mktemp)"
  ( cd "$ROOT" && _cm_render ) > "$tmp"
  mkdir -p "$(dirname "$OUT")"
  outlabel="${OUT#"$ROOT"/}"

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
