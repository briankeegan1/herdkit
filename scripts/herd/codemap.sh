#!/usr/bin/env bash
# codemap.sh — bespoke, native repo mapper behind `herd codemap`. Regenerates docs/codemap.md: a
# compact, DETERMINISTIC, diff-friendly map — module roles, who-imports/sources-whom, and
# config-key → consumer wiring — that a coordinator/builder agent loads as context instead of
# re-exploring the tree each session. NO external code-graph dependency required: the whole scan is
# native grep/awk/sort.
#
# TWO MODES, picked automatically from the tree being mapped (HERD-79):
#   • ENGINE mode — when run in the herdkit engine repo itself (its own signature files present),
#     scan the ENGINE tree (bin/herd, scripts/herd/*.sh, templates/) exactly as before. This
#     behavior is BYTE-IDENTICAL to the historical map (tests/test-codemap.sh asserts it).
#   • PROJECT mode — when run in a CONSUMING project (not the engine), scan THAT project's own source
#     tree, language-aware (node/python/go/rust/java via the same detection `herd init`'s scout uses),
#     emitting the same section shapes: module roles from top-of-file comments/docstrings,
#     who-imports-whom (local import edges), and config-key → consumer (env-var read sites). When
#     GRAPHIFY_BIN resolves AND graphify-out/graph.json exists, the who-imports section is optionally
#     enriched with graphify's file→file import edges (fail-soft: absent without it).
#
# Invoked by bin/herd (cmd_codemap runs `bash "$SCRIPTS_DIR/codemap.sh"`); also standalone-runnable
# (`bash scripts/herd/codemap.sh`) and driven that way by tests/test-codemap.sh. It sources
# herd-config.sh (for its PYTHONUTF8 guard + PROJECT_ROOT discovery): PROJECT_ROOT is what tells a
# consumer-project run to map THAT project instead of herdkit internals.
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
# Source herd-config.sh the way siblings do (its PYTHONUTF8 guard + shared discovery). Unlike the
# historical single-mode scanner, we DO consult its PROJECT_ROOT: it is the seam that lets a run
# inside a consuming project map THAT project rather than the engine (see mode selection below).
# shellcheck source=/dev/null
. "$HERE/herd-config.sh"

# Engine repo root: the tree this script ships in (two dirs up from scripts/herd/).
ENGINE_ROOT="$(cd "$HERE/../.." && pwd -P)"

# _cm_is_engine <dir> — true iff <dir> is the herdkit ENGINE repo itself (its own signature files are
# present). Decides ENGINE mode (map bin/herd + scripts/herd + templates, byte-identical to the
# historical map) vs PROJECT mode (map a CONSUMING project's own source tree).
_cm_is_engine() {
  [ -f "$1/scripts/herd/codemap.sh" ] && [ -f "$1/bin/herd" ] && [ -f "$1/templates/capabilities.tsv" ]
}

# Root of the tree to map. Precedence:
#   1. HERD_CODEMAP_ROOT override — mapped verbatim (tests + the watcher's post-merge refresh).
#   2. the CONSUMING project (PROJECT_ROOT) when it is NOT the engine repo — so `herd codemap` run in
#      a real project maps THAT project's own code, not herdkit internals.
#   3. the engine repo this script ships in (running inside herdkit itself → historical behavior).
ROOT="${HERD_CODEMAP_ROOT:-$ENGINE_ROOT}"
if [ -z "${HERD_CODEMAP_ROOT:-}" ] && [ -n "${PROJECT_ROOT:-}" ]; then
  _cm_proj="$(cd "$PROJECT_ROOT" 2>/dev/null && pwd -P || printf '%s' "$PROJECT_ROOT")"
  if ! _cm_is_engine "$_cm_proj"; then ROOT="$_cm_proj"; fi
fi
OUT="${HERD_CODEMAP_OUT:-$ROOT/docs/codemap.md}"

# Renderer is chosen purely by whether ROOT is the engine repo. ENGINE mode reproduces the historical
# map byte-for-byte (tests/test-codemap.sh asserts this); PROJECT mode maps the consumer's own tree.
if _cm_is_engine "$ROOT"; then CM_MODE="engine"; else CM_MODE="project"; fi

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
  # Work-unit adapters: the per-kind delivery-vehicle bodies behind scripts/herd/work-unit.sh
  # (HERD-398). Own subsection, mirroring Templates below, so a new adapter kind is never silently
  # missing from the map.
  local wu=(); for f in scripts/herd/work-units/*.sh; do [ -f "$f" ] && wu+=("$f"); done
  if [ "${#wu[@]}" -gt 0 ]; then
    printf '\n### Work-unit adapters (`scripts/herd/work-units/`)\n\n'
    _cm_module_lines "${wu[@]}" | while IFS=$'\t' read -r f role; do
      printf -- '- `%s` — %s\n' "${f#scripts/herd/}" "$role"
    done
  fi
  # Templates: the top-level render surface only (skip drivers/ and themes/ subdirs).
  local tmpl=(); for f in templates/*; do [ -f "$f" ] && tmpl+=("$f"); done
  printf '\n### Templates (`templates/`)\n\n'
  if [ "${#tmpl[@]}" -gt 0 ]; then
    _cm_module_lines "${tmpl[@]}" | while IFS=$'\t' read -r f role; do
      printf -- '- `%s` — %s\n' "${f##*/}" "$role"
    done
  fi

  # 2. Who sources whom (edges to real engine scripts only; sorted by sourcer then target).
  printf '\n## Who sources whom\n\n'
  printf 'Static `.`/`source` edges between shell files (dynamic `. "$var"` sources omitted).\n\n'
  # Set of engine-script basenames as a space-delimited string (bash 3.2 has no associative arrays;
  # basenames never contain spaces, so a padded ' name ' glob is an exact membership test).
  local _isscript=" "
  for f in scripts/herd/*.sh scripts/herd/work-units/*.sh; do [ -f "$f" ] && _isscript="$_isscript${f##*/} "; done
  cur=""; targets=""
  while IFS=$'\t' read -r path tgt; do
    [ -n "$path" ] || continue
    case "$_isscript" in *" $tgt "*) ;; *) continue ;; esac
    if [ "$path" != "$cur" ]; then
      if [ -n "$cur" ] && [ -n "$targets" ]; then
        case "$cur" in bin/herd) lbl="bin/herd" ;; *) lbl="${cur##*/}" ;; esac
        printf -- '- `%s` → %s\n' "$lbl" "$targets"
      fi
      cur="$path"; targets=""
    fi
    targets="${targets:+$targets, }\`$tgt\`"
  done < <(_cm_source_edges bin/herd scripts/herd/*.sh scripts/herd/work-units/*.sh | sort)
  if [ -n "$cur" ] && [ -n "$targets" ]; then
    case "$cur" in bin/herd) lbl="bin/herd" ;; *) lbl="${cur##*/}" ;; esac
    printf -- '- `%s` → %s\n' "$lbl" "$targets"
  fi

  # 3. Config key → consumers.
  printf '\n## Config key → consumers\n\n'
  printf 'Which script(s) reference each `kind=config` key from `templates/capabilities.tsv`. The\n'
  printf 'loader `herd-config.sh` (which only sets defaults) is omitted, so this shows real consumers.\n\n'
  if [ -f "$caps" ]; then
    # Files scanned for consumers: bin/herd + every engine script (incl. the work-unit adapter
    # bodies) EXCEPT the loader itself.
    local scan=(bin/herd)
    for f in scripts/herd/*.sh scripts/herd/work-units/*.sh; do
      [ -f "$f" ] || continue
      case "$f" in scripts/herd/herd-config.sh) continue ;; esac
      scan+=("$f")
    done
    # Accumulate consumers per key AND emit every manifest config key (sorted; a key with no
    # consumer shows an em-dash) in ONE awk over two inputs — awk arrays are always associative and
    # portable, so this replaces the bash-4-only `declare -A` map with no output change. Input 1 is
    # the full sorted config-key list (never empty when caps has config rows, so the NR==FNR split is
    # unambiguous); input 2 is the sorted key<TAB>path consumer pairs, appended in sorted order.
    awk -F'\t' '
      NR==FNR { keys[++n]=$1; next }                     # input 1: manifest config keys, sorted
      {                                                   # input 2: key<TAB>path consumer pairs
        if ($1=="") next
        if ($2=="bin/herd") lbl="bin/herd"; else { lbl=$2; sub(/.*\//,"",lbl) }
        cons[$1] = (cons[$1]=="" ? "" : cons[$1] ", ") "`" lbl "`"
      }
      END { for (i=1;i<=n;i++) print "- `" keys[i] "` \342\206\222 " (cons[keys[i]]=="" ? "\342\200\224" : cons[keys[i]]) }
    ' <(awk -F'\t' '$2=="config" && $1!="name" && $1!="" {print $1}' "$caps" | sort -u) \
      <(_cm_config_pairs "$caps" "${scan[@]}" | sort)
  fi
}

# ══ PROJECT MODE — map a CONSUMING project's own source tree ════════════════════════════════════════
# Everything below runs only in PROJECT mode (CM_MODE=project); ENGINE mode never touches it, so the
# historical engine map stays byte-identical. All scanners run with cwd == ROOT (main() cd's there),
# so every emitted path is project-relative — never absolute — preserving the determinism contract.

# _cm_detect_lang — the consuming project's primary language, using the SAME markers + precedence as
# `herd init`'s scout_repo (bin/herd). Prints one of: node|python|go|rust|java|unknown. cwd == ROOT.
_cm_detect_lang() {
  local lang=unknown
  [ -f package.json ] && lang=node
  { [ -f pyproject.toml ] || [ -f requirements.txt ] || [ -f setup.py ]; } && lang=python
  [ -f go.mod ] && lang=go
  [ -f Cargo.toml ] && lang=rust
  { [ -f pom.xml ] || [ -f build.gradle ] || [ -f build.gradle.kts ]; } && lang=java
  printf '%s' "$lang"
}

# _cm_srcfiles <lang> — sorted, project-relative source files for the language, pruning vendored /
# build / VCS dirs (and .herd — herdkit's own control files are not the project's code). cwd == ROOT.
_cm_srcfiles() {
  local lang="$1"; local -a names=()
  case "$lang" in
    node)   names=(-name '*.js' -o -name '*.jsx' -o -name '*.ts' -o -name '*.tsx' -o -name '*.mjs' -o -name '*.cjs') ;;
    python) names=(-name '*.py') ;;
    go)     names=(-name '*.go') ;;
    rust)   names=(-name '*.rs') ;;
    java)   names=(-name '*.java') ;;
    *)      return 0 ;;
  esac
  find . \( -name .git -o -name node_modules -o -name vendor -o -name target -o -name dist \
            -o -name build -o -name out -o -name __pycache__ -o -name .venv -o -name venv \
            -o -name graphify-out -o -name .herd \) -prune -o \
       -type f \( "${names[@]}" \) -print 2>/dev/null \
    | sed 's|^\./||' | LC_ALL=C sort
}

# _cm_roles <style: hash|slash> <file>... — for each file emit `path<TAB>role`: the first descriptive
# top-of-file comment (hash: `#` line or a `"""docstring"""`; slash: `//`/`///`/`//!` line or a
# `/* … */` block), with a redundant "<basename> — "/"- " prefix trimmed and a placeholder when the
# file opens with no comment. Output order follows the argument order. One awk process for the group.
_cm_roles() {
  local style="$1"; shift
  [ "$#" -gt 0 ] || return 0
  awk -v style="$style" '
    function base(p,  n,a){ n=split(p,a,"/"); return a[n] }
    function trim(x){ sub(/^[[:space:]]+/,"",x); sub(/[[:space:]]+$/,"",x); return x }
    FNR==1 { order[++nf]=FILENAME; inblk=0; indoc=0 }
    {
      if (fdone[FILENAME]) next
      line=$0
      if (FNR==1 && line ~ /^#!/) next
      if (style=="hash") {
        if (indoc) {
          t=line; if (t ~ /"""/) sub(/""".*/,"",t); t=trim(t)
          if (t!="") { role[FILENAME]=t; fdone[FILENAME]=1; indoc=0; next }
          if (line ~ /"""/) { role[FILENAME]=""; fdone[FILENAME]=1; indoc=0 }
          next
        }
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*#/) {
          t=line; sub(/^[[:space:]]*#+[[:space:]]?/,"",t)
          if (t ~ /^shellcheck/) next
          if (trim(t)=="") next
          role[FILENAME]=trim(t); fdone[FILENAME]=1; next
        }
        if (line ~ /^[[:space:]]*"""/) {
          t=line; sub(/^[[:space:]]*"""/,"",t)
          if (t ~ /"""/) { sub(/""".*/,"",t); role[FILENAME]=trim(t); fdone[FILENAME]=1; next }
          t=trim(t)
          if (t!="") { role[FILENAME]=t; fdone[FILENAME]=1; next }
          indoc=1; next
        }
        role[FILENAME]=""; fdone[FILENAME]=1; next
      } else {
        if (inblk) {
          t=line; if (t ~ /\*\//) sub(/\*\/.*/,"",t)
          sub(/^[[:space:]]*\*+[[:space:]]?/,"",t); t=trim(t)
          if (t!="") { role[FILENAME]=t; fdone[FILENAME]=1; inblk=0; next }
          if (line ~ /\*\//) { role[FILENAME]=""; fdone[FILENAME]=1; inblk=0 }
          next
        }
        if (line ~ /^[[:space:]]*$/) next
        if (line ~ /^[[:space:]]*\/\//) {
          t=line; sub(/^[[:space:]]*\/+[!\/]?[[:space:]]?/,"",t); t=trim(t)
          if (t=="") next
          role[FILENAME]=t; fdone[FILENAME]=1; next
        }
        if (line ~ /^[[:space:]]*\/\*/) {
          t=line; sub(/^[[:space:]]*\/\*+[[:space:]]?/,"",t)
          if (t ~ /\*\//) { sub(/\*\/.*/,"",t); role[FILENAME]=trim(t); fdone[FILENAME]=1; next }
          t=trim(t)
          if (t!="") { role[FILENAME]=t; fdone[FILENAME]=1; next }
          inblk=1; next
        }
        role[FILENAME]=""; fdone[FILENAME]=1; next
      }
    }
    END {
      for (i=1;i<=nf;i++){
        f=order[i]; r=role[f]; b=base(f)
        if      (index(r, b " \342\200\224 ")==1) r=substr(r,length(b " \342\200\224 ")+1)
        else if (index(r, b " - ")==1)            r=substr(r,length(b " - ")+1)
        r=trim(r)
        if (r=="") r="(no header comment)"
        print f "\t" r
      }
    }
  ' "$@"
}

# _cm_import_edges <lang> <file>... — emit `importer-path<TAB>local-target` for every LOCAL import
# (external/library imports omitted), deduped. Heuristic + language-aware; the "local" test differs by
# language (relative specifiers for node/python/rust, the module path for go, a declared package
# prefix for java). Unordered; the caller sorts + groups. cwd == ROOT.
_cm_import_edges() {
  local lang="$1"; shift
  [ "$#" -gt 0 ] || return 0
  case "$lang" in
    node)
      awk -v dq='"' -v sq="'" '
        BEGIN{ Q="[" dq sq "]"; NQ="[^" dq sq "]+" }
        /^[[:space:]]*(\/\/|\*)/ { next }
        {
          s=$0; re="(from|require|import)[[:space:](]*" Q NQ Q
          while (match(s,re)) {
            seg=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH)
            if (match(seg,Q NQ Q)) {
              spec=substr(seg,RSTART+1,RLENGTH-2)
              if (substr(spec,1,1)==".") { k=FILENAME SUBSEP spec
                if(!(k in seen)){seen[k]=1; print FILENAME "\t" spec} }
            }
          }
        }
      ' "$@"
      ;;
    python)
      local mods=" "
      local e
      for e in *; do
        if [ -f "$e" ]; then case "$e" in *.py) mods="$mods${e%.py} " ;; esac
        elif [ -d "$e" ]; then
          if [ -f "$e/__init__.py" ] || ls "$e"/*.py >/dev/null 2>&1; then mods="$mods$e "; fi
        fi
      done
      awk -v mods="$mods" '
        function seg1(m,  a){ split(m,a,"."); return a[1] }
        function emit(m){ k=FILENAME SUBSEP m; if(!(k in seen)){seen[k]=1; print FILENAME "\t" m} }
        /^[[:space:]]*#/ { next }
        {
          line=$0
          if (match(line,/^[[:space:]]*from[[:space:]]+\.+[A-Za-z0-9_.]*/)) {
            m=substr(line,RSTART,RLENGTH); sub(/^[[:space:]]*from[[:space:]]+/,"",m); emit(m)
          } else if (match(line,/^[[:space:]]*from[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*/)) {
            m=substr(line,RSTART,RLENGTH); sub(/^[[:space:]]*from[[:space:]]+/,"",m)
            if (index(mods," " seg1(m) " ")>0) emit(m)
          } else if (match(line,/^[[:space:]]*import[[:space:]]+[A-Za-z_][A-Za-z0-9_.]*/)) {
            m=substr(line,RSTART,RLENGTH); sub(/^[[:space:]]*import[[:space:]]+/,"",m)
            if (index(mods," " seg1(m) " ")>0) emit(m)
          }
        }
      ' "$@"
      ;;
    go)
      local modp; modp="$(awk '$1=="module"{print $2; exit}' go.mod 2>/dev/null)"
      awk -v modp="$modp" '
        function emit(l,  p,out){
          if (modp=="") return
          if (match(l,/"[^"]+"/)) {
            p=substr(l,RSTART+1,RLENGTH-2)
            if (p==modp) out="."
            else if (index(p, modp "/")==1) out=substr(p, length(modp)+2)
            else return
            k=FILENAME SUBSEP out; if(!(k in seen)){seen[k]=1; print FILENAME "\t" out}
          }
        }
        /^[[:space:]]*\/\// { next }
        {
          line=$0
          if (line ~ /^[[:space:]]*import[[:space:]]*\(/) { inblk=1; next }
          if (inblk && line ~ /^[[:space:]]*\)/)          { inblk=0; next }
          if (inblk)                                       { emit(line); next }
          if (line ~ /^[[:space:]]*import[[:space:]]+"/)   { emit(line) }
        }
      ' "$@"
      ;;
    rust)
      awk '
        function emit(m){ k=FILENAME SUBSEP m; if(!(k in seen)){seen[k]=1; print FILENAME "\t" m} }
        /^[[:space:]]*\/\// { next }
        {
          line=$0
          if (match(line,/^[[:space:]]*(pub[[:space:]]+)?use[[:space:]]+(crate|self|super)/)) {
            m=substr(line,RSTART,RLENGTH); sub(/^[[:space:]]*(pub[[:space:]]+)?use[[:space:]]+/,"",m)
            rest=substr(line,RSTART+RLENGTH); sub(/;.*/,"",rest)
            m=m rest; sub(/[[:space:]]+$/,"",m); emit(m)
          } else if (match(line,/^[[:space:]]*(pub[[:space:]]+)?mod[[:space:]]+[A-Za-z0-9_]+[[:space:]]*;/)) {
            m=substr(line,RSTART,RLENGTH); sub(/^[[:space:]]*(pub[[:space:]]+)?mod[[:space:]]+/,"",m)
            sub(/[[:space:]]*;.*/,"",m); emit("mod " m)
          }
        }
      ' "$@"
      ;;
    java)
      local pkgs; pkgs="$(awk '/^[[:space:]]*package[[:space:]]/{p=$2; sub(/;.*/,"",p); print p}' "$@" 2>/dev/null | LC_ALL=C sort -u | tr '\n' ' ')"
      awk -v pkgs=" $pkgs " '
        function emit(m){ k=FILENAME SUBSEP m; if(!(k in seen)){seen[k]=1; print FILENAME "\t" m} }
        /^[[:space:]]*\/\// { next }
        {
          line=$0
          if (match(line,/^[[:space:]]*import[[:space:]]+(static[[:space:]]+)?[A-Za-z_][A-Za-z0-9_.]*[*]?/)) {
            m=substr(line,RSTART,RLENGTH)
            sub(/^[[:space:]]*import[[:space:]]+(static[[:space:]]+)?/,"",m); sub(/;.*/,"",m)
            n=split(pkgs,arr," ")
            for (i=1;i<=n;i++) if (arr[i]!="" && index(m, arr[i] ".")==1) { emit(m); break }
          }
        }
      ' "$@"
      ;;
  esac
}

# _cm_group_edges — read `left<TAB>right` TSV on stdin, sort, and print one grouped bullet per left:
# `- \`left\` → \`r1\`, \`r2\``. Shared by the who-imports edges and the graphify enrichment.
_cm_group_edges() {
  LC_ALL=C sort | awk -F'\t' '
    { if ($1!=cur){ if(cur!=""){print line} cur=$1; line="- `" cur "` \342\206\222 `" $2 "`" }
      else line=line ", `" $2 "`" }
    END{ if(cur!="") print line }
  '
}

# _cm_env_pairs <lang> <file>... — emit `KEY<TAB>consumer-path` for every environment variable READ by
# the project (node process.env.X / process.env["X"]; python os.getenv/os.environ[/.get; go
# os.Getenv/os.LookupEnv; rust env::var/env::var_os; java System.getenv), deduped. The project-mode
# analog of the engine's config-key→consumer wiring; heuristic ("where detectable"). cwd == ROOT.
_cm_env_pairs() {
  local lang="$1"; shift
  [ "$#" -gt 0 ] || return 0
  awk -v lang="$lang" -v dq='"' -v sq="'" '
    function ident(rest){ if (match(rest,/[A-Za-z_][A-Za-z0-9_]*/)) return substr(rest,RSTART,RLENGTH); return "" }
    function emit(k){ if(k!=""){ e=k SUBSEP FILENAME; if(!(e in seen)){seen[e]=1; print k "\t" FILENAME} } }
    # scan every quoted-key accessor prefix in the line; require a quote right after so only literal
    # keys count. NB: re is passed as a STRING (a /regex/ literal argument would be matched against $0
    # by awk and passed as 0/1, not as the pattern).
    function scanq(line,re,   s,seg,rest,q){
      q="[" dq sq "]"; s=line
      while (match(s,re)) {
        seg=substr(s,RSTART,RLENGTH); rest=substr(s,RSTART+RLENGTH); s=rest
        if (match(rest,"^[[:space:]]*" q)) emit(ident(substr(rest,RSTART+RLENGTH)))
      }
    }
    /^[[:space:]]*(#|\/\/|\*)/ { next }
    {
      line=$0
      if (lang=="node") {
        s=line
        while (match(s,/process\.env\.[A-Za-z_][A-Za-z0-9_]*/)) {
          seg=substr(s,RSTART,RLENGTH); s=substr(s,RSTART+RLENGTH); sub(/^process\.env\./,"",seg); emit(seg)
        }
        scanq(line,"process\\.env\\[")
      } else if (lang=="python") {
        scanq(line,"os\\.environ\\.get\\("); scanq(line,"os\\.getenv\\("); scanq(line,"os\\.environ\\[")
      } else if (lang=="go") {
        scanq(line,"os\\.Getenv\\("); scanq(line,"os\\.LookupEnv\\(")
      } else if (lang=="rust") {
        scanq(line,"env::var\\("); scanq(line,"env::var_os\\(")
      } else if (lang=="java") {
        scanq(line,"System\\.getenv\\(")
      }
    }
  ' "$@"
}

# _cm_graphify_enrich — OPTIONAL, FAIL-SOFT enrichment of the who-imports section from graphify. Only
# fires when GRAPHIFY_BIN (or `graphify` on PATH) resolves AND graphify-out/graph.json exists AND
# python3 is available; anything missing/malformed → prints nothing (the tree-only map is unchanged).
# Emits graphify's file→file `imports` edges — the cross-file links a native single-pass scan can miss.
_cm_graphify_enrich() {
  local gbin="${GRAPHIFY_BIN:-}"
  if [ -z "$gbin" ] || [ ! -x "$gbin" ]; then gbin="$(command -v graphify 2>/dev/null || true)"; fi
  [ -n "$gbin" ] || return 0
  [ -f graphify-out/graph.json ] || return 0
  command -v python3 >/dev/null 2>&1 || return 0
  local edges
  edges="$(python3 - <<'PY' 2>/dev/null || true
import json, sys
try:
    d = json.load(open('graphify-out/graph.json'))
except Exception:
    sys.exit(0)
byid = {n.get('id'): n for n in d.get('nodes', [])}
def isfile(n): return bool(n) and n.get('metadata', {}).get('kind') == 'file'
seen, out = set(), []
for l in d.get('links', []):
    if l.get('relation') not in ('imports', 'import'): continue
    s, t = byid.get(l.get('source')), byid.get(l.get('target'))
    if not isfile(s) or not isfile(t): continue
    sf, tf = s.get('source_file'), t.get('source_file')
    if not sf or not tf or sf == tf: continue
    if sf.startswith('/') or tf.startswith('/'): continue   # never leak an absolute path
    if (sf, tf) in seen: continue
    seen.add((sf, tf)); out.append((sf, tf))
out.sort()
for sf, tf in out:
    print('%s\t%s' % (sf, tf))
PY
)"
  [ -n "$edges" ] || return 0
  printf '\n### graphify-enriched cross-file edges\n\n'
  printf 'Additional file→file `imports` edges from `graphify-out/graph.json` (optional accelerator;\n'
  printf 'absent without graphify).\n\n'
  printf '%s\n' "$edges" | _cm_group_edges
}

# _cm_render_project — the PROJECT-mode report body. Same section shapes as the engine map (module
# roles, who-imports-whom, config-key → consumers), language-aware. Runs with cwd == ROOT.
_cm_render_project() {
  local lang name style
  name="${PWD##*/}"
  lang="$(_cm_detect_lang)"
  local files=()
  local f
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(_cm_srcfiles "$lang")

  printf '# %s codemap\n\n' "$name"
  printf '> Generated by `herd codemap` — a native scan of this project'"'"'s %s source tree.\n' "$lang"
  printf '> **Do not edit by hand;** run `herd codemap` to refresh. Deterministic: an unchanged tree\n'
  printf '> yields a byte-identical map.\n\n'

  if [ "$lang" = unknown ] || [ "${#files[@]}" -eq 0 ]; then
    printf '## Modules\n\n'
    printf 'No recognized source tree detected (looked for node/python/go/rust/java markers). Nothing\n'
    printf 'to map — `herd codemap` covers file-level structure of a supported language'"'"'s source tree.\n'
    return
  fi

  case "$lang" in python) style=hash ;; *) style=slash ;; esac

  # 1. Module roles.
  printf '## Modules\n\n'
  printf 'Role summarized from each file'"'"'s top-of-file comment/docstring.\n\n'
  _cm_roles "$style" "${files[@]}" | while IFS=$'\t' read -r f role; do
    printf -- '- `%s` — %s\n' "$f" "$role"
  done

  # 2. Who imports whom (local edges only; sorted + grouped by importer).
  printf '\n## Who imports whom\n\n'
  printf 'Local import edges between project files (external/library imports omitted).\n\n'
  _cm_import_edges "$lang" "${files[@]}" | _cm_group_edges
  _cm_graphify_enrich

  # 3. Config key → consumers (environment-variable read sites).
  printf '\n## Config key → consumers\n\n'
  printf 'Environment variables the project reads (heuristic: `getenv`/`process.env`/… call sites).\n\n'
  _cm_env_pairs "$lang" "${files[@]}" | LC_ALL=C sort | awk -F'\t' '
    { if ($1!=cur){ if(cur!=""){print line} cur=$1; line="- `" cur "` \342\206\222 `" $2 "`" }
      else line=line ", `" $2 "`" }
    END{ if(cur!="") print line }
  '
}

# ── Refresh (default) / --check (read-only staleness probe) ────────────────────────────────────────
# main [--check]
#   (no arg) REFRESH: regenerate the map and write $OUT only when its content actually changed.
#   --check  PROBE:   regenerate to a temp file and diff it against the committed $OUT WITHOUT ever
#                     writing $OUT (or creating its directory) — exit 0 when the committed map is
#                     byte-identical to a fresh scan (fresh), non-zero when it is missing or drifted
#                     (stale). The cheap, side-effect-free guard the watcher's post-merge auto-refresh
#                     and `herd status`' informational freshness row both build on.
main() {
  local mode="refresh" tmp outlabel delta
  case "${1:-}" in
    --check) mode="check" ;;
    "")      : ;;
    *)       printf 'codemap.sh: unknown argument: %s (expected --check or none)\n' "$1" >&2; return 2 ;;
  esac

  tmp="$(mktemp)"
  if [ "$CM_MODE" = project ]; then
    ( cd "$ROOT" && _cm_render_project ) > "$tmp"
  else
    ( cd "$ROOT" && _cm_render ) > "$tmp"
  fi
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
      printf '%s — STALE (out of date; run `herd codemap` to refresh)\n' "$outlabel" >&2
    else
      printf '%s — STALE (missing; run `herd codemap` to generate)\n' "$outlabel" >&2
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
