#!/usr/bin/env bash
# test-scribe-multiline-transport.sh — HERD-783 hermetic proof that scribe add-item transports a
# multiline tracker request through its claimed file, never through runtime-specific argv quoting.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
PASS=0; ok(){ PASS=$((PASS+1)); }

BIN="$T/bin"; mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/herdr"; chmod +x "$BIN/herdr"
export PATH="$BIN:$PATH"

REPO="$T/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email t@t.t
git -C "$REPO" config user.name t
git -C "$REPO" commit -q --allow-empty -m init
TREES="$T/trees"; Q="$TREES/backlog-queue"; mkdir -p "$Q"
CAPTURE="$T/capture"
FAKEDIR="$T/backends"; mkdir -p "$FAKEDIR"

# Record arg2 without a line-oriented encoding so newlines and literal backslashes are distinguishable.
cat > "$FAKEDIR/fake.sh" <<EOF
#!/usr/bin/env bash
_backend_add_item() { printf 'argc=%s\narg1=%s\n' "\$#" "\$1" > "$CAPTURE.meta"; printf '%s' "\$2" > "$CAPTURE"; _BACKEND_RESULT="DONE"; }
_backend_mark_shipped() { :; }
_backend_list_open() { :; }
_backend_item_state() { ITEM_STATE="open"; }
EOF

CFG="$T/config"
cat > "$CFG" <<EOF
HERD_VERSION=1
PROJECT_ROOT="$REPO"
WORKTREES_DIR="$TREES"
DEFAULT_BRANCH="origin/main"
WORKSPACE_NAME="multiline"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="fake"
EOF

step() {
  set +e
  OUT="$(cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$FAKEDIR" SCRIBE_POLL=0 bash "$STEP" "$@" 2>&1)"
  RC=$?
  set -e
}

# 1. The runtime passes only verb + claim path. Actual newlines reach the backend byte-for-byte
#    (apart from the queue file's conventional final record newline, stripped by shell assignment).
REQ=$'Short tracker title\n\nBody paragraph.\n- first proof\n- second proof'
p="$Q/100.req.mine"; printf '%s\n' "$REQ" > "$p"
step add-item "$p"
[ "$RC" -eq 0 ] || fail "file transport exited $RC ($OUT)"
[ "$(cat "$CAPTURE")" = "$REQ" ] || fail "file transport did not preserve actual newlines"
[ ! -e "$p" ] || fail "successful claim was not cleaned up"
ok

# 2. The compatibility/default argv path stays byte-identical. In particular, backslash-n remains
#    two literal characters; the transport never guesses that the caller meant a newline.
LITERAL='Short title\nBody is intentionally literal here'
p="$Q/200.req.mine"; printf 'unused request\n' > "$p"
step add-item "$p" "$LITERAL"
[ "$RC" -eq 0 ] || fail "legacy argv transport exited $RC ($OUT)"
[ "$(cat "$CAPTURE")" = "$LITERAL" ] || fail "legacy argv bytes changed or backslash-n was decoded"
grep -qx 'argc=2' "$CAPTURE.meta" || fail "legacy backend argv shape changed ($(cat "$CAPTURE.meta"))"
grep -qx "arg1=$p" "$CAPTURE.meta" || fail "legacy backend claim argv changed ($(cat "$CAPTURE.meta"))"
want="DONE $(git -C "$REPO" rev-parse --short HEAD)"
[ "$OUT" = "$want" ] || fail "legacy success output changed (want '$want', got '$OUT')"
ok

# 3. A malformed path cannot turn the transport into an arbitrary file reader. Fail soft, call no
#    backend, disclose neither the secret bytes nor the supplied path, and leave the source intact.
SECRET="$T/lin-secret"; TOKEN='lin_api_secret_must_not_leak'; printf '%s\n' "$TOKEN" > "$SECRET"
: > "$CAPTURE"
step add-item "$SECRET"
[ "$RC" -eq 0 ] || fail "malformed transport must fail soft (rc=$RC)"
[ ! -s "$CAPTURE" ] || fail "malformed transport reached the backend"
case "$OUT" in *"$TOKEN"*|*"$SECRET"*) fail "malformed transport leaked secret/path ($OUT)" ;; esac
[ -f "$SECRET" ] || fail "malformed transport source was removed"
case "$OUT" in *"item not filed"*) ;; *) fail "malformed transport was not diagnosed generically ($OUT)" ;; esac
ok

# 4. The no-plan marker is expressed as a scalar flag, not multiline argv, and is appended after the
#    original body with real newlines.
REQ=$'Flagged title\nOriginal body'
p="$Q/400.req.mine"; printf '%s\n' "$REQ" > "$p"
step add-item "$p" --no-verification-plan
[ "$RC" -eq 0 ] || fail "no-plan transport exited $RC ($OUT)"
[ "$(cat "$CAPTURE")" = "$REQ"$'\n\n''⚠️ no verification plan' ] || fail "no-plan marker/body bytes wrong"
ok

echo "ALL PASS ($PASS checks) — multiline claim transport / literal compatibility / leak-safe malformed input"
