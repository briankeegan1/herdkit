#!/usr/bin/env bash
# test-driver-wsl-interop.sh — hermetic tests for the WSL PATH-interop guard (HERD-454).
#
# FIELD FAILURE this closes: a WSL user's builders died seconds after spawn because `claude` resolved
# via PATH interop to /mnt/c/…claude.exe — a Windows binary WSL's interop channel bridges into the
# Linux shell, which dies the moment the spawning lane's shell detaches. `herd doctor` said claude ✓
# present the whole time (presence was never the question — the RESOLVED binary was the wrong one).
#
# ONE check (scripts/herd/driver.sh: herd_is_wsl / _herd_wsl_interop_path / herd_driver_wsl_interop_
# guard), TWO consumers: the LANE spawn gate (herd_preflight, scripts/herd/herd-preflight.sh — a hard
# refusal BEFORE any worktree/tab is created) and `herd doctor` (a reported red row, same hint).
#
# Asserts:
#   (1) herd_is_wsl: microsoft marker (case-insensitive), fail-soft on missing/unreadable /proc/version.
#   (2) _herd_wsl_interop_path: pure classifier — /mnt/* and *.exe (case-insensitive), no false hits.
#   (3) herd_driver_wsl_interop_guard is DRIVER-GENERIC (claude/codex/grok — never hardcoded): off-WSL
#       is a silent no-op even with a Windows binary on PATH (byte-identical, zero new probes); on WSL
#       it refuses with the fix hint; a Linux-native resolution / an unresolvable binary both pass.
#   (4) herd_preflight wires the guard BEFORE the headless early-return and before any herdr
#       requirement, and HERD_SKIP_PREFLIGHT=1 still bypasses it.
#   (5) herd doctor: silent off-WSL (byte-identical — no new section at all); a red row + same hint on
#       WSL, WARN-tier (does not gate exit 0, since git/gh presence — the doctor's own hard-fail
#       contract — is untouched); the git/gh/python3/node resolution-check wiring is present.
#   (6) MUTATION-PROVE, lane integration: a real new-feature.sh run, stubbed WSL + an interop agent
#       binary on PATH → the lane refuses BEFORE `git worktree add` runs (no worktree directory is
#       ever created), vs. a HERD_SKIP_PREFLIGHT=1 control that DOES create one — proving the guard,
#       not something else, is what's blocking it (remove the guard call → this case reds).
#
# Fully hermetic: temp dirs + a throwaway bare origin/clone only. NO herdr, NO gh, NO network, NO real
# /proc/version or /mnt path is touched (HERD_WSL_PROC_VERSION_FILE is the test seam driver.sh reads
# instead). No `set -e`: several checks deliberately expect a non-zero exit; asserted via fail().
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
DRIVER_SH="$ROOT/scripts/herd/driver.sh"
PREFLIGHT_SH="$ROOT/scripts/herd/herd-preflight.sh"
NEWFEAT="$ROOT/scripts/herd/new-feature.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail() { echo "FAIL: $1" >&2; exit 1; }
ok()   { pass=$((pass+1)); }

for f in "$DRIVER_SH" "$PREFLIGHT_SH" "$NEWFEAT"; do
  [ -f "$f" ] || fail "missing required file: $f"
done

# The standard system bin dirs — the full real coreutils set (grep/tail/tr/sed/…) the sourced code
# shells out to, PLUS python3/git wherever this host actually keeps them (mirrors tests/test-preflight.sh).
SYS="/usr/bin:/bin:/usr/sbin:/sbin"
command -v python3 >/dev/null 2>&1 || fail "python3 required to run this test"
case ":$SYS:" in *":$(dirname "$(command -v python3)"):"*) ;; *) SYS="$(dirname "$(command -v python3)"):$SYS";; esac
command -v git >/dev/null 2>&1 || fail "git required to run this test"
case ":$SYS:" in *":$(dirname "$(command -v git)"):"*) ;; *) SYS="$(dirname "$(command -v git)"):$SYS";; esac

# ── fixtures: fake /proc/version files (the HERD_WSL_PROC_VERSION_FILE test seam) ──────────────────
WSL_PROC="$T/proc-version-wsl"
printf 'Linux version 5.15.153.1-microsoft-standard-WSL2 (root@buildkitsandbox) (gcc)\n' > "$WSL_PROC"
MIXED_PROC="$T/proc-version-mixedcase"
printf 'Linux version 5.15.0 (build@host) (MicroSoft, gcc)\n' > "$MIXED_PROC"
LINUX_PROC="$T/proc-version-linux"
printf 'Linux version 6.8.0-generic (buildd@lcy02-amd64-031) (gcc)\n' > "$LINUX_PROC"
MISSING_PROC="$T/does-not-exist"

# dv <env…> -- <snippet> — run a snippet in a FRESH bash with driver.sh sourced.
dv() {
  local envs=(); while [ "$#" -gt 0 ] && [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift || true
  env ${envs[@]+"${envs[@]}"} bash -c '. "$1"; '"$*" _ "$DRIVER_SH"
}

# ── (1) herd_is_wsl: marker detection (case-insensitive) + fail-soft ────────────────────────────────
dv HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" -- 'herd_is_wsl' \
  || fail "(1) a microsoft-standard-WSL2 proc-version was not detected as WSL"
dv HERD_WSL_PROC_VERSION_FILE="$MIXED_PROC" -- 'herd_is_wsl' \
  || fail "(1) mixed-case 'MicroSoft' was not detected (the grep must be case-insensitive)"
dv HERD_WSL_PROC_VERSION_FILE="$LINUX_PROC" -- '! herd_is_wsl' \
  || fail "(1) a plain Linux proc-version was misdetected as WSL"
dv HERD_WSL_PROC_VERSION_FILE="$MISSING_PROC" -- '! herd_is_wsl' \
  || fail "(1) a missing /proc/version must fail-soft to 'not WSL', never abort"
if [ "$(id -u)" -ne 0 ]; then
  UNREADABLE="$T/proc-version-noperm"; printf 'microsoft\n' > "$UNREADABLE"; chmod 000 "$UNREADABLE"
  dv HERD_WSL_PROC_VERSION_FILE="$UNREADABLE" -- '! herd_is_wsl' \
    || fail "(1) an unreadable /proc/version must fail-soft to 'not WSL'"
  chmod 644 "$UNREADABLE"
fi
ok; echo "PASS (1) herd_is_wsl: marker detection + fail-soft on missing/unreadable"

# ── (2) _herd_wsl_interop_path: pure classifier, no filesystem needed ───────────────────────────────
for p in "/mnt/c/Users/x/AppData/Roaming/npm/claude" "/mnt/d/npm/claude.exe" "/opt/tools/CLAUDE.EXE"; do
  dv -- "_herd_wsl_interop_path '$p'" || fail "(2) '$p' should classify as WSL interop"
done
for p in "/usr/local/bin/claude" "/home/user/.npm-global/bin/claude" "" "/opt/exec/not-exe"; do
  dv -- "! _herd_wsl_interop_path '$p'" || fail "(2) '$p' should NOT classify as WSL interop"
done
ok; echo "PASS (2) _herd_wsl_interop_path: /mnt/* and *.exe (case-insensitive), no false hits"

# ── (3) herd_driver_wsl_interop_guard is DRIVER-GENERIC ──────────────────────────────────────────────
# A throwaway driver whose agent binary is named 'claude.exe' — proves the guard follows whatever the
# ACTIVE driver resolves to, not a hardcoded 'claude' string (real claude/codex/grok never carry a
# .exe-suffixed binary name themselves, so this is the only hermetic way to drive command -v to a
# resolved path ending .exe without touching a real Windows/mnt filesystem).
DRIVERS_D="$T/drivers"; mkdir -p "$DRIVERS_D"
cat > "$DRIVERS_D/wintest.driver" <<'EOF'
DRIVER_AGENT_INTERACTIVE_SPAWN='claude.exe --model <model> --dangerously-skip-permissions "<prompt>"'
DRIVER_AGENT_PERMISSION_FLAG='--dangerously-skip-permissions'
EOF
cat > "$DRIVERS_D/lintest.driver" <<'EOF'
DRIVER_AGENT_INTERACTIVE_SPAWN='claude-linux --model <model> --dangerously-skip-permissions "<prompt>"'
DRIVER_AGENT_PERMISSION_FLAG='--dangerously-skip-permissions'
EOF

BIN_EXE="$T/bin-exe"; mkdir -p "$BIN_EXE"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_EXE/claude.exe"; chmod +x "$BIN_EXE/claude.exe"
BIN_LINUX="$T/bin-linux"; mkdir -p "$BIN_LINUX"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_LINUX/claude-linux"; chmod +x "$BIN_LINUX/claude-linux"

# (3a) OFF WSL: even with the ONLY resolvable binary being the Windows one, the guard is a silent
#      no-op — herd_is_wsl short-circuits before any binary resolution runs (zero new spawn-path
#      probes off WSL; the non-WSL-byte-identical requirement).
out="$(env HERD_WSL_PROC_VERSION_FILE="$LINUX_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=wintest \
  PATH="$BIN_EXE:$SYS" bash -c '. "$1"; herd_driver_wsl_interop_guard' _ "$DRIVER_SH" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3a) an off-WSL run refused (rc=$rc): $out"
[ -z "$out" ]   || fail "(3a) an off-WSL run printed something (must be silent): $out"
ok

# (3b) ON WSL + the interop binary present → REFUSED, naming the binary/driver, with the fix hint.
out="$(env HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=wintest \
  PATH="$BIN_EXE:$SYS" bash -c '. "$1"; herd_driver_wsl_interop_guard' _ "$DRIVER_SH" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(3b) WSL + an interop binary should refuse (got rc=0): $out"
grep -qi "WSL interop"                                    <<<"$out" || fail "(3b) refusal doesn't mention WSL interop: $out"
grep -qF "$BIN_EXE/claude.exe"                             <<<"$out" || fail "(3b) refusal doesn't name the resolved binary path: $out"
grep -qi "wintest"                                         <<<"$out" || fail "(3b) refusal doesn't name the active driver: $out"
grep -qi "npm install -g @anthropic-ai/claude-code"        <<<"$out" || fail "(3b) fix hint missing the Linux-build install command: $out"
grep -qi "appendWindowsPath=false"                          <<<"$out" || fail "(3b) fix hint missing the wsl.conf interop fix: $out"
grep -qi "wsl --shutdown"                                   <<<"$out" || fail "(3b) fix hint missing wsl --shutdown: $out"
ok

# (3c) ON WSL, a DIFFERENT driver resolving a Linux-native binary → passes silently (proves the guard
#      isn't just "always refuse on WSL" — it genuinely inspects the resolved path).
out="$(env HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=lintest \
  PATH="$BIN_LINUX:$SYS" bash -c '. "$1"; herd_driver_wsl_interop_guard' _ "$DRIVER_SH" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3c) a Linux-native resolved binary should pass (got rc=$rc): $out"
[ -z "$out" ]   || fail "(3c) a clean pass should be silent: $out"
ok

# (3d) ON WSL, the driver's binary is nowhere on PATH → fail-soft ALLOW (can't check; "missing" is a
#      separate, pre-existing concern — not this guard's).
out="$(env HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=lintest \
  PATH="$SYS" bash -c '. "$1"; herd_driver_wsl_interop_guard' _ "$DRIVER_SH" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3d) an unresolvable binary should fail-soft ALLOW (got rc=$rc): $out"
ok

# (3e) A REAL shipped driver (codex) resolves by ITS OWN binary name ('codex', not 'claude') — proves
#      the guard reads the ACTIVE driver's binding, not a hardcoded 'claude' string.
BIN_CODEX="$T/bin-codex"; mkdir -p "$BIN_CODEX"
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN_CODEX/codex"; chmod +x "$BIN_CODEX/codex"
out="$(env HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVER=codex PATH="$BIN_CODEX:$SYS" \
  bash -c '. "$1"; herd_driver_wsl_interop_guard' _ "$DRIVER_SH" 2>&1)"; rc=$?
[ "$rc" -eq 0 ] || fail "(3e) the real codex driver resolving a normal Linux 'codex' binary should pass (got rc=$rc): $out"
ok
echo "PASS (3) herd_driver_wsl_interop_guard: driver-generic, off-WSL no-op, refuses/passes correctly, fail-soft on missing"

# ── (4) herd_preflight wiring: BEFORE headless early-return, BEFORE any herdr requirement ───────────
# No herdr stub anywhere on PATH — the refusal must fire without ever needing one.
out="$(env HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=wintest \
  PATH="$BIN_EXE:$SYS" bash -c '. "$1"; herd_preflight' _ "$PREFLIGHT_SH" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(4) herd_preflight passed a WSL+interop binary with no herdr on PATH (got rc=0): $out"
grep -qi "WSL interop" <<<"$out" || fail "(4) herd_preflight's refusal doesn't mention WSL interop: $out"
grep -qi "herdr"       <<<"$out" && fail "(4) the refusal should fire before any herdr-specific message: $out"
# Headless driver spawns a real detached process too — the guard must not be skippable via headless.
# A fake headless.driver dropped into the SAME HERD_DRIVERS_DIR overlay (real headless.driver's own
# binary name is plain 'claude', which — like real codex/grok — never carries a .exe suffix itself,
# so this reuses the .exe-trick fixture under the 'headless' driver NAME to drive the same probe).
cat > "$DRIVERS_D/headless.driver" <<'EOF'
DRIVER_AGENT_INTERACTIVE_SPAWN='claude.exe --model <model> --dangerously-skip-permissions "<prompt>"'
DRIVER_AGENT_PERMISSION_FLAG='--dangerously-skip-permissions'
EOF
out="$(env HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=headless \
  PATH="$BIN_EXE:$SYS" bash -c '. "$1"; herd_preflight' _ "$PREFLIGHT_SH" 2>&1)"; rc=$?
[ "$rc" -ne 0 ] || fail "(4) headless driver bypassed the WSL interop guard (got rc=0): $out"
grep -qi "WSL interop" <<<"$out" || fail "(4) headless refusal doesn't mention WSL interop: $out"
# HERD_SKIP_PREFLIGHT=1 still bypasses the WHOLE guard, including this check.
env HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=wintest \
  PATH="$BIN_EXE:$SYS" HERD_SKIP_PREFLIGHT=1 bash -c '. "$1"; herd_preflight' _ "$PREFLIGHT_SH" >/dev/null 2>&1 \
  || fail "(4) HERD_SKIP_PREFLIGHT=1 did not bypass the WSL interop guard"
ok; echo "PASS (4) herd_preflight: WSL guard fires before headless early-return / any herdr requirement; HERD_SKIP_PREFLIGHT bypasses it"

# ── (5) herd doctor: silent off-WSL, a red+warn row on WSL with the same hint, toolchain wiring ─────
mkbin() { local d="$T/$1"; rm -rf "$d"; mkdir -p "$d"; printf '%s' "$d"; }
add_present() { local d="$1"; shift; local n; for n in "$@"; do printf '#!/usr/bin/env bash\nexit 0\n' > "$d/$n"; chmod +x "$d/$n"; done; }
add_gh_authed() { printf '#!/usr/bin/env bash\ncase "$1 $2" in "auth status") exit 0;; esac\nexit 0\n' > "$1/gh"; chmod +x "$1/gh"; }
run_doctor() {
  local d="$1"; shift
  env "$@" PATH="$d:$SYS" bash -c '. "$0"; herd_doctor 2>&1' "$PREFLIGHT_SH"
}

# (5a) OFF WSL: no "WSL interop" section at all — byte-identical to a pre-HERD-454 doctor run.
b="$(mkbin s5a)"; add_present "$b" git claude; add_gh_authed "$b"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux HERD_WSL_PROC_VERSION_FILE="$LINUX_PROC")"; rc=$?
[ "$rc" -eq 0 ]                        || fail "(5a) off-WSL doctor run failed (rc=$rc): $out"
grep -qi "WSL interop" <<<"$out"       && fail "(5a) off-WSL doctor printed a WSL interop section: $out"
ok

# (5b) ON WSL + the active driver's binary resolving via interop (custom driver, same .exe trick) →
#      a red row with the SAME fix hint, but stays WARN-tier: git+gh present ⇒ still exit 0 (the
#      doctor's REQUIRED-tier contract — git/gh only — is untouched by this check).
b="$(mkbin s5b)"; add_present "$b" git claude; add_gh_authed "$b"
printf '#!/usr/bin/env bash\nexit 0\n' > "$b/claude.exe"; chmod +x "$b/claude.exe"
out="$(run_doctor "$b" HERD_DOCTOR_OS=linux HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=wintest)"; rc=$?
[ "$rc" -eq 0 ]                                      || fail "(5b) a WSL interop hit must stay WARN-tier, not gate exit (got rc=$rc): $out"
grep -qi "WSL interop"                       <<<"$out" || fail "(5b) doctor row missing the WSL interop section: $out"
grep -qF "$b/claude.exe"                     <<<"$out" || fail "(5b) doctor row doesn't name the resolved binary: $out"
grep -qi "wintest"                           <<<"$out" || fail "(5b) doctor row doesn't name the active driver: $out"
grep -qi "npm install -g @anthropic-ai/claude-code" <<<"$out" || fail "(5b) doctor row missing the same fix hint as the lane refusal: $out"
grep -qi "appendWindowsPath=false"            <<<"$out" || fail "(5b) doctor row missing the wsl.conf fix: $out"
grep -q "recommended dependency check(s) failed" <<<"$out" || fail "(5b) doctor summary doesn't reflect the bumped warn count: $out"
ok

# (5c) WIRING: the doctor's WSL section resolution-checks git/gh/python3/node too (warn-tier per
#      HERD-454 item 3). Behaviorally proving this needs a REAL /mnt-prefixed PATH (not available
#      hermetically without root — the .exe-suffix trick above only works for a binary whose OWN
#      binding names the extension, which git/gh/python3/node's real command names never do), so this
#      is a structural proof that the wiring exists, mirroring tests/test-engine-handshake.sh's own
#      structural assertion (check 12) for a similarly non-independently-triggerable code path.
grep -q 'for wsl_tool in git gh python3 node' "$PREFLIGHT_SH" \
  || fail "(5c) herd_doctor's WSL section does not resolution-check git/gh/python3/node"
ok
echo "PASS (5) herd doctor: silent off-WSL, red+warn row on WSL with the shared hint, toolchain check wired"

# ── (6) MUTATION-PROVE, lane integration: new-feature.sh refuses BEFORE any worktree is created ─────
REPO="$T/repo"
git init -q --bare "$T/origin.git"
git clone -q "$T/origin.git" "$REPO" 2>/dev/null
git -C "$REPO" checkout -q -b main
: > "$REPO/seed.txt"
git -C "$REPO" -c user.email=t@t -c user.name=t add seed.txt
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m seed
git -C "$REPO" push -q -u origin main 2>/dev/null

run_lane() {  # run_lane <slug> <extra env…>  → sets RC, WT_DIR, OUT
  local slug="$1"; shift
  local ltrees="$T/lane-trees-$slug"; mkdir -p "$ltrees"
  local cfg="$T/lane-cfg-$slug"
  {
    printf 'PROJECT_ROOT="%s"\n'  "$REPO"
    printf 'WORKTREES_DIR="%s"\n' "$ltrees"
    printf 'DEFAULT_BRANCH="origin/main"\n'
    printf 'WORKSPACE_NAME="wsl-interop-test"\n'
    printf 'SHARE_LINKS=""\n'
  } > "$cfg"
  WT_DIR="$ltrees/$slug"
  OUT="$(env HOME="$T" HERD_CONFIG_FILE="$cfg" WORKSPACE_NAME="wsl-interop-test" \
    PATH="$BIN_EXE:$SYS" "$@" bash "$NEWFEAT" "$slug" 2>&1)"
  RC=$?
}

# (6a) Stubbed WSL + an interop agent binary on PATH → the lane refuses, and NO worktree is ever
#      created (the mutation-prove: this is exactly what a caller removing the herd_preflight call —
#      or removing the WSL guard inside it — would break; without the guard this run would instead
#      succeed and create the worktree, so this assertion goes RED if the check is removed).
run_lane wsl-mutation-a HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=wintest
[ "$RC" -ne 0 ]        || fail "(6a) new-feature.sh succeeded despite a WSL+interop agent binary (rc=0): $OUT"
[ ! -e "$WT_DIR" ]     || fail "(6a) a worktree was created at $WT_DIR despite the refusal — the guard did not run before 'git worktree add'"
grep -qi "WSL interop" <<<"$OUT" || fail "(6a) new-feature.sh's failure output doesn't mention WSL interop: $OUT"
ok

# (6b) CONTROL: the identical fixture, but HERD_SKIP_PREFLIGHT=1 bypasses the guard → the worktree
#      DOES get created. This proves (a)+(b) together that the guard — not something else in the
#      fixture — is what blocked (6a).
run_lane wsl-mutation-b HERD_WSL_PROC_VERSION_FILE="$WSL_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=wintest HERD_SKIP_PREFLIGHT=1
[ "$RC" -eq 0 ]   || fail "(6b) control run (guard skipped) failed to create a worktree: $OUT"
[ -d "$WT_DIR" ]  || fail "(6b) control run (guard skipped) did not create the worktree at $WT_DIR: $OUT"
ok

# (6c) Off WSL, the SAME interop binary on PATH → the lane proceeds past the guard (worktree created);
#      proves the guard is WSL-scoped, not a blanket refusal of any .exe-named agent binary. Uses the
#      headless driver (bound to the same claude.exe fixture via the DRIVERS_D overlay, see (4) above)
#      so this proceeds without needing a herdr stub on PATH — herd_preflight's own herdr requirement
#      is an orthogonal concern to what's under test here.
run_lane wsl-mutation-c HERD_WSL_PROC_VERSION_FILE="$LINUX_PROC" HERD_DRIVERS_DIR="$DRIVERS_D" HERD_DRIVER=headless
[ "$RC" -eq 0 ]   || fail "(6c) an off-WSL run with the same binary was refused (rc=$RC): $OUT"
[ -d "$WT_DIR" ]  || fail "(6c) an off-WSL run did not create its worktree at $WT_DIR: $OUT"
ok
echo "PASS (6) MUTATION-PROVE: new-feature.sh refuses before any worktree exists on WSL+interop; a skipped/off-WSL guard lets it through"

echo
echo "ALL PASS ($pass groups) — WSL interop guard: detection, classifier, driver-generic refusal, lane + doctor wiring, mutation-proved."
