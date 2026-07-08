#!/usr/bin/env bash
# tests/test-seam-conformance.sh — the SEAM-CONFORMANCE LINT (HERD-160).
#
# The engine deliberately routes each cross-cutting concern through ONE seam so a single swap changes
# behavior everywhere: runtime control-surface calls go through scripts/herd/driver.sh, config loading
# through herd-config.sh, colour through theme.sh, and journal writes through journal.sh. When a new
# script hard-wires `herdr …`, sources `.herd/config` by hand, prints a raw ANSI escape, or calls
# journal_append with the machinery unloaded, the seam silently rots — the exact drift the 2026-07-08
# contract-drift audit catalogued. This lint makes that drift a RED test instead of a code review a
# human might miss.
#
# It enforces FOUR architectural rules over the engine surface (scripts/herd/*.sh, its backends/, and
# bin/herd):
#   1. raw-runtime  — a raw `herdr notification|agent list|pane run` OUTSIDE the driver seam
#                     (scripts/herd/driver.sh) and its sim stubs. This rule is ALSO the enforcement
#                     rail for the driver-portability migration (HERD-150 P2–P5): P5 extends
#                     RAW_RUNTIME_PATTERNS with the raw-claude patterns once those call sites are
#                     factored behind the driver — see the pattern comment below.
#   2. config-source — a direct `. .herd/config` / `source .herd/config` OUTSIDE herd-config.sh (which
#                     owns config discovery + the foreign-project reader _herd_read_project_config).
#   3. raw-ansi     — a raw ANSI escape (\033[ / \e[ / \x1b[ / [) OUTSIDE theme.sh + the theme
#                     palettes (which are not on the scanned engine surface).
#   4. journal-unsourced — a `journal_append` call in a file that neither sources journal.sh NOR
#                     guards the call with `command -v journal_append` (the best-effort pattern).
#
# It SHIPS GREEN and RATCHETS: the not-yet-migrated legacy surface is grandfathered per rule (the
# GF_* lists), and every grandfather entry is a wholesale file exemption that only ever SHRINKS as the
# migration progresses. A NEW violation in any non-grandfathered file — or new drift in a file the
# GF list does not name — fails the lint. Two finer escape hatches exist so the ratchet never blocks
# legitimate work: shrink a GF_* list when a file is migrated, or tag a single intentional line with a
# `# seam-lint-ok` comment (both are explicit and reviewable).
#
# Structure: PART A drives the scanner against synthetic temp files (proves it CATCHES each violation,
# IGNORES comments/tagged lines, and PASSES clean files — the red-first proof the lint itself works);
# PART B runs the scanner over the REAL engine tree and asserts zero non-grandfathered violations.
#
# Fully hermetic: static text scan + local temp files. No herdr, no claude, no network, no git.
# Run:  bash tests/test-seam-conformance.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
GREP=/usr/bin/grep
command -v "$GREP" >/dev/null 2>&1 || GREP=grep

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
PASS=0
fail() { echo "FAIL: $1" >&2; exit 1; }
pass() { PASS=$((PASS+1)); }

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Rule patterns
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# RAW_RUNTIME_PATTERNS — the runtime control-surface calls that MUST route through the driver seam
# (scripts/herd/driver.sh: herd_driver_notify / herd_driver_agent_list_json / herd_driver_send_text)
# instead of being hard-wired to a runtime. Today: raw herdr. P5 of the driver-portability migration
# (HERD-150) EXTENDS this alternation with the raw-claude patterns — e.g. add `|claude --model|claude -p`
# — once those call sites are factored behind the driver, and grandfathers the not-yet-migrated files
# in GF_raw_runtime exactly as raw-herdr is grandfathered here. The alternation is the single extension
# point so the rail grows without touching the scanner.
RAW_RUNTIME_PATTERNS='herdr (notification|agent list|pane run)'

# CONFIG_SOURCE_PATTERN — a shell `.`/`source` of a `.herd/config` file. The trailing class stops it
# matching `.herd/config.local`-only helpers spuriously — both baseline and overlay belong to the
# loader (herd-config.sh), which is excluded.
CONFIG_SOURCE_PATTERN='(^|;|[[:space:]])(\.|source)[[:space:]]+"?[^"|;&]*\.herd/config'

# RAW_ANSI_PATTERN — a raw CSI introducer written as a literal escape (octal \033, \e, hex \x1b, or
# unicode ), the drift theme.sh's C_* palette exists to prevent.
RAW_ANSI_PATTERN='\\(033|e|x1b|u001b)\['

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# Grandfather lists — the NOT-YET-MIGRATED legacy surface, per rule. SHRINK-ONLY: each entry is a
# whole-file exemption a future migration removes. Space-separated file BASENAMES.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# raw-runtime: the lanes/consoles that still hard-wire herdr (driver-portability migration P2–P5).
GF_raw_runtime="agent-watch.sh bin/herd coordinator.sh fleet.sh herd-feature.sh herd-resolve.sh herd-review.sh research-step.sh research.sh scribe-step.sh scribe.sh status.sh"

# config-source: bin/herd reads a specific project's REVIEW_CHECKLIST inline; fleet.sh reads FOREIGN
# projects' configs during fan-out (a legitimate cross-project read the current-project loader can't do).
GF_config_source="bin/herd fleet.sh"

# raw-ansi: the view/preview panes + preflight that still emit raw escapes rather than theme.sh C_*.
GF_raw_ansi="app-monitor.sh backlog-view.sh coordinator.sh herd-preflight.sh task-spec-view.sh"

# Global per-rule exclusions — the seam OWNERS themselves (they legitimately contain the raw form).
EX_raw_runtime="driver.sh"            # the driver seam IS the one place raw herdr lives
EX_config_source="herd-config.sh"     # the config loader owns `. .herd/config`
EX_raw_ansi="theme.sh"                # the palette owner
EX_journal="driver.sh"                # the driver guards journal_append; it is the seam-internal caller

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# The scanner
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# _engine_files — the scanned surface, one path per line: every scripts/herd/*.sh (NOT the sim/
# subdir — a non-recursive glob), the pluggable backends, and bin/herd.
_engine_files() {
  ls "$ROOT"/scripts/herd/*.sh "$ROOT"/scripts/herd/backends/*.sh "$ROOT/bin/herd" 2>/dev/null
}

# _code_stream <file> — emit the file with NON-CODE lines BLANKED (line count + numbering preserved):
# full-line comments (first non-space char is #) and any line carrying a `seam-lint-ok` exemption tag
# become empty, so `grep -nE` downstream reports the ORIGINAL line number and matches raw line content
# (a `^`/leading-space anchor is honoured — the line-number prefix is added AFTER the match).
_code_stream() {
  awk '{ s=$0; sub(/^[ \t]+/,"",s); if (s ~ /^#/ || $0 ~ /seam-lint-ok/) print ""; else print $0 }' "$1"
}

# _scan_file <file> <ere> — print "<lineno>:<line>" for each CODE line matching <ere> (empty = clean).
_scan_file() {
  _code_stream "$1" | "$GREP" -nE "$2" || true
}

# _journal_violates <file> — success (0) iff <file> calls journal_append WITHOUT the machinery loaded:
# it invokes journal_append on a code line yet neither sources journal.sh nor guards with a
# `command -v journal_append` presence check. That guarded best-effort form is the sanctioned pattern.
_journal_violates() {
  local f="$1"
  _code_stream "$f" | "$GREP" -qE '\bjournal_append\b' || return 1     # no call at all → fine
  "$GREP" -qE 'journal\.sh' "$f" && return 1                           # sources the seam → fine
  "$GREP" -qE 'command -v journal_append' "$f" && return 1             # guarded best-effort → fine
  return 0
}

# _conformance <ere> <exclude-basenames> — scan the whole engine tree for <ere>, honouring the
# space-separated basename exclusion set. Prints "<file>:<lineno>:<line>" per violation; empty = clean.
# _excluded <file> <exclude-set> — success iff <file> is exempt. An exclusion entry matches either the
# file BASENAME (e.g. driver.sh) or its ROOT-relative path (e.g. bin/herd).
_excluded() {
  local f="$1" set="$2" base rel
  base="$(basename "$f")"; rel="${f#"$ROOT"/}"
  case " $set " in *" $base "*|*" $rel "*) return 0 ;; esac
  return 1
}
_conformance() {
  local ere="$1" exclude="$2" f hits
  while IFS= read -r f; do
    [ -n "$f" ] || continue
    _excluded "$f" "$exclude" && continue
    hits="$(_scan_file "$f" "$ere")"
    [ -n "$hits" ] && printf '%s\n' "$hits" | while IFS= read -r h; do printf '%s:%s\n' "$f" "$h"; done
  done < <(_engine_files)
}

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART A — the scanner works: it CATCHES each violation, IGNORES comments + tagged lines, PASSES clean.
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# ── 1. raw-runtime ────────────────────────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\nherdr notification show "hi" --body x\n' > "$T/a1.sh"
[ -n "$(_scan_file "$T/a1.sh" "$RAW_RUNTIME_PATTERNS")" ] \
  || fail "(A1) scanner missed a raw 'herdr notification' call"
pass
printf '#!/usr/bin/env bash\nj="$(herdr agent list 2>/dev/null)"\n' > "$T/a2.sh"
[ -n "$(_scan_file "$T/a2.sh" "$RAW_RUNTIME_PATTERNS")" ] \
  || fail "(A2) scanner missed a raw 'herdr agent list' call"
pass
# a pure comment mentioning the raw call is NOT a violation
printf '#!/usr/bin/env bash\n# this used to call herdr pane run directly\n:\n' > "$T/a3.sh"
[ -z "$(_scan_file "$T/a3.sh" "$RAW_RUNTIME_PATTERNS")" ] \
  || fail "(A3) scanner flagged a comment mentioning herdr pane run"
pass
# an explicit inline exemption tag suppresses the finding
printf '#!/usr/bin/env bash\nherdr pane run "$p" "$c"  # seam-lint-ok: legacy path pending P5\n' > "$T/a4.sh"
[ -z "$(_scan_file "$T/a4.sh" "$RAW_RUNTIME_PATTERNS")" ] \
  || fail "(A4) seam-lint-ok tag did not suppress the raw-runtime finding"
pass
# a driver-routed call is clean
printf '#!/usr/bin/env bash\nherd_driver_notify "title" "body"\n' > "$T/a5.sh"
[ -z "$(_scan_file "$T/a5.sh" "$RAW_RUNTIME_PATTERNS")" ] \
  || fail "(A5) a driver-routed notify was wrongly flagged"
pass

# ── 2. config-source ──────────────────────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\n. "$root/.herd/config"\n' > "$T/c1.sh"
[ -n "$(_scan_file "$T/c1.sh" "$CONFIG_SOURCE_PATTERN")" ] \
  || fail "(A6) scanner missed a direct '. .herd/config' source"
pass
printf '#!/usr/bin/env bash\nsource "$d/.herd/config"\n' > "$T/c2.sh"
[ -n "$(_scan_file "$T/c2.sh" "$CONFIG_SOURCE_PATTERN")" ] \
  || fail "(A7) scanner missed a 'source .herd/config'"
pass
# sourcing herd-config.sh (the seam) is clean
printf '#!/usr/bin/env bash\n. "$HERE/herd-config.sh"\n' > "$T/c3.sh"
[ -z "$(_scan_file "$T/c3.sh" "$CONFIG_SOURCE_PATTERN")" ] \
  || fail "(A8) sourcing herd-config.sh was wrongly flagged as a direct config source"
pass

# ── 3. raw-ansi ───────────────────────────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\nprintf %s\n' "\$'\\033[32mgreen\\033[0m'" > "$T/n1.sh"
[ -n "$(_scan_file "$T/n1.sh" "$RAW_ANSI_PATTERN")" ] \
  || fail "(A9) scanner missed a raw \\033[ ANSI escape"
pass
printf '#!/usr/bin/env bash\nprintf %s\n' "\$'\\e[1mbold\\e[0m'" > "$T/n2.sh"
[ -n "$(_scan_file "$T/n2.sh" "$RAW_ANSI_PATTERN")" ] \
  || fail "(A10) scanner missed a raw \\e[ ANSI escape"
pass
# a theme C_* reference is clean
printf '#!/usr/bin/env bash\nprintf "%%sX%%s" "$C_GREEN" "$C_RST"\n' > "$T/n3.sh"
[ -z "$(_scan_file "$T/n3.sh" "$RAW_ANSI_PATTERN")" ] \
  || fail "(A11) a theme C_* colour reference was wrongly flagged"
pass

# ── 4. journal-unsourced ──────────────────────────────────────────────────────────────────────────
printf '#!/usr/bin/env bash\njournal_append some_event key val\n' > "$T/j1.sh"
_journal_violates "$T/j1.sh" || fail "(A12) scanner missed an unsourced/unguarded journal_append"
pass
# sources journal.sh → fine
printf '#!/usr/bin/env bash\n. "$HERE/journal.sh"\njournal_append e k v\n' > "$T/j2.sh"
_journal_violates "$T/j2.sh" && fail "(A13) journal_append flagged despite sourcing journal.sh"
pass
# guarded best-effort → fine
printf '#!/usr/bin/env bash\ncommand -v journal_append >/dev/null 2>&1 && journal_append e k v\n' > "$T/j3.sh"
_journal_violates "$T/j3.sh" && fail "(A14) guarded journal_append (command -v) wrongly flagged"
pass
# no call at all → fine
printf '#!/usr/bin/env bash\n:\n' > "$T/j4.sh"
_journal_violates "$T/j4.sh" && fail "(A15) a file with no journal_append call was flagged"
pass

# ══════════════════════════════════════════════════════════════════════════════════════════════════
# PART B — the real engine tree is conformant (modulo the shrink-only grandfather lists).
# ══════════════════════════════════════════════════════════════════════════════════════════════════

# Every grandfathered basename must still name a real engine file — a typo'd or stale entry would
# silently widen the exemption. (Stale-but-real entries are tolerated: a GF list only ever shrinks.)
_gf_files_exist() {
  local list="$1" b
  for b in $list; do
    case "$b" in
      */*) [ -e "$ROOT/$b" ] || fail "grandfather list names a non-existent file: $b" ;;
      *)   [ -e "$ROOT/scripts/herd/$b" ] || [ -e "$ROOT/scripts/herd/backends/$b" ] \
             || fail "grandfather list names a non-existent file: $b" ;;
    esac
  done
}
_gf_files_exist "$GF_raw_runtime"
_gf_files_exist "$GF_config_source"
_gf_files_exist "$GF_raw_ansi"
pass

# ── B1. raw-runtime clean outside driver seam + grandfathered legacy ─────────────────────────────
v="$(_conformance "$RAW_RUNTIME_PATTERNS" "$EX_raw_runtime $GF_raw_runtime")"
[ -z "$v" ] || fail "(B1) raw herdr call outside the driver seam (route through scripts/herd/driver.sh, or add a seam-lint-ok tag / grandfather the file):
$v"
pass

# ── B2. config-source clean outside herd-config.sh + grandfathered legacy ────────────────────────
v="$(_conformance "$CONFIG_SOURCE_PATTERN" "$EX_config_source $GF_config_source")"
[ -z "$v" ] || fail "(B2) direct '.herd/config' source outside herd-config.sh (use _herd_read_project_config, or grandfather the file):
$v"
pass

# ── B3. raw-ansi clean outside theme.sh + grandfathered panes ────────────────────────────────────
v="$(_conformance "$RAW_ANSI_PATTERN" "$EX_raw_ansi $GF_raw_ansi")"
[ -z "$v" ] || fail "(B3) raw ANSI escape outside theme.sh (use the theme C_* palette, or grandfather the file):
$v"
pass

# ── B4. journal-unsourced clean across the whole tree (no grandfather needed) ────────────────────
jv=""
while IFS= read -r f; do
  [ -n "$f" ] || continue
  base="$(basename "$f")"
  case " $EX_journal " in *" $base "*) continue ;; esac
  _journal_violates "$f" && jv="${jv}${f}\n"
done < <(_engine_files)
[ -z "$jv" ] || fail "(B4) journal_append called without sourcing journal.sh or a 'command -v journal_append' guard:
$(printf '%b' "$jv")"
pass

echo "ALL PASS ($PASS checks)"
