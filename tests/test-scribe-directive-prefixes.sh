#!/usr/bin/env bash
# test-scribe-directive-prefixes.sh — HERD-787: documented Add directives get a separate concise
# tracker title while their complete claimed-file request remains the description. Exact shipped
# prefixes are a default correctness repair; the default-off expansion leaves every other request on
# the legacy two-argument backend contract exactly.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
STEP="$HERE/../scripts/herd/scribe-step.sh"
SCRIBE="$HERE/../scripts/herd/scribe.sh"

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

# Preserve every argument as a NUL-delimited record: this distinguishes real newlines, literal \n,
# and the legacy two-argument backend call without a line-oriented encoding ambiguity.
cat > "$FAKEDIR/fake.sh" <<EOF
#!/usr/bin/env bash
_backend_add_item() { printf '%s\0' "\$#" "\$@" > "$CAPTURE"; _BACKEND_RESULT="DONE"; }
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
WORKSPACE_NAME="directive-prefixes"
HERD_REMOTE="origin"
HERD_BRANCH_NAME="main"
BACKLOG_FILE="BACKLOG.md"
SCRIBE_BACKEND="fake"
SCRIBE_DIRECTIVE_PREFIXES="off"
EOF

step() {
  set +e
  OUT="$(cd "$REPO" && HERD_CONFIG_FILE="$CFG" SCRIBE_BACKEND_DIR="$FAKEDIR" SCRIBE_POLL=0 bash "$STEP" "$@" 2>&1)"
  RC=$?
  set -e
}

assert_capture() {
  python3 - "$CAPTURE" "$@" <<'PY'
import pathlib, sys
got = pathlib.Path(sys.argv[1]).read_bytes().split(b"\0")[:-1]
want = [x.encode() for x in sys.argv[2:]]
assert got == want, (got, want)
PY
}

claim() {
  CLAIM="$Q/$1.req.mine"
  printf '%s\n' "$2" > "$CLAIM"
}

# 1. LIVE DEFAULT PATH: invoke the same scribe.sh command the rendered coordinator documents, let it
# enqueue a request file, claim it through `next`, then dispatch ONLY that claimed path. With the
# expansion lever still OFF, the exact shipped prefix is corrected to a concise title and the entire
# request remains the description. This is the post-#849/HERD-786 regression, end to end.
REQ='Add a planned item: Reap merged Codex builders — close their tabs after merge.'
SCRIBE_OUT="$(cd "$REPO" && HERD_CONFIG_FILE="$CFG" bash "$SCRIBE" "$REQ" 2>&1)"
case "$SCRIBE_OUT" in *"📥 queued:"*) ;; *) fail "scribe.sh did not enqueue the documented request ($SCRIBE_OUT)" ;; esac
step next
[ "$RC" -eq 0 ] || fail "next after documented enqueue exited $RC ($OUT)"
P="$(sed -n 's/^CLAIMED //p; /^CLAIMED /q' <<< "$OUT")"
[ -n "$P" ] || fail "next did not return the path-only claim ($OUT)"
step add-item "$P"
[ "$RC" -eq 0 ] || fail "documented default add exited $RC ($OUT)"
assert_capture 3 "$P" "$REQ" 'Reap merged Codex builders' || fail "documented default title/body split wrong"
ok

# 2. The compatibility boundary: with expansion OFF, a noncanonical lowercase/article-less variant
# remains byte-identical and reaches the backend through exactly the historical two arguments.
REQ='add planned item: Normalize a custom prompt — preserve its body.'
claim 200 "$REQ"; P="$CLAIM"
step add-item "$P"
[ "$RC" -eq 0 ] || fail "off noncanonical path exited $RC ($OUT)"
assert_capture 2 "$P" "$REQ" || fail "off noncanonical path changed backend argv"
ok

# Arm only the optional grammar expansion in the hermetic config.
sed -i.bak 's/SCRIBE_DIRECTIVE_PREFIXES="off"/SCRIBE_DIRECTIVE_PREFIXES="on"/' "$CFG"
rm -f "$CFG.bak"

# 3. ON widens the grammar to that noncanonical variant while still keeping its complete body.
claim 300 "$REQ"; P="$CLAIM"
step add-item "$P"
[ "$RC" -eq 0 ] || fail "widened directive exited $RC ($OUT)"
assert_capture 3 "$P" "$REQ" 'Normalize a custom prompt' || fail "widened title/body split wrong"
ok

# 4. The title may follow a canonical directive on the next REAL line; the full body is unchanged.
REQ=$'Add a planned item:\nNormalize scribe directive prefixes\n\nKeep the complete request in the tracker description.'
claim 400 "$REQ"; P="$CLAIM"
step add-item "$P"
[ "$RC" -eq 0 ] || fail "real-newline directive exited $RC ($OUT)"
assert_capture 3 "$P" "$REQ" 'Normalize scribe directive prefixes' || fail "real-newline title/body split wrong"
ok

# 5. The coordinator's checked-in emoji spelling is canonical too. A literal backslash-n can bound
# the title but is NEVER decoded: the description still contains the original two characters.
REQ='Add a 🔜 item: Keep literal transport\nBody stays literal'
claim 500 "$REQ"; P="$CLAIM"
step add-item "$P"
[ "$RC" -eq 0 ] || fail "literal-backslash directive exited $RC ($OUT)"
assert_capture 3 "$P" "$REQ" 'Keep literal transport' || fail "literal-backslash bytes/title wrong"
ok

# 6. Opting in does not perturb title-first or arbitrary prose: only the anchored directive grammar
# receives the optional title argument.
REQ=$'Already concise title\n\nFull title-first request body.'
claim 600 "$REQ"; P="$CLAIM"
step add-item "$P"
[ "$RC" -eq 0 ] || fail "title-first compatibility exited $RC ($OUT)"
assert_capture 2 "$P" "$REQ" || fail "unmatched opt-in path changed backend argv"
ok

# 7. The existing arbitrary-path rail remains ahead of normalization: no backend call, no supplied
# path or secret bytes in output, and the source remains untouched.
SECRET="$T/secret"; TOKEN='lin_secret_must_not_leak'; printf '%s\n' "$TOKEN" > "$SECRET"
: > "$CAPTURE"
step add-item "$SECRET"
[ "$RC" -eq 0 ] || fail "arbitrary path did not fail soft (rc=$RC)"
[ ! -s "$CAPTURE" ] || fail "arbitrary path reached backend"
case "$OUT" in *"$TOKEN"*|*"$SECRET"*) fail "arbitrary path leaked secret/path ($OUT)" ;; esac
[ -f "$SECRET" ] || fail "arbitrary source was removed"
ok

echo "ALL PASS ($PASS checks) — directive title normalization / full-body transport / legacy-off / path safety"
