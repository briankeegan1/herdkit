#!/usr/bin/env bash
# test-context-guard.sh — hermetic proof of the INVOCATION-CONTEXT guard (HERD-269).
#
# GROUNDING (the live incident): a builder followed a task-spec VERIFY step, ran `herd config set`
# + `herd reload` FROM ITS WORKTREE, and rebuilt the operator's control room — the live watcher died
# mid-run. Every .herd/config in a worktree names the SAME PROJECT_ROOT / watcher lock / panes as the
# control room (the worktree is a checkout of the repo that config is committed in), so the CLI had
# no way to tell "the operator reloading" from "a builder reloading". Now it does.
#
# The fixture is a REAL git repo plus a REAL `git worktree add` linked tree under a REAL
# WORKTREES_DIR, and it drives the REAL bin/herd — no stubbing of the thing under test. Nothing
# outside $T is read or written: JOURNAL_FILE is pinned to the fixture, and every actuator refusal
# happens BEFORE its command body, so not one pane, config or watcher can be touched even if the
# guard were wrong (a refusal that ran the body would fail assertion (b)'s exit code anyway).
#
# Asserts:
#   (a) each of the 10 enumerated ACTUATORS, run from the linked worktree, REFUSES (exit 3) with the
#       loud, specific message — and refuses BEFORE the command body (no .herd/config even needed)
#   (b) `herd config set` from the worktree leaves the config file BYTE-IDENTICAL (nothing partial)
#   (c) each READER (status, log, why, backlog, notes, config get|list|lint|sync, doctor, codemap,
#       conformance, cost, help, render, init) is NOT an actuator — builders read state freely; the
#       two readers that need no network are also driven live and must not print REFUSED
#   (d) the guard is per-SUBCOMMAND, not per-command: `config get` passes where `config set` refuses
#   (e) HERD_ALLOW_CONTROL_MUTATION=1 lets the actuator through AND journals control_mutation_bypass
#   (f) a refusal journals control_mutation_refused (the coordinator sees it within a watcher tick)
#   (g) FROM THE MAIN CHECKOUT the guard is byte-inert: every actuator returns 0, silently, with no
#       journal event. (Asserted at function level — invoking `herd reload` for real would rebuild
#       the caller's control room, which is the very bug under test.)
#   (h) clause (B): a builder tree that is a plain COPY (no git linkage) but lies inside
#       $WORKTREES_DIR is still guarded
#   (i) a git repo that is NOT a worktree and NOT under WORKTREES_DIR is never guarded (no false
#       positive on an ordinary main checkout elsewhere on disk)
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
PASS=0
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
ok()   { PASS=$(( PASS + 1 )); }

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT

# Pin the journal into the fixture BEFORE anything can append (HERD-223 discipline).
export JOURNAL_FILE="$T/journal.jsonl"
: > "$JOURNAL_FILE"

# ── fixture: a real repo, a real linked worktree, a real WORKTREES_DIR ───────────────────────────
MAIN="$T/proj"
TREES="$T/proj-trees"
mkdir -p "$MAIN" "$TREES"
git -C "$MAIN" init -q 2>/dev/null || fail "git init failed"
git -C "$MAIN" config user.email t@t.t
git -C "$MAIN" config user.name t
mkdir -p "$MAIN/.herd"
cat > "$MAIN/.herd/config" <<EOF
PROJECT_ROOT="$MAIN"
WORKTREES_DIR="$TREES"
WORKSPACE_NAME="ctxguard"
DEFAULT_BRANCH="main"
EOF
git -C "$MAIN" add -A
git -C "$MAIN" commit -qm init
git -C "$MAIN" worktree add -q "$TREES/feat" -b feat 2>/dev/null || fail "git worktree add failed"
[ -f "$TREES/feat/.herd/config" ] || fail "fixture: the worktree must carry the committed .herd/config (that is the whole hazard)"

# The actuator set, exactly as enumerated in scripts/herd/context-guard.sh.
ACTUATORS=(
  "config set DEFAULT_BRANCH trunk"
  "theme set nord"
  "governance apply /dev/null"
  "backend switch file"
  "reload"
  "pane watch"
  "sweep"
  "update"
  "upgrade"
  "agent-update"
)

# ── (a) every actuator refuses from the linked worktree, loudly, exit 3 ──────────────────────────
for a in "${ACTUATORS[@]}"; do
  # shellcheck disable=SC2086
  out="$( cd "$TREES/feat" && bash "$HERD" $a 2>&1 )"
  rc=$?
  [ "$rc" -eq 3 ] || fail "(a) 'herd $a' from a worktree must exit 3 (refusal), got $rc"
  case "$out" in
    *"REFUSED — this is a builder worktree"*) ;;
    *) fail "(a) 'herd $a' must refuse LOUDLY with the specific message; got: $out" ;;
  esac
  case "$out" in
    *"HERD_ALLOW_CONTROL_MUTATION=1"*) ;;
    *) fail "(a) 'herd $a' refusal must name the escape hatch" ;;
  esac
  case "$out" in
    *"herd status"*) ;;
    *) fail "(a) 'herd $a' refusal must tell the builder what to do instead" ;;
  esac
done
ok

# The refusal precedes the command body: it fires even with NO .herd/config to load.
bare="$T/bare"
git -C "$MAIN" worktree add -q "$bare" -b bare 2>/dev/null || fail "fixture: second worktree"
rm -rf "$bare/.herd"
out="$( cd "$bare" && bash "$HERD" reload 2>&1 )"; rc=$?
[ "$rc" -eq 3 ] || fail "(a) the guard must refuse BEFORE the body's 'no .herd/config' die, got $rc"
case "$out" in *"REFUSED"*) ;; *) fail "(a) bare-worktree reload must refuse" ;; esac
ok

# ── (b) a refused 'config set' leaves the config byte-identical ──────────────────────────────────
before="$(cat "$TREES/feat/.herd/config")"
( cd "$TREES/feat" && bash "$HERD" config set DEFAULT_BRANCH trunk >/dev/null 2>&1 )
after="$(cat "$TREES/feat/.herd/config")"
[ "$before" = "$after" ] || fail "(b) a refused 'config set' must not write one byte to .herd/config"
ok

# ── (c)+(d) readers are not actuators ────────────────────────────────────────────────────────────
# shellcheck source=/dev/null
. "$REPO/scripts/herd/context-guard.sh"
for fn in herd_context_guard _herd_context_is_worktree _herd_context_is_actuator; do
  command -v "$fn" >/dev/null 2>&1 || fail "(c) context-guard.sh must define $fn"
done

READERS=(
  "status" "log" "why 1" "backlog" "notes list" "note x" "doctor" "codemap --check"
  "symbol-index --check" "conformance report" "cost" "stats" "advise q" "deps list"
  "config get DEFAULT_BRANCH" "config list" "config lint" "config sync" "config models"
  "theme list" "theme preview" "governance export" "backend" "render" "init" "help"
  "map" "ledger list" "link list" "fleet status" "approve list" "changelog" "triage report"
)
for r in "${READERS[@]}"; do
  # shellcheck disable=SC2086
  if _herd_context_is_actuator $r >/dev/null 2>&1; then
    fail "(c) READ-ONLY 'herd $r' must never be treated as a control-room mutation"
  fi
done
ok

# And the actuators ARE recognized, by their canonical names.
for a in "${ACTUATORS[@]}"; do
  # shellcheck disable=SC2086
  name="$(_herd_context_is_actuator $a)" || fail "(c) 'herd $a' must be recognized as an actuator"
  [ -n "$name" ] || fail "(c) actuator '$a' must report a canonical name"
done
ok

# (d) live: the two network-free readers pass from inside the worktree.
for r in "config get DEFAULT_BRANCH" "config list"; do
  # shellcheck disable=SC2086
  out="$( cd "$TREES/feat" && bash "$HERD" $r 2>&1 )"
  case "$out" in
    *"REFUSED"*) fail "(d) reader 'herd $r' must run from a builder worktree, not refuse" ;;
  esac
done
# config get must actually resolve the value (the reader really ran).
out="$( cd "$TREES/feat" && bash "$HERD" config get DEFAULT_BRANCH 2>/dev/null )"
[ "$out" = "main" ] || fail "(d) 'config get' from a worktree must return the value, got '$out'"
ok

# ── (f) a refusal journals control_mutation_refused ──────────────────────────────────────────────
: > "$JOURNAL_FILE"
( cd "$TREES/feat" && JOURNAL_FILE="$JOURNAL_FILE" bash "$HERD" reload >/dev/null 2>&1 )
grep -q '"event_type":[[:space:]]*"control_mutation_refused"' "$JOURNAL_FILE" \
  || grep -q 'control_mutation_refused' "$JOURNAL_FILE" \
  || fail "(f) a refusal must journal control_mutation_refused; journal: $(cat "$JOURNAL_FILE")"
grep -q 'reload' "$JOURNAL_FILE" || fail "(f) the refusal event must name the actuator"
ok

# ── (e) the escape hatch lets it through AND journals the bypass ─────────────────────────────────
: > "$JOURNAL_FILE"
out="$( cd "$TREES/feat" && HERD_ALLOW_CONTROL_MUTATION=1 JOURNAL_FILE="$JOURNAL_FILE" \
        bash "$HERD" config set 2>&1 )"
rc=$?
[ "$rc" -ne 3 ] || fail "(e) HERD_ALLOW_CONTROL_MUTATION=1 must not refuse"
case "$out" in
  *"REFUSED"*) fail "(e) the escape hatch must bypass the refusal" ;;
esac
case "$out" in
  *"HERD_ALLOW_CONTROL_MUTATION=1"*) ;;
  *) fail "(e) the bypass must WARN loudly (never a silent actuation)" ;;
esac
# It reached the command body: 'config set' with no KEY/VALUE dies on its own usage message.
case "$out" in
  *"usage: herd config set"*) ;;
  *) fail "(e) the bypass must reach the real command body; got: $out" ;;
esac
grep -q 'control_mutation_bypass' "$JOURNAL_FILE" \
  || fail "(e) the bypass must be JOURNALED; journal: $(cat "$JOURNAL_FILE")"
ok

# ── (g) byte-inert from the main checkout ────────────────────────────────────────────────────────
: > "$JOURNAL_FILE"
(
  cd "$MAIN" || exit 1
  unset WORKTREES_DIR
  _herd_context_is_worktree && exit 1   # a main checkout is never a worktree
  for a in reload sweep update upgrade agent-update; do
    out="$(herd_context_guard "$a" 2>&1)" || exit 1
    [ -z "$out" ] || exit 1              # silent
  done
  out="$(herd_context_guard config set K V 2>&1)" || exit 1
  [ -z "$out" ] || exit 1
) || fail "(g) from the main checkout every actuator must pass the guard silently (rc 0, no output)"
[ ! -s "$JOURNAL_FILE" ] || fail "(g) the guard must journal NOTHING from the main checkout"
ok

# ── (h) clause B: a plain COPY inside WORKTREES_DIR is still guarded ─────────────────────────────
copy="$TREES/copied"
mkdir -p "$copy"
(
  cd "$copy" || exit 1
  export WORKTREES_DIR="$TREES"
  _herd_context_is_worktree || exit 1
) || fail "(h) a non-git builder tree inside WORKTREES_DIR must still be guarded"
ok

# ── (i) no false positive on an unrelated main checkout ──────────────────────────────────────────
other="$T/other"
mkdir -p "$other"
git -C "$other" init -q
(
  cd "$other" || exit 1
  export WORKTREES_DIR="$TREES"
  _herd_context_is_worktree && exit 1
  exit 0
) || fail "(i) an ordinary git checkout outside WORKTREES_DIR must never be guarded"
ok

printf 'ALL PASS (%d groups) — test-context-guard.sh\n' "$PASS"
