#!/usr/bin/env bash
# test-init-github-detection.sh — hermetic tests for `herd init`'s GitHub detection pass
# (detect_github + its helpers in bin/herd, and the derived MERGE_POLICY/MERGE_METHOD defaults it
# writes into .herd/config). A FAKE `gh` on PATH returns scripted JSON — NO network, NO real gh, NO
# real GitHub API is ever contacted. Asserts:
#   (1) protected default branch (required review) ⇒ derived MERGE_POLICY=approve, NEVER auto;
#       allowed merge methods constrain MERGE_METHOD; findings (protection, checks, CODEOWNERS,
#       merge methods) are parsed correctly.
#   (2) unprotected default branch (404 on protection) ⇒ auto/merge; absence is a valid finding.
#   (3) 403/no-access on the API ⇒ graceful auto/merge (never an error).
#   (4) gh present but unauthenticated ⇒ detection skips with a note.
#   (5) no GitHub remote / non-GitHub remote ⇒ detection skips with a note.
#   (6) end-to-end `herd init`: the summary block is shown and the derived defaults land in config
#       (protected ⇒ approve/squash).
#   (7) end-to-end `herd init` with NO gh on PATH ⇒ init still succeeds, notes the skip, and writes
#       today's defaults (auto/merge) — detection never hard-fails init.
#
# No `set -e`: several checks assert non-zero-tolerant degradation; assert explicitly.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
HERD="$REPO/bin/herd"
export HERD

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

# strip ANSI colour/style escapes so greps match the plain text (init colourises the summary).
plain() { printf '%s' "$1" | sed $'s/\x1b\\[[0-9;]*m//g'; }

command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
command -v git     >/dev/null 2>&1 || fail "git required to run this test"
REAL_BASH="$(command -v bash)"
REAL_PY="$(command -v python3)"

# ── fake gh: scripted JSON keyed on $GH_FIXTURE; $GH_AUTHED toggles `gh auth status` ─────────────
STUB="$T/stub"; mkdir -p "$STUB"
cat > "$STUB/gh" <<'STUB_EOF'
#!/usr/bin/env bash
case "$1" in
  auth)
    if [ "${GH_AUTHED:-1}" = "1" ]; then exit 0; else echo "not logged in" >&2; exit 1; fi ;;
  api)
    p="$2"
    case "$GH_FIXTURE" in
      protected)
        case "$p" in
          repos/acme/widgets)
            printf '{"default_branch":"main","allow_merge_commit":false,"allow_squash_merge":true,"allow_rebase_merge":true}\n' ;;
          repos/acme/widgets/branches/main/protection)
            printf '{"required_pull_request_reviews":{"required_approving_review_count":2},"required_status_checks":{"contexts":["ci","lint"]}}\n' ;;
          *) echo '{"message":"Not Found"}' >&2; exit 1 ;;
        esac ;;
      unprotected)
        case "$p" in
          repos/acme/widgets)
            printf '{"default_branch":"main","allow_merge_commit":true,"allow_squash_merge":true,"allow_rebase_merge":true}\n' ;;
          repos/acme/widgets/branches/main/protection)
            echo '{"message":"Branch not protected"}' >&2; exit 1 ;;
          *) echo '{"message":"Not Found"}' >&2; exit 1 ;;
        esac ;;
      forbidden)
        echo '{"message":"Must have admin rights to Repository"}' >&2; exit 1 ;;
      *) echo '{"message":"Not Found"}' >&2; exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
STUB_EOF
chmod +x "$STUB/gh"

# ── a temp git repo with a github.com origin + a root CODEOWNERS ──────────────────────────────────
mkproj() { # <dir> <origin-url> ; creates repo on branch main with one commit
  local d="$1" origin="$2"
  rm -rf "$d"; mkdir -p "$d"
  git -C "$d" init -q
  git -C "$d" config user.email t@t.t; git -C "$d" config user.name t
  git -C "$d" commit -q --allow-empty -m init
  git -C "$d" branch -M main
  [ -n "$origin" ] && git -C "$d" remote add origin "$origin"
}

# run_detect <root> <ref> — source bin/herd (help = no-op dispatch) and call detect_github; env
# (GH_FIXTURE/GH_AUTHED/PATH) is inherited from the caller. Prints detect_github's key=value output.
run_detect() {
  "$REAL_BASH" -c '. "$HERD" help >/dev/null 2>&1; detect_github "$1" "$2"' _ "$1" "$2"
}
field() { printf '%s' "$1" | sed -n "s/^$2=//p"; }

# ── (1) protected default branch: required review ⇒ approve; merge methods constrain the method ──
proj="$T/p1"; mkproj "$proj" "git@github.com:acme/widgets.git"; : > "$proj/CODEOWNERS"
out="$(PATH="$STUB:$PATH" GH_FIXTURE=protected GH_AUTHED=1 run_detect "$proj" "origin/main")"
[ "$(field "$out" slug)"            = "acme/widgets" ] || fail "(1) slug ($out)"
[ "$(field "$out" branch)"          = "main" ]         || fail "(1) branch ($out)"
[ "$(field "$out" protected)"       = "1" ]            || fail "(1) protected ($out)"
[ "$(field "$out" reviews_required)" = "1" ]           || fail "(1) reviews_required ($out)"
[ "$(field "$out" reviews)"         = "2" ]            || fail "(1) reviews count ($out)"
[ "$(field "$out" checks)"          = "ci,lint" ]      || fail "(1) checks ($out)"
[ "$(field "$out" codeowners)"      = "1" ]            || fail "(1) codeowners ($out)"
[ "$(field "$out" merge_methods)"   = "squash,rebase" ] || fail "(1) merge_methods ($out)"
# SAFE direction: required review ⇒ approve (never auto). merge disabled ⇒ squash (first allowed).
[ "$(field "$out" policy)" = "approve" ] || fail "(1) required review must derive approve, not auto ($out)"
[ "$(field "$out" method)" = "squash" ]  || fail "(1) method should be constrained to squash ($out)"
ok

# ── (2) unprotected default branch (404 on protection) ⇒ auto/merge; absence is a valid finding ──
proj="$T/p2"; mkproj "$proj" "https://github.com/acme/widgets.git"
out="$(PATH="$STUB:$PATH" GH_FIXTURE=unprotected GH_AUTHED=1 run_detect "$proj" "origin/main")"
[ "$(field "$out" protected)"        = "0" ]     || fail "(2) should report unprotected ($out)"
[ "$(field "$out" reviews_required)" = "0" ]     || fail "(2) no required review ($out)"
[ "$(field "$out" policy)"           = "auto" ]  || fail "(2) unprotected should derive auto ($out)"
[ "$(field "$out" merge_methods)"    = "merge,squash,rebase" ] || fail "(2) merge_methods ($out)"
[ "$(field "$out" method)"           = "merge" ] || fail "(2) merge allowed ⇒ merge ($out)"
[ -z "$(field "$out" skip)" ]                    || fail "(2) unprotected must NOT skip ($out)"
ok

# ── (3) 403 / no-access on the API ⇒ graceful auto/merge (never an error) ─────────────────────────
proj="$T/p3"; mkproj "$proj" "git@github.com:acme/widgets.git"
out="$(PATH="$STUB:$PATH" GH_FIXTURE=forbidden GH_AUTHED=1 run_detect "$proj" "origin/main")"; RC=$?
[ "$RC" -eq 0 ]                            || fail "(3) 403 must not fail detection (rc=$RC): $out"
[ "$(field "$out" protected)" = "0" ]      || fail "(3) 403 protection treated as unprotected ($out)"
[ "$(field "$out" repo_ok)"   = "0" ]      || fail "(3) 403 repo metadata unavailable ($out)"
[ "$(field "$out" policy)"    = "auto" ]   || fail "(3) 403 should derive auto ($out)"
[ "$(field "$out" method)"    = "merge" ]  || fail "(3) 403 keeps default merge ($out)"
ok

# ── (4) gh present but UNAUTHENTICATED ⇒ skip with a note (no derived findings) ───────────────────
proj="$T/p4"; mkproj "$proj" "git@github.com:acme/widgets.git"
out="$(PATH="$STUB:$PATH" GH_FIXTURE=protected GH_AUTHED=0 run_detect "$proj" "origin/main")"
echo "$out" | grep -qi "^skip=.*authenticat" || fail "(4) unauthenticated gh should skip with a note ($out)"
[ -z "$(field "$out" slug)" ]                || fail "(4) skip should not emit findings ($out)"
ok

# ── (5) no GitHub remote / non-GitHub remote ⇒ skip with a note ──────────────────────────────────
proj="$T/p5a"; mkproj "$proj" ""   # no origin at all
out="$(PATH="$STUB:$PATH" GH_FIXTURE=protected GH_AUTHED=1 run_detect "$proj" "origin/main")"
echo "$out" | grep -qi "^skip=no GitHub remote" || fail "(5a) missing remote should skip ($out)"
proj="$T/p5b"; mkproj "$proj" "https://gitlab.com/acme/widgets.git"   # non-github host
out="$(PATH="$STUB:$PATH" GH_FIXTURE=protected GH_AUTHED=1 run_detect "$proj" "origin/main")"
echo "$out" | grep -qi "^skip=no GitHub remote" || fail "(5b) non-github remote should skip ($out)"
ok

# ── (6) end-to-end `herd init`: summary shown + derived defaults written to .herd/config ──────────
proj="$T/e2e"; mkproj "$proj" "git@github.com:acme/widgets.git"; : > "$proj/CODEOWNERS"
out="$(cd "$proj" && PATH="$STUB:$PATH" GH_FIXTURE=protected GH_AUTHED=1 \
        HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init 2>&1)"; RC=$?
[ "$RC" -eq 0 ] || fail "(6) init should succeed with detection (rc=$RC): $out"
pout="$(plain "$out")"
echo "$pout" | grep -qi "GitHub detection"                 || fail "(6) summary header missing: $out"
echo "$pout" | grep -qi "acme/widgets"                     || fail "(6) repo slug not shown: $out"
echo "$pout" | grep -qi "protected"                        || fail "(6) protection not shown: $out"
echo "$pout" | grep -qi "2 required review"                || fail "(6) required-review count not shown: $out"
echo "$pout" | grep -qi "required checks: ci,lint"         || fail "(6) required checks not shown: $out"
echo "$pout" | grep -qi "CODEOWNERS:.*present"             || fail "(6) CODEOWNERS not shown: $out"
echo "$pout" | grep -qi "MERGE_POLICY=approve"             || fail "(6) derived approve not shown: $out"
echo "$pout" | grep -qi "MERGE_METHOD=squash"              || fail "(6) derived squash not shown: $out"
grep -qE '^MERGE_POLICY="approve"$' "$proj/.herd/config"  || fail "(6) config MERGE_POLICY not approve: $(cat "$proj/.herd/config")"
grep -qE '^MERGE_METHOD="squash"$'  "$proj/.herd/config"  || fail "(6) config MERGE_METHOD not squash"
ok

# ── (7) end-to-end with NO gh on PATH ⇒ init succeeds, notes the skip, writes auto/merge defaults ─
# SAFE = the system tools bin/herd needs but NOT gh (gh lives in a package-manager prefix outside).
SAFE="/usr/bin:/bin:/usr/sbin:/sbin"
case ":$SAFE:" in *":$(dirname "$REAL_PY"):"*) ;; *) SAFE="$(dirname "$REAL_PY"):$SAFE" ;; esac
proj="$T/e2e-nogh"; mkproj "$proj" "git@github.com:acme/widgets.git"
if PATH="$SAFE" command -v gh >/dev/null 2>&1; then
  echo "SKIP (7): a real gh is present on the SAFE PATH; cannot assert the no-gh branch hermetically" >&2
else
  out="$(cd "$proj" && PATH="$SAFE" HERD_NONINTERACTIVE=1 HERD_SKIP_DOCTOR=1 bash "$HERD" init 2>&1)"; RC=$?
  [ "$RC" -eq 0 ] || fail "(7) init must not hard-fail without gh (rc=$RC): $out"
  pout="$(plain "$out")"
  echo "$pout" | grep -qi "skipped"                         || fail "(7) skip note missing: $out"
  echo "$pout" | grep -qi "gh CLI not installed"            || fail "(7) no-gh reason missing: $out"
  grep -qE '^MERGE_POLICY="auto"$'  "$proj/.herd/config"    || fail "(7) config should default MERGE_POLICY=auto"
  grep -qE '^MERGE_METHOD="merge"$' "$proj/.herd/config"    || fail "(7) config should default MERGE_METHOD=merge"
fi
ok

echo "ALL PASS ($pass checks)"
