#!/usr/bin/env bash
# test-agent-update.sh — hermetic tests for the AGENT_UPDATE mechanism (HERD-149,
# scripts/herd/agent-update.sh): keep the AGENT RUNTIME (claude — or, via the driver seam, codex/grok)
# up to date SAFELY. Covers the four things the feature promises:
#   OFF   — AGENT_UPDATE unset/off is a HARD no-op: no installer probe, no update exec, no xattr call
#           (byte-identical to before the feature existed).
#   DETECT+RUN — installer detection (brew cask/formula / npm global / native / missing) picks the
#           right update command; --dry-run composes it without executing; a real run invokes it.
#   QUARANTINE — the macOS footgun (issue #137): after an update on darwin the resolved binary is
#           xattr-de-quarantined; a clean binary is left alone; off darwin the check is skipped.
#   DRIVER-AWARE — the runtime binary + installer package come from the ACTIVE driver's DRIVER_AGENT_*
#           bindings, so a codex driver updates codex, not claude.
#
# Everything is exercised behind a FAKE PATH of tool stubs + fake driver files, so no real
# brew/npm/xattr/claude state leaks in and nothing on the host is updated. Mirrors the stub style of
# test-doctor-claude-quarantine.sh. Run:  bash tests/test-agent-update.sh
# No `set -e`: assert exit codes explicitly (the mechanism is fail-soft, so it returns 0 a lot).
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
DRIVER_SH="$REPO/scripts/herd/driver.sh"
AU_SH="$REPO/scripts/herd/agent-update.sh"
REAL_DRIVERS="$REPO/templates/drivers"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

[ -f "$AU_SH" ]     || fail "mechanism not found at $AU_SH"
[ -f "$DRIVER_SH" ] || fail "driver seam not found at $DRIVER_SH"

# real_of <tool> — absolute path to a genuine system tool (the mechanism shells out to these under the
# restricted PATH, so they must be reachable there).
real_of() { command -v "$1" 2>/dev/null || fail "this test needs a real '$1' on PATH"; }

# BASE: the minimal genuine externals agent-update.sh + driver.sh need under the restricted PATH —
# uname (platform), readlink/dirname (symlink resolution), grep/tail (driver value read + xattr match),
# tr (lowercasing the platform), cat, and bash (the stub shebangs + the -c runner). NO brew/npm/xattr/
# claude/codex: a tool is "present" only when a scenario stubs it.
BASE="$T/base"; mkdir -p "$BASE"
for t in uname bash readlink dirname grep tail tr cat; do ln -sf "$(real_of "$t")" "$BASE/$t"; done

mkbin() { local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
# present_bin <dir> <name...> — a trivially-present binary (its own real file, so command -v finds it
# and _agent_update_realpath resolves to it → a "native"-style location unless symlinked elsewhere).
present_bin() { local d="$1"; shift; local n; for n in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done; }
# stub_npm <dir> <prefix> <record> — an npm whose `prefix -g` echoes <prefix> and whose `install …`
# appends its argv to <record> (so a real run's command is observable without touching a real npm).
stub_npm() {
  printf '%s\n' '#!/usr/bin/env bash' \
    "case \"\$1 \$2\" in \"prefix -g\") echo \"$2\"; exit 0;; esac" \
    "case \"\$1\" in install) echo \"npm \$*\" >> \"$3\"; exit 0;; esac" \
    'exit 0' > "$1/npm"; chmod +x "$1/npm"
}
# stub_brew <dir> <prefix> <record> — a brew whose `--prefix` echoes <prefix> and whose `upgrade …`
# records its argv to <record>.
stub_brew() {
  printf '%s\n' '#!/usr/bin/env bash' \
    "case \"\$1\" in --prefix) echo \"$2\"; exit 0;; upgrade) echo \"brew \$*\" >> \"$3\"; exit 0;; esac" \
    'exit 0' > "$1/brew"; chmod +x "$1/brew"
}
# stub_xattr <dir> <mode:quarantined|clean> <record> — models `xattr`: a bare `xattr <path>` lists the
# attribute names (quarantined → includes com.apple.quarantine), and `xattr -d <attr> <path>` records
# the removal to <record>.
stub_xattr() {
  local d="$1" mode="$2" rec="$3"
  { printf '%s\n' '#!/usr/bin/env bash' \
      "if [ \"\$1\" = \"-d\" ]; then echo \"xattr \$*\" >> \"$rec\"; exit 0; fi"
    if [ "$mode" = quarantined ]; then
      printf '%s\n' 'printf "com.apple.provenance\ncom.apple.quarantine\n"; exit 0'
    else
      printf '%s\n' 'exit 0'
    fi
  } > "$d/xattr"; chmod +x "$d/xattr"
}

# au <bindir> <env-kv...> -- <run-args...> — source driver.sh + agent-update.sh under PATH=<bindir>:BASE
# with the given env, run agent_update_run <run-args>, echo combined output, RETURN its exit code.
# Sets the global OUT + RC. Env pairs are plain KEY=VAL tokens before the literal '--'.
au() {
  local d="$1"; shift
  local -a envs=()
  while [ "${1:-}" != "--" ] && [ "$#" -gt 0 ]; do envs+=("$1"); shift; done
  [ "${1:-}" = "--" ] && shift
  OUT="$(env "${envs[@]}" PATH="$d:$BASE" "$BASE/bash" -c \
    '. "$1"; . "$2"; shift 2; agent_update_run "$@"' _ "$DRIVER_SH" "$AU_SH" "$@" 2>&1)"; RC=$?
}
# installer_of <bindir> <env-kv...> — echo agent_update_installer's verdict for the default binary.
installer_of() {
  local d="$1"; shift
  env "$@" PATH="$d:$BASE" "$BASE/bash" -c \
    '. "$1"; . "$2"; agent_update_installer "$(agent_update_binary)"' _ "$DRIVER_SH" "$AU_SH" 2>/dev/null
}

DRV="HERD_DRIVER=herdr-claude HERD_DRIVERS_DIR=$REAL_DRIVERS"   # the default (claude) driver

# ── (1) OFF (default) → a HARD no-op: no installer probe, no update, no xattr; byte-identical ──────
# Stubs that MUST NOT run (they'd write a marker); assert the marker never appears and the output
# names the off state. Also assert OFF is inert regardless of the platform.
REC="$T/rec1"; : > "$REC"
b="$(mkbin s1)"; stub_brew "$b" "/opt/homebrew" "$REC"; stub_npm "$b" "/usr/local" "$REC"; present_bin "$b" claude
au "$b" $DRV AGENT_UPDATE=off HERD_AGENT_UPDATE_OS=darwin --
[ "$RC" -eq 0 ]                          || fail "(1) off must exit 0 (got $RC): $OUT"
grep -qi "AGENT_UPDATE is off" <<<"$OUT"  || fail "(1) off did not announce the no-op: $OUT"
grep -qi "installer=" <<<"$OUT"           && fail "(1) off must NOT probe the installer: $OUT"
[ -s "$REC" ]                             && fail "(1) off ran an installer command (marker written): $(cat "$REC")"
# unset (never configured) is also off.
au "$b" $DRV HERD_AGENT_UPDATE_OS=darwin --
grep -qi "AGENT_UPDATE is off" <<<"$OUT"  || fail "(1) unset AGENT_UPDATE should be treated as off: $OUT"
ok

# ── (2) installer DETECTION — brew cask / npm global / native / missing ────────────────────────────
# brew: claude on PATH is a shim symlink into a fake Caskroom (the definitive brew marker + the
# quarantine-footgun case). _agent_update_realpath must follow the shim to the Caskroom target.
CASK="$T/Caskroom/claude-code/2.1.201/bin"; mkdir -p "$CASK"; present_bin "$CASK" claude
b="$(mkbin s2brew)"; ln -sf "$CASK/claude" "$b/claude"
[ "$(installer_of "$b" $DRV)" = brew ] || fail "(2) Caskroom-resolved binary not detected as brew"
# npm: claude resolves UNDER the npm global prefix.
NPMPFX="$T/npmglobal"; mkdir -p "$NPMPFX/bin"; present_bin "$NPMPFX/bin" claude
b="$(mkbin s2npm)"; stub_npm "$b" "$NPMPFX" "$T/rec_npm"; ln -sf "$NPMPFX/bin/claude" "$b/claude"
[ "$(installer_of "$b" $DRV)" = npm ] || fail "(2) npm-prefix-resolved binary not detected as npm"
# native: a plain binary in a dir that is neither Caskroom nor the npm/brew prefix.
b="$(mkbin s2native)"; present_bin "$b" claude; stub_npm "$b" "$T/someotherprefix" "$T/rec_n2"
[ "$(installer_of "$b" $DRV)" = native ] || fail "(2) plain binary not detected as native"
# missing: nothing named claude on PATH.
b="$(mkbin s2missing)"
[ "$(installer_of "$b" $DRV)" = missing ] || fail "(2) absent runtime not detected as missing"
ok

# ── (3) DRY-RUN composes the right update command per installer WITHOUT executing it ───────────────
# brew (Caskroom) → `brew upgrade <brew-pkg>`; record must stay empty (nothing executed).
REC="$T/rec3b"; : > "$REC"
b="$(mkbin s3brew)"; stub_brew "$b" "/opt/homebrew" "$REC"; ln -sf "$CASK/claude" "$b/claude"
au "$b" $DRV AGENT_UPDATE=on HERD_AGENT_UPDATE_OS=darwin -- --dry-run
[ "$RC" -eq 0 ]                                 || fail "(3) dry-run brew exit (got $RC): $OUT"
grep -qi "installer=brew" <<<"$OUT"             || fail "(3) brew not detected in run: $OUT"
grep -qF "would run: brew upgrade claude-code" <<<"$OUT" || fail "(3) brew update command not composed: $OUT"
[ -s "$REC" ]                                   && fail "(3) dry-run EXECUTED brew: $(cat "$REC")"
# npm → `npm install -g <pkg>@latest`.
b="$(mkbin s3npm)"; stub_npm "$b" "$NPMPFX" "$T/rec3n"; ln -sf "$NPMPFX/bin/claude" "$b/claude"
au "$b" $DRV AGENT_UPDATE=on HERD_AGENT_UPDATE_OS=linux -- --dry-run
grep -qF "would run: npm install -g @anthropic-ai/claude-code@latest" <<<"$OUT" || fail "(3) npm update command not composed: $OUT"
# native → the driver's DRIVER_AGENT_NATIVE_UPDATE (claude update).
b="$(mkbin s3native)"; present_bin "$b" claude
au "$b" $DRV AGENT_UPDATE=on HERD_AGENT_UPDATE_OS=linux -- --dry-run
grep -qF "would run: claude update" <<<"$OUT"   || fail "(3) native update command not composed: $OUT"
ok

# ── (4) macOS QUARANTINE footgun — de-quarantine after a real update; clean binary untouched ───────
# darwin + quarantined: a REAL run of the brew path, then xattr -d on the RESOLVED Caskroom binary.
REC="$T/rec4d"; : > "$REC"; XREC="$T/xrec4"; : > "$XREC"
b="$(mkbin s4q)"; stub_brew "$b" "/opt/homebrew" "$REC"; stub_xattr "$b" quarantined "$XREC"; ln -sf "$CASK/claude" "$b/claude"
au "$b" $DRV AGENT_UPDATE=on HERD_AGENT_UPDATE_OS=darwin --
[ "$RC" -eq 0 ]                          || fail "(4) update exit (got $RC): $OUT"
grep -qF "brew upgrade claude-code" "$REC" || fail "(4) brew upgrade was not actually run: $(cat "$REC")"
grep -qi "de-quarantined" <<<"$OUT"       || fail "(4) quarantined binary not de-quarantined: $OUT"
grep -qF "com.apple.quarantine $CASK/claude" "$XREC" || fail "(4) xattr -d did not target the resolved Caskroom binary: $(cat "$XREC")"
# darwin + CLEAN binary: no removal attempted, no false alarm.
XREC="$T/xrec4c"; : > "$XREC"
b="$(mkbin s4c)"; stub_brew "$b" "/opt/homebrew" "$T/rec4c"; stub_xattr "$b" clean "$XREC"; ln -sf "$CASK/claude" "$b/claude"
au "$b" $DRV AGENT_UPDATE=on HERD_AGENT_UPDATE_OS=darwin --
grep -qi "not quarantined" <<<"$OUT"      || fail "(4) clean binary not reported as clean: $OUT"
[ -s "$XREC" ]                            && fail "(4) xattr -d run on a CLEAN binary: $(cat "$XREC")"
# non-darwin: the quarantine check is SKIPPED entirely (even with a quarantining xattr stub present).
XREC="$T/xrec4l"; : > "$XREC"
b="$(mkbin s4l)"; stub_brew "$b" "/opt/homebrew" "$T/rec4l"; stub_xattr "$b" quarantined "$XREC"; ln -sf "$CASK/claude" "$b/claude"
au "$b" $DRV AGENT_UPDATE=on HERD_AGENT_UPDATE_OS=linux --
grep -qi "quarantine" <<<"$OUT"           && fail "(4) quarantine check must not run off darwin: $OUT"
[ -s "$XREC" ]                            && fail "(4) xattr touched off darwin: $(cat "$XREC")"
ok

# ── (5) DRIVER-AWARE — a codex driver updates codex, not claude ────────────────────────────────────
# A fake templates/drivers/ with a codex.driver binding the runtime to codex + its own packages.
DD="$T/drivers"; mkdir -p "$DD"
cp "$REAL_DRIVERS/herdr-claude.driver" "$DD/herdr-claude.driver"
cat > "$DD/codex.driver" <<'EOF'
DRIVER_AGENT_BINARY='codex'
DRIVER_AGENT_NPM_PKG='@openai/codex'
DRIVER_AGENT_BREW_PKG='codex-cli'
DRIVER_AGENT_NATIVE_UPDATE='codex upgrade'
EOF
# codex resolves under the npm prefix → npm install -g @openai/codex@latest, runtime=codex.
NPX="$T/codexnpm"; mkdir -p "$NPX/bin"; present_bin "$NPX/bin" codex
b="$(mkbin s5)"; stub_npm "$b" "$NPX" "$T/rec5"; ln -sf "$NPX/bin/codex" "$b/codex"
au "$b" HERD_DRIVER=codex HERD_DRIVERS_DIR="$DD" AGENT_UPDATE=on HERD_AGENT_UPDATE_OS=linux -- --dry-run
grep -qi "runtime=codex" <<<"$OUT"                                  || fail "(5) driver-aware binary not resolved to codex: $OUT"
grep -qi "claude" <<<"$OUT"                                         && fail "(5) codex run must not mention claude: $OUT"
grep -qF "would run: npm install -g @openai/codex@latest" <<<"$OUT" || fail "(5) codex update did not use the codex npm package: $OUT"
ok

# ── (6) herd_driver_agent_value default fallback — a driver missing the key falls back cleanly ─────
# Real herdr-claude.driver → 'claude'; a driver with NO DRIVER_AGENT_BINARY → the supplied default.
v="$(env $DRV "$BASE/bash" -c '. "$1"; herd_driver_agent_value DRIVER_AGENT_BINARY claude' _ "$DRIVER_SH" 2>/dev/null)"
[ "$v" = claude ] || fail "(6) herdr-claude driver DRIVER_AGENT_BINARY not read as claude: got [$v]"
echo "DRIVER_AGENT_NPM_PKG='@openai/codex'" > "$DD/nobinary.driver"
v="$(env HERD_DRIVER=nobinary HERD_DRIVERS_DIR="$DD" "$BASE/bash" -c '. "$1"; herd_driver_agent_value DRIVER_AGENT_BINARY claude' _ "$DRIVER_SH" 2>/dev/null)"
[ "$v" = claude ] || fail "(6) missing key did not fall back to the default: got [$v]"
ok

echo "ALL PASS ($pass checks)"
