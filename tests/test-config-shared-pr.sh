#!/usr/bin/env bash
# test-config-shared-pr.sh — hermetic tests for `herd config set --shared` (HERD-62).
#
# --shared applies a PROJECT-scoped change to the committed baseline .herd/config AND opens a tiny
# single-file PR (branch config/<key>) so operators who cannot push to the default branch still
# propagate policy the gated way. Contracts covered:
#   (1) happy path: local baseline edited; a config/<key> branch is pushed to origin carrying exactly
#       the one-key old->new change; `gh pr create` is called with a body stating old->new + reason;
#       the operator's own checkout is never switched off its branch and no worktree is leaked.
#   (2) re-run: with the value already applied locally, --shared still (re)opens/refreshes the PR
#       (it does NOT short-circuit like a plain no-op set) — proven by the "already exists" gh path.
#   (3) machine-scoped keys are REFUSED for --shared (their per-user value must never be committed).
#   (4) --local and --shared are mutually exclusive.
#   (5) secrets refusal + key validation are IDENTICAL to a normal set (secret-shaped / DENY_PATHS /
#       unknown key all rejected before any branch/PR work).
#   (6) degrade: with no gh on PATH, the local change still applies and the command warns (no die).
#
# Fully hermetic: local temp git repos + a bare "origin"; gh/herdr/pgrep stubbed on PATH; NO network,
# NO real GitHub, NO model. Mirrors the stubbing style of test-cli-config.sh / test-config-local-overlay.sh.
# Run:  bash tests/test-config-shared-pr.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; okp(){ pass=$((pass+1)); }

# ── Stub pgrep + herdr on PATH (keep any reload path hermetic) ────────────────
BIN="$T/bin"; mkdir -p "$BIN"
cat > "$BIN/pgrep" <<'STUB'
#!/usr/bin/env bash
exit 0
STUB
chmod +x "$BIN/pgrep"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"

# ── Stateful gh stub: records every invocation, tracks which branches already have a PR ───────────
# `gh pr create --head <branch> --body <body>`: succeeds the FIRST time for a branch (recording the
# body under GHSTATE/body-<key>), then EXITS 1 ("already exists") on any later create for that same
# branch — exactly how real gh behaves. `gh pr view <branch>`: exit 0 iff a PR already exists for it.
GHLOG="$T/gh.log"; GHSTATE="$T/gh-state"; mkdir -p "$GHSTATE"
cat > "$BIN/gh" <<STUB
#!/usr/bin/env bash
{ printf 'ARGS:'; for a in "\$@"; do printf ' [%s]' "\$a"; done; printf '\n'; } >> "$GHLOG"
sub="\$1 \$2"; shift 2 || true
head=""; body=""; view_branch=""
# For 'pr view', the branch is the first positional; capture it before flag parsing eats positionals.
case "\$sub" in "pr view") view_branch="\$1" ;; esac
while [ "\$#" -gt 0 ]; do
  case "\$1" in
    --head) head="\$2"; shift 2 ;;
    --body) body="\$2"; shift 2 ;;
    *) shift ;;
  esac
done
key_of(){ printf '%s' "\$1" | tr '/' '_'; }
case "\$sub" in
  "pr create")
    k="\$(key_of "\$head")"
    [ -f "$GHSTATE/pr-\$k" ] && exit 1
    printf '%s' "\$body" > "$GHSTATE/body-\$k"
    : > "$GHSTATE/pr-\$k"
    exit 0 ;;
  "pr view")
    k="\$(key_of "\$view_branch")"
    [ -f "$GHSTATE/pr-\$k" ] && exit 0 || exit 1 ;;
esac
exit 0
STUB
chmod +x "$BIN/gh"
export PATH="$BIN:$PATH"

# ── Stub capabilities manifest (6-column: name kind description when requires scope) ──────────────
# CLAIM_REQUIRED: project-scoped, NO requires (clean propagation case — no watcher restart).
# MODEL_QUICK:    machine-scoped (must be refused for --shared).
CAPS="$T/capabilities.tsv"
{
  printf 'name\tkind\tdescription\twhen_to_surface\trequires\tscope\n'
  printf 'CLAIM_REQUIRED\tconfig\tRequire a claim before building\tMulti-operator\t\tproject\n'
  printf 'MODEL_QUICK\tconfig\tQuick-lane model tier\tPer-user cost\t\tmachine\n'
} > "$CAPS"
export HERD_CAPABILITIES_FILE="$CAPS"

# ── project fixture: git repo with its OWN bare origin; .herd/config COMMITTED + pushed to origin/main.
# Sets the global $BARE to this project's origin so assertions can inspect the pushed branch.
BARE=""
_make_project() {
  local r="$1"; mkdir -p "$r"; local r_real; r_real="$(cd "$r" && pwd -P)"
  BARE="$r.origin.git"; git init -q --bare "$BARE"
  git -C "$r" init -q -b main
  git -C "$r" config user.email t@t.t; git -C "$r" config user.name t
  mkdir -p "$r/.herd" "$r/trees"
  cat > "$r/.herd/config" <<CFG
# .herd/config — baseline fixture (comment preserved on purpose)
HERD_VERSION=1
PROJECT_ROOT="$r_real"
WORKTREES_DIR="$r_real/trees"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="sharedws"
CLAIM_REQUIRED="off"
MODEL_QUICK="claude-baseline"
CFG
  git -C "$r" add -A; git -C "$r" commit -q -m init
  git -C "$r" remote add origin "$BARE"
  git -C "$r" push -q -u origin main
}

# run <ROOT> <args...> → `herd <args>` in ROOT; combined output → $OUT, exit → $RC.
run() {
  local r="$1"; shift
  set +e
  OUT="$( cd "$r" && HERD_RELOAD_SKIP_LAUNCH=1 bash "$HERD" "$@" 2>&1 )"
  RC=$?
  set -e
}

# ══════════════════════════════════════════════════════════════════════════════
# (1) Happy path — apply locally + open the config PR.
# ══════════════════════════════════════════════════════════════════════════════
P="$T/p1"; _make_project "$P"
run "$P" config set --shared --reason "enforce claims before builds" CLAIM_REQUIRED on
[ "$RC" -eq 0 ] || fail "(1) --shared set failed (rc=$RC): $OUT"
# local baseline edited (applied immediately for this operator)
grep -qE '^CLAIM_REQUIRED="on"' "$P/.herd/config" || fail "(1) local baseline not updated ($(grep CLAIM_REQUIRED "$P/.herd/config"))"
# a config/CLAIM_REQUIRED branch was pushed to origin carrying the one-key change
git -C "$BARE" rev-parse --verify --quiet refs/heads/config/CLAIM_REQUIRED >/dev/null \
  || fail "(1) config/CLAIM_REQUIRED branch was not pushed to origin"
git -C "$BARE" show config/CLAIM_REQUIRED:.herd/config | grep -qE '^CLAIM_REQUIRED="on"' \
  || fail "(1) pushed branch does not carry CLAIM_REQUIRED=on"
# it must be a SINGLE-file, single-key diff vs main (only .herd/config changed; only CLAIM_REQUIRED line)
dieffiles="$(git -C "$BARE" diff --name-only main config/CLAIM_REQUIRED)"
[ "$dieffiles" = ".herd/config" ] || fail "(1) branch changed more than .herd/config: [$dieffiles]"
changed_keys="$(git -C "$BARE" diff main config/CLAIM_REQUIRED -- .herd/config | grep -E '^\+[A-Za-z_]+=' || true)"
printf '%s\n' "$changed_keys" | grep -qE '^\+CLAIM_REQUIRED="on"' || fail "(1) diff missing +CLAIM_REQUIRED=on ($changed_keys)"
[ "$(printf '%s\n' "$changed_keys" | grep -c .)" -eq 1 ] || fail "(1) diff touched more than one key: $changed_keys"
# gh pr create was invoked with a body stating old->new + the reason
grep -q 'ARGS:.*\[pr\] \[create\]' "$GHLOG" || fail "(1) gh pr create was not called ($(cat "$GHLOG"))"
BODY="$(cat "$GHSTATE/body-config_CLAIM_REQUIRED")"
printf '%s' "$BODY" | grep -q 'off' && printf '%s' "$BODY" | grep -q 'on' || fail "(1) PR body missing old->new ($BODY)"
printf '%s' "$BODY" | grep -q 'enforce claims before builds' || fail "(1) PR body missing the --reason ($BODY)"
# the operator's own checkout is untouched: still on main.
[ "$(git -C "$P" symbolic-ref --short HEAD)" = "main" ] || fail "(1) operator checkout was switched off main"
# HERD-74: the config worktree now PERSISTS in the pool (WORKTREES_DIR) so the STANDARD watcher gate
# discovers + gates + merges + reaps it (agent-watch.sh finds work via `git worktree list`, not open
# PRs). It used to be a throwaway removed at the end — which left the PR ungated forever (PRs #190/#191).
CWT="$P/trees/config-CLAIM_REQUIRED"
[ -d "$CWT" ] || fail "(1) config worktree not left in the pool for watcher adoption ($(git -C "$P" worktree list))"
[ "$(git -C "$CWT" symbolic-ref --short HEAD)" = "config/CLAIM_REQUIRED" ] || fail "(1) config worktree not checked out on config/CLAIM_REQUIRED ($(git -C "$CWT" symbolic-ref --short HEAD 2>&1))"
grep -qE '^CLAIM_REQUIRED="on"' "$CWT/.herd/config" || fail "(1) config worktree does not carry the change"
# exactly two worktrees now: the operator's main checkout + the one adopted config worktree (no leak).
[ "$(git -C "$P" worktree list | wc -l | tr -d ' ')" = "2" ] || fail "(1) unexpected worktree set ($(git -C "$P" worktree list))"
printf '%s\n' "$OUT" | grep -qi 'opened config PR' || fail "(1) output did not confirm the PR ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'watcher gates' || fail "(1) output did not flag the worktree left for the watcher ($OUT)"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (2) Re-run — value already applied locally; --shared must NOT short-circuit but refresh the PR.
# ══════════════════════════════════════════════════════════════════════════════
run "$P" config set --shared CLAIM_REQUIRED on
[ "$RC" -eq 0 ] || fail "(2) re-run --shared failed (rc=$RC): $OUT"
printf '%s\n' "$OUT" | grep -qi 'no change' && fail "(2) --shared wrongly short-circuited as a plain no-op ($OUT)"
printf '%s\n' "$OUT" | grep -qi 'refreshed the existing config PR' || fail "(2) re-run did not refresh the existing PR ($OUT)"
# HERD-74: re-run must not choke on the persisted worktree from run (1) — it re-adds it in place and
# leaves it again (still exactly two worktrees: main + the refreshed config worktree, no accumulation).
[ -d "$CWT" ] || fail "(2) config worktree missing after re-run ($(git -C "$P" worktree list))"
[ "$(git -C "$P" worktree list | wc -l | tr -d ' ')" = "2" ] || fail "(2) re-run accumulated worktrees ($(git -C "$P" worktree list))"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (3) machine-scoped key refused for --shared.
# ══════════════════════════════════════════════════════════════════════════════
run "$P" config set --shared MODEL_QUICK claude-x
[ "$RC" -ne 0 ] || fail "(3) --shared on a machine-scoped key was NOT refused"
printf '%s\n' "$OUT" | grep -qi 'machine-scoped' || fail "(3) wrong refusal message ($OUT)"
# nothing committed/pushed for it
git -C "$BARE" rev-parse --verify --quiet refs/heads/config/MODEL_QUICK >/dev/null \
  && fail "(3) a config/MODEL_QUICK branch was pushed despite the refusal"
grep -qE '^MODEL_QUICK="claude-baseline"' "$P/.herd/config" || fail "(3) baseline MODEL_QUICK mutated despite refusal"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (4) --local and --shared are mutually exclusive.
# ══════════════════════════════════════════════════════════════════════════════
run "$P" config set --local --shared CLAIM_REQUIRED off
[ "$RC" -ne 0 ] || fail "(4) --local --shared combo was accepted"
printf '%s\n' "$OUT" | grep -qi 'mutually exclusive' || fail "(4) wrong mutual-exclusion message ($OUT)"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (5) secrets refusal + key validation identical to a normal set (rejected before any PR work).
# ══════════════════════════════════════════════════════════════════════════════
P2="$T/p2"; _make_project "$P2"
run "$P2" config set --shared MY_SECRET_TOKEN hunter2
{ [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qi 'secret-shaped'; } || fail "(5) --shared did not refuse a secret-shaped key ($OUT)"
run "$P2" config set --shared DENY_PATHS /etc
{ [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qi 'refusing to set DENY_PATHS'; } || fail "(5) --shared did not refuse DENY_PATHS ($OUT)"
run "$P2" config set --shared BOGUS_SETTING x
{ [ "$RC" -ne 0 ] && printf '%s\n' "$OUT" | grep -qi 'unknown config key'; } || fail "(5) --shared did not reject an unknown key ($OUT)"
# none of the three reached git: no config/* branch exists on origin for p2's remote
[ -z "$(git -C "$BARE" for-each-ref --format='%(refname)' 'refs/heads/config/MY_SECRET_TOKEN' 'refs/heads/config/BOGUS_SETTING')" ] \
  || fail "(5) a refused key still pushed a branch"
okp

# ══════════════════════════════════════════════════════════════════════════════
# (6) degrade: no gh on PATH → local change applies, command warns, no die.
# ══════════════════════════════════════════════════════════════════════════════
P3="$T/p3"; _make_project "$P3"
NOGH="$T/nogh"; mkdir -p "$NOGH"
cp "$BIN/pgrep" "$NOGH/"; cp "$BIN/herdr" "$NOGH/"   # keep pgrep+herdr, DROP gh
OUT="$( cd "$P3" && PATH="$NOGH:/usr/bin:/bin" HERD_RELOAD_SKIP_LAUNCH=1 HERD_CAPABILITIES_FILE="$CAPS" bash "$HERD" config set --shared CLAIM_REQUIRED on 2>&1 )"; RC=$?
[ "$RC" -eq 0 ] || fail "(6) --shared without gh should still succeed locally (rc=$RC): $OUT"
grep -qE '^CLAIM_REQUIRED="on"' "$P3/.herd/config" || fail "(6) local change not applied in the degrade path"
printf '%s\n' "$OUT" | grep -qi 'gh CLI not found' || fail "(6) degrade path did not warn about missing gh ($OUT)"
okp

echo "ALL PASS ($pass tests)"
