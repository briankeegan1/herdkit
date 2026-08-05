#!/usr/bin/env bash
# test-adopt.sh — hermetic tests for `herd adopt` (HERD-520), the one-command localization of a
# CLONED herd project (epic HERD-517, docs/audits/2026-08-05-collaborator-onboarding.md).
#
# The defect being closed: a herd project COMMITS .herd/config, so a collaborator's clone inherits
# the AUTHOR's absolute PROJECT_ROOT / WORKTREES_DIR — paths that do not exist on this machine.
# Contracts asserted here, each against a fixture whose committed config carries a FOREIGN root:
#   (a) after `herd adopt`, `herd config get PROJECT_ROOT` resolves to the LOCAL path, and the
#       committed baseline .herd/config is byte-unchanged (the localization lives in the overlay).
#   (b) WORKTREES_DIR is localized to the sibling pool <PROJECT_ROOT>-trees and that directory EXISTS.
#   (c) .herd/config.local is ignored by git AND the clone is left undirtied (`git status` empty).
#   (d) a SECOND adopt is a no-op: it reports "no changes" and mutates no file.
#   (e) `herd adopt <path>` localizes THAT path, not cwd; a path with no .herd/config is refused.
#   (f) a LINKED git worktree is refused before any write (it would hijack a live control room).
#   (g) adopt never drives a watcher restart — the reload path is not reached even though
#       PROJECT_ROOT/WORKTREES_DIR are `requires=watcher` keys (the no-watcher-hang finding).
#
# Fully hermetic: local temp only, NO herdr/gh/network/model. HERD_SKIP_DOCTOR=1 keeps the doctor's
# hard-dep gate out of the assertions (it is proven by tests/test-doctor.sh); (h) covers the
# doctor-failure exit contract with the bypass OFF and a stubbed-away gh.
# Run:  bash tests/test-adopt.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; T="$(cd "$T" && pwd -P)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; okp(){ pass=$((pass+1)); }

# ── Stubs: a herdr that always fails + a pgrep that finds nothing, so ANY watcher/pane path this
#    command might reach is hermetic (and, per contract (g), provably never reached at all).
BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/pgrep"; chmod +x "$BIN/pgrep"
export PATH="$BIN:$PATH"
export HERD_SKIP_DOCTOR=1

# ── Stub capabilities manifest (9-column; PROJECT_ROOT/WORKTREES_DIR carry requires=watcher and NO
#    scope — exactly as templates/capabilities.tsv declares them, so adopt must force --local).
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\tgovernance\tvalue_shape\tenv_coupling\n'
  printf 'PROJECT_ROOT\tconfig\tProject git root\tAlways\twatcher\t\t\tfree\t\n'
  printf 'WORKTREES_DIR\tconfig\tWorktree pool\tAlways\twatcher\t\t\tfree\t\n'
  printf 'SCRIBE_BACKEND\tconfig\tTracker backend\tSet for a tracker\t\t\t\tfree\t\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

FOREIGN="/home/some-other-operator/source/emberglen"

# _make_clone <dir> — a git repo whose COMMITTED .herd/config names a FOREIGN absolute root, i.e.
# exactly what `git clone` of someone else's herd project hands you.
_make_clone() {
  local r="$1"
  mkdir -p "$r"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  mkdir -p "$r/.herd"
  cat > "$r/.herd/config" <<CFG
# .herd/config — committed baseline from the project's AUTHOR (comment preserved on purpose)
HERD_VERSION=1
PROJECT_ROOT="$FOREIGN"
WORKTREES_DIR="$FOREIGN-trees"
DEFAULT_BRANCH="origin/main"
SCRIBE_BACKEND="file"
CFG
  printf 'x\n' > "$r/README.md"
  git -C "$r" add .herd/config README.md
  git -C "$r" commit -q -m "seed"
}

# run <cwd> <args...> → `herd <args>` from cwd; combined output → $OUT, exit → $RC.
run() {
  local c="$1"; shift
  set +e
  OUT="$( cd "$c" && bash "$HERD" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ══════════════════════════════════════════════════════════════════════════════
# (a)+(b)+(c) the happy path: adopt a clone carrying a foreign committed root.
# ══════════════════════════════════════════════════════════════════════════════
P="$T/clone"; _make_clone "$P"
BASE_BEFORE="$(cat "$P/.herd/config")"

run "$P" adopt
[ "$RC" -eq 0 ] || fail "(a) adopt failed rc=$RC: $OUT"

# (a) the EFFECTIVE PROJECT_ROOT is now the local path — the contract the epic states.
run "$P" config get PROJECT_ROOT
{ [ "$RC" -eq 0 ] && [ "$OUT" = "$P" ]; } || fail "(a) config get PROJECT_ROOT != local path (got: '$OUT')"
okp

# (a) the localization landed in the OVERLAY; the committed baseline is byte-unchanged.
[ -f "$P/.herd/config.local" ] || fail "(a) .herd/config.local was not created"
grep -qE "^PROJECT_ROOT=\"$P\"" "$P/.herd/config.local" || fail "(a) PROJECT_ROOT not in the overlay: $(cat "$P/.herd/config.local")"
[ "$(cat "$P/.herd/config")" = "$BASE_BEFORE" ] || fail "(a) the COMMITTED .herd/config was mutated"
grep -qE "^PROJECT_ROOT=\"$FOREIGN\"" "$P/.herd/config" || fail "(a) baseline lost the author's PROJECT_ROOT"
okp

# (b) WORKTREES_DIR is the sibling pool and it EXISTS on disk.
run "$P" config get WORKTREES_DIR
{ [ "$RC" -eq 0 ] && [ "$OUT" = "$P-trees" ]; } || fail "(b) WORKTREES_DIR != <PROJECT_ROOT>-trees (got: '$OUT')"
[ -d "$P-trees" ] || fail "(b) the worktree pool $P-trees was not created"
okp

# (c) the overlay is ignored by git AND the clone is still clean (no committed .gitignore churn).
git -C "$P" check-ignore -q -- .herd/config.local || fail "(c) .herd/config.local is NOT gitignored"
[ -z "$(git -C "$P" status --porcelain)" ] || fail "(c) adopt DIRTIED the clone: $(git -C "$P" status --porcelain)"
[ ! -f "$P/.gitignore" ] || fail "(c) adopt wrote a committed .gitignore instead of a checkout-local exclude"
grep -qxF '.herd/config.local' "$P/.git/info/exclude" || fail "(c) the exclude entry is missing from .git/info/exclude"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (d) idempotence — a second adopt changes nothing and says so.
# ══════════════════════════════════════════════════════════════════════════════
OVERLAY_BEFORE="$(cat "$P/.herd/config.local")"
EXCLUDE_BEFORE="$(cat "$P/.git/info/exclude")"
run "$P" adopt
[ "$RC" -eq 0 ] || fail "(d) second adopt failed rc=$RC: $OUT"
grep -qi 'already localized' <<< "$OUT" || fail "(d) second adopt did not report a no-op: $OUT"
[ "$(cat "$P/.herd/config.local")" = "$OVERLAY_BEFORE" ] || fail "(d) second adopt mutated the overlay"
[ "$(cat "$P/.git/info/exclude")" = "$EXCLUDE_BEFORE" ] || fail "(d) second adopt appended a duplicate exclude line"
[ "$(cat "$P/.herd/config")" = "$BASE_BEFORE" ]         || fail "(d) second adopt mutated the baseline"
[ -z "$(git -C "$P" status --porcelain)" ]              || fail "(d) second adopt dirtied the clone"
okp

# A clone whose COMMITTED .gitignore already covers the overlay needs no exclude entry at all.
PG="$T/clone-gi"; _make_clone "$PG"
printf '.herd/config.local\n' > "$PG/.gitignore"
git -C "$PG" add .gitignore; git -C "$PG" commit -q -m gitignore
run "$PG" adopt
[ "$RC" -eq 0 ] || fail "(d2) adopt failed on a clone with a committed ignore rule: $OUT"
grep -qi 'already ignored' <<< "$OUT" || fail "(d2) adopt did not recognise the committed ignore rule: $OUT"
grep -qxF '.herd/config.local' "$PG/.git/info/exclude" 2>/dev/null && fail "(d2) adopt added a redundant exclude entry"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (e) the [path] argument + refusal on a non-herd directory.
# ══════════════════════════════════════════════════════════════════════════════
PA="$T/clone-arg"; _make_clone "$PA"
ELSEWHERE="$T/elsewhere"; mkdir -p "$ELSEWHERE"
run "$ELSEWHERE" adopt "$PA"
[ "$RC" -eq 0 ] || fail "(e) adopt <path> failed rc=$RC: $OUT"
grep -qE "^PROJECT_ROOT=\"$PA\"" "$PA/.herd/config.local" || fail "(e) adopt <path> did not localize the TARGET"
[ ! -e "$ELSEWHERE/.herd" ] || fail "(e) adopt <path> wrote into cwd instead of the target"
okp

BARE="$T/bare"; mkdir -p "$BARE"
run "$BARE" adopt
{ [ "$RC" -ne 0 ] && grep -q 'no .herd/config' <<< "$OUT"; } || fail "(e2) adopt on a non-herd dir was not refused (rc=$RC): $OUT"
run "$BARE" adopt "$T/does-not-exist"
{ [ "$RC" -ne 0 ] && grep -q 'no directory' <<< "$OUT"; } || fail "(e3) adopt on a missing path was not refused (rc=$RC): $OUT"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (f) a LINKED git worktree is refused BEFORE any write.
# ══════════════════════════════════════════════════════════════════════════════
PW="$T/clone-wt"; _make_clone "$PW"
WT="$T/clone-wt-linked"
git -C "$PW" worktree add -q --detach "$WT" >/dev/null 2>&1
run "$WT" adopt
{ [ "$RC" -ne 0 ] && grep -qi 'linked git worktree' <<< "$OUT"; } || fail "(f) a linked worktree was not refused (rc=$RC): $OUT"
[ ! -f "$WT/.herd/config.local" ] || fail "(f) the refusal still wrote an overlay"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (g) NO watcher restart: PROJECT_ROOT/WORKTREES_DIR are requires=watcher keys, so a plain
#     `config set` would drive `herd reload` — against a control room a fresh clone does not have.
#     adopt must defer instead (HERD_INIT_DEFER_APPLY), and say so.
# ══════════════════════════════════════════════════════════════════════════════
PR2="$T/clone-nowatch"; _make_clone "$PR2"
run "$PR2" adopt
[ "$RC" -eq 0 ] || fail "(g) adopt failed rc=$RC: $OUT"
grep -qi 'restarting the watcher' <<< "$OUT" && fail "(g) adopt reached the watcher-restart path: $OUT"
grep -qi 'deferred' <<< "$OUT" || fail "(g) adopt did not report the deferred apply: $OUT"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (h) the doctor runs LAST and never blocks the localization: with the bypass OFF and the hard
#     deps stubbed away, adopt still localizes, then exits non-zero naming the doctor.
# ══════════════════════════════════════════════════════════════════════════════
PD="$T/clone-doctor"; _make_clone "$PD"
BROKEN="$T/broken-bin"; mkdir -p "$BROKEN"
# A PATH with no gh at all (git stays, since the fixture repo needs it) → the doctor's hard-dep gate
# fails for a reason that has nothing to do with localizing paths.
set +e
OUT="$( cd "$PD" && env -u HERD_SKIP_DOCTOR PATH="$BROKEN:$(dirname "$(command -v git)"):/usr/bin:/bin" \
        bash "$HERD" adopt 2>&1 )"
RC=$?
set -e
[ "$RC" -ne 0 ] || fail "(h) adopt exited 0 despite a failing doctor: $OUT"
grep -qi 'dependency doctor' <<< "$OUT" || fail "(h) the exit did not name the doctor: $OUT"
grep -qE "^PROJECT_ROOT=\"$PD\"" "$PD/.herd/config.local" || fail "(h) the localization was rolled back / never applied: $OUT"
[ -d "$PD-trees" ] || fail "(h) the worktree pool was not created before the doctor ran"
okp

echo "ALL PASS ($pass tests)"
