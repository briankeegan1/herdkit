#!/usr/bin/env bash
# test-install.sh — hermetic tests for the one-command installer (install.sh) in its MANAGED mode:
# clone/ff-update a standard HERDKIT_HOME, wire `herd` onto PATH, and stay idempotent + dirty-safe.
# (test-doctor.sh §9 already covers the LOCAL from-checkout advisory path; this file covers the
# curl | bash bootstrap path, driven hermetically via HERDKIT_HOME + HERDKIT_REPO_URL knobs.)
#
# Everything is pointed at temp dirs — no network, no real HOME, no real ~/.herdkit is touched:
#   • HERDKIT_REPO_URL → a local fake "upstream" git repo (git clones from a path just fine), so
#     the clone/pull are offline and fast. The upstream ships a stub bin/herd + a stub preflight
#     whose herd_doctor prints a marker, so we can assert the doctor ran without real deps.
#   • HERDKIT_HOME → a temp engine home (exercises the managed clone-or-update path regardless of
#     the fact that this test itself runs from inside the real checkout).
#   • A writable temp bin dir is placed FIRST on PATH so the symlink lands there deterministically.
#
# Asserts: (1) fresh clone lays out .git + bin/herd + a verified symlink, runs the doctor, and
# prints the two-step quickstart; (2) a re-run fast-forwards to a new upstream commit WITHOUT
# clobbering the symlink (idempotent); (3) a dirty engine checkout is politely REFUSED, and
# --force overrides it; (4) with no writable PATH dir, the exact `export PATH=".../bin:$PATH"`
# hint is printed instead of failing.
#
# Run:  bash tests/test-install.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
INSTALL="$REPO/install.sh"

T="$(mktemp -d)"; trap 'chmod -R u+w "$T" 2>/dev/null; rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

command -v git >/dev/null 2>&1 || fail "git required to run this test"

# ── Fake upstream repo (the clone source) ───────────────────────────────────────────────────────
UPSTREAM="$T/upstream"
mkdir -p "$UPSTREAM/bin" "$UPSTREAM/scripts/herd"
# Stub `herd`: enough for the installer's checks (executable, resolvable). Never actually invoked
# by the managed flow beyond the executability probe.
cat > "$UPSTREAM/bin/herd" <<'EOF'
#!/usr/bin/env bash
echo "herd stub $*"
EOF
chmod +x "$UPSTREAM/bin/herd"
# Stub preflight: install.sh sources it and calls herd_doctor. Print a marker so we can prove the
# doctor step ran; return 0 (a clean advisory).
cat > "$UPSTREAM/scripts/herd/herd-preflight.sh" <<'EOF'
#!/usr/bin/env bash
herd_doctor() { echo "DOCTOR-RAN: checking dependencies"; return 0; }
EOF
git -C "$UPSTREAM" init -q
git -C "$UPSTREAM" config user.email t@t.t
git -C "$UPSTREAM" config user.name t
git -C "$UPSTREAM" add -A
git -C "$UPSTREAM" commit -q -m "engine v1"

# ── A writable bin dir, first on PATH, so the auto-symlink lands there deterministically ─────────
BINDIR="$T/bin"; mkdir -p "$BINDIR"
# Keep the real toolchain reachable (git etc.) but put our writable dir first.
RUN_PATH="$BINDIR:$PATH"

HH="$T/herdkit-home"   # managed engine home (does not exist yet → first run clones)

run_install() {  # run_install [extra args...] ; sets: OUT, RC
  OUT="$(HERDKIT_HOME="$HH" HERDKIT_REPO_URL="$UPSTREAM" PATH="$RUN_PATH" \
         bash "$INSTALL" "$@" 2>&1)"; RC=$?
}

# ── (1) Fresh clone: layout + verified symlink + doctor + quickstart ─────────────────────────────
run_install
[ "$RC" -eq 0 ]                || fail "(1) fresh install should exit 0 (got $RC): $OUT"
[ -e "$HH/.git" ]             || fail "(1) install did not clone a git checkout to $HH: $OUT"
[ -x "$HH/bin/herd" ]        || fail "(1) cloned checkout missing bin/herd: $OUT"
[ -L "$BINDIR/herd" ]        || fail "(1) install did not symlink herd into the writable PATH dir: $OUT"
link_target="$(readlink "$BINDIR/herd")"
[ "$link_target" = "$HH/bin/herd" ] || fail "(1) symlink points at '$link_target', expected '$HH/bin/herd'"
grep -q "DOCTOR-RAN" <<<"$OUT"       || fail "(1) install did not run the dependency doctor: $OUT"
grep -q "herd init"  <<<"$OUT"       || fail "(1) install did not print the two-step quickstart (herd init): $OUT"
grep -q "cd your-project" <<<"$OUT"  || fail "(1) install did not print the 'cd your-project' step: $OUT"
ok

# ── (2) Idempotent re-run: fast-forwards to a new upstream commit, keeps the symlink ─────────────
printf 'v2\n' > "$UPSTREAM/VERSION"
git -C "$UPSTREAM" add -A
git -C "$UPSTREAM" commit -q -m "engine v2"
UP_HEAD="$(git -C "$UPSTREAM" rev-parse HEAD)"

run_install
[ "$RC" -eq 0 ]                       || fail "(2) idempotent re-run should exit 0 (got $RC): $OUT"
[ -L "$BINDIR/herd" ]                 || fail "(2) re-run clobbered the symlink: $OUT"
HH_HEAD="$(git -C "$HH" rev-parse HEAD)"
[ "$HH_HEAD" = "$UP_HEAD" ]           || fail "(2) re-run did not fast-forward to upstream HEAD ($HH_HEAD != $UP_HEAD): $OUT"
[ -f "$HH/VERSION" ]                  || fail "(2) re-run did not pull the new file into the checkout: $OUT"
ok

# ── (3) Dirty engine checkout: politely refused; --force overrides ───────────────────────────────
printf 'local edit\n' >> "$HH/bin/herd"   # uncommitted change in the engine checkout
run_install
[ "$RC" -ne 0 ]                       || fail "(3) install must REFUSE to update a dirty checkout (got 0): $OUT"
grep -qi "refus" <<<"$OUT"            || fail "(3) refusal message not shown for a dirty checkout: $OUT"
# The dirty file must be untouched (never clobbered).
grep -q "local edit" "$HH/bin/herd"  || fail "(3) install clobbered local changes in the dirty checkout"

run_install --force
[ "$RC" -eq 0 ]                       || fail "(3) --force should proceed past the dirty guard (got $RC): $OUT"
ok
# Reset the checkout clean for the next case.
git -C "$HH" checkout -- . 2>/dev/null || true

# ── (4) No writable PATH dir → prints the exact export-PATH hint instead of failing ──────────────
# A read-only bin dir holding just the tools the installer needs, and nothing else on PATH.
ROBIN="$T/robin"; mkdir -p "$ROBIN"
for t in git bash sh env readlink dirname basename mkdir ln cat rm chmod grep sed uname; do
  p="$(command -v "$t" 2>/dev/null || true)"; [ -n "$p" ] && ln -sf "$p" "$ROBIN/$t"
done
chmod 555 "$ROBIN"
OUT="$(HERDKIT_HOME="$HH" HERDKIT_REPO_URL="$UPSTREAM" PATH="$ROBIN" \
       bash "$INSTALL" 2>&1)"; RC=$?
[ "$RC" -eq 0 ]                                   || fail "(4) install should still succeed with no writable PATH dir (got $RC): $OUT"
grep -qF "export PATH=\"$HH/bin:\$PATH\"" <<<"$OUT" || fail "(4) exact PATH hint not printed: $OUT"
ok

echo "ALL PASS ($pass checks)"
