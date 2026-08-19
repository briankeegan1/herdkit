#!/usr/bin/env bash
# HERD-773: atomic, complete, reversible Claude Code <-> Codex runtime switching.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $*" >&2; exit 1; }
ok(){ echo "ok: $*"; }

# Load the CLI's functions without dispatching a mutating command, then replace reload with a
# deterministic counter. This exercises the real switch/config/driver functions while proving the
# command owns exactly one reload rather than depending on a live pane server.
set -- help
. "$ROOT/bin/herd" >/dev/null
cmd_reload(){ printf 'reload\n' >> "$HERD_RS_RELOAD_LOG"; }

P="$T/project"; mkdir -p "$P/.herd" "$T/bin"
cat > "$P/.herd/config" <<EOF
WORKSPACE_NAME="runtime-switch-test"
PROJECT_ROOT="$P"
HERD_DRIVER="herdr-claude"
MODEL_FEATURE="old-feature"
EOF
cat > "$P/.herd/config.local" <<'EOF'
# existing machine overlay
MODEL_QUICK="old-quick"
EOF
cp "$P/.herd/config" "$T/baseline.before"

for rt in claude codex; do
  cat > "$T/bin/$rt" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
  "auth status"|"login status") exit "${RUNTIME_AUTH_RC:-0}" ;;
esac
exit 0
EOF
  chmod +x "$T/bin/$rt"
done
export PATH="$T/bin:$PATH" HERD_RS_RELOAD_LOG="$T/reloads"

# Dry-run: full map shown, binary/login/argv preflight run, zero bytes changed and zero reloads.
before="$(shasum "$P/.herd/config.local")"
out="$(cd "$P" && cmd_runtime_switch codex --dry-run)"
[ "$before" = "$(shasum "$P/.herd/config.local")" ] || fail "dry-run changed config.local"
[ ! -e "$HERD_RS_RELOAD_LOG" ] || fail "dry-run reloaded"
for k in HERD_DRIVER MODEL_COORDINATOR MODEL_FEATURE MODEL_QUICK MODEL_SCRIBE MODEL_RESEARCH \
  MODEL_REVIEW MODEL_RESOLVER MODEL_ADVISE MODEL_ESCALATE REVIEW_MODEL_CHEAP REVIEW_MODEL_DOCS \
  REVIEW_MODEL_ESCALATED; do
  grep -q "${k}" <<<"$out" || fail "dry-run omitted role $k"
done
grep -q 'NOTHING was written' <<<"$out" || fail "dry-run did not state no-write"
ok "dry-run is complete and write-free"

# Claude -> Codex: one atomic overlay contains the complete preset and exactly one reload occurred.
( cd "$P" && cmd_runtime_switch codex ) >"$T/codex.out"
[ "$(wc -l < "$HERD_RS_RELOAD_LOG" | tr -d ' ')" = 1 ] || fail "Codex switch did not reload exactly once"
[ "$( _config_file_value "$P/.herd/config.local" HERD_DRIVER )" = codex ] || fail "driver not switched to codex"
while IFS=$'\t' read -r k v; do
  [ "$( _config_file_value "$P/.herd/config.local" "$k" )" = "$v" ] || fail "Codex map mismatch: $k"
done < <(_runtime_switch_pairs codex)
cmp -s "$P/.herd/config" "$T/baseline.before" || fail "switch mutated shared .herd/config"
[ ! -e "$P/.herd/secrets" ] || fail "switch created/touched secrets"
grep -q 'runtime switch herdr-claude' "$T/codex.out" || fail "Codex switch omitted rollback path"
ok "Claude to Codex map is complete, local, and reloads once"

# Codex -> Claude: complete inverse preset and one additional (not per-key) reload.
( cd "$P" && cmd_runtime_switch herdr-claude ) >"$T/claude.out"
[ "$(wc -l < "$HERD_RS_RELOAD_LOG" | tr -d ' ')" = 2 ] || fail "Claude switch did not add exactly one reload"
while IFS=$'\t' read -r k v; do
  [ "$( _config_file_value "$P/.herd/config.local" "$k" )" = "$v" ] || fail "Claude map mismatch: $k"
done < <(_runtime_switch_pairs herdr-claude)
grep -q 'runtime switch codex' "$T/claude.out" || fail "Claude switch omitted switch-back path"
ok "Codex to Claude map is complete and reversible"

# Missing runtime and failed login: hard refusal, byte-identical overlay, no reload.
mkdir "$T/missing-drivers"; cp "$ROOT/templates/drivers/herdr-claude.driver" "$T/missing-drivers/"
sed 's/codex/definitely-missing-herd-runtime/g' "$ROOT/templates/drivers/codex.driver" > "$T/missing-drivers/codex.driver"
before="$(shasum "$P/.herd/config.local")"; set +e
( cd "$P" && HERD_DRIVERS_DIR="$T/missing-drivers" cmd_runtime_switch codex ) >"$T/missing.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "missing runtime was accepted"
[ "$before" = "$(shasum "$P/.herd/config.local")" ] || fail "missing-runtime refusal wrote config"
[ "$(wc -l < "$HERD_RS_RELOAD_LOG" | tr -d ' ')" = 2 ] || fail "missing-runtime refusal reloaded"
before="$(shasum "$P/.herd/config.local")"; set +e
RUNTIME_AUTH_RC=1 bash -c 'set -- help; . "$1" >/dev/null; cd "$2"; cmd_runtime_switch codex' _ "$ROOT/bin/herd" "$P" >"$T/auth.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "logged-out runtime was accepted"
[ "$before" = "$(shasum "$P/.herd/config.local")" ] || fail "login refusal wrote config"
ok "missing and logged-out runtimes refuse atomically"

# Malformed driver argv is also a pre-write refusal.
mkdir "$T/drivers"; cp "$ROOT/templates/drivers/herdr-claude.driver" "$T/drivers/"
cp "$ROOT/templates/drivers/codex.driver" "$T/drivers/codex.driver"
sed -i.bak "s|^DRIVER_AGENT_ONESHOT_EXEC=.*|DRIVER_AGENT_ONESHOT_EXEC='codex exec --model <model>'|" "$T/drivers/codex.driver"
rm "$T/drivers/codex.driver.bak"
before="$(shasum "$P/.herd/config.local")"; set +e
( cd "$P" && HERD_DRIVERS_DIR="$T/drivers" cmd_runtime_switch codex ) >"$T/shape.out" 2>&1; rc=$?
set -e
[ "$rc" -ne 0 ] || fail "undriveable argv was accepted"
[ "$before" = "$(shasum "$P/.herd/config.local")" ] || fail "argv refusal wrote config"
ok "undriveable argv refuses before write"

# Shared coordinator prose must describe the active runtime, not prescribe one vendor.
if rg -n 'Claude Code|Claude quota|Claude death' "$ROOT/templates/coordinator.md.tmpl" >"$T/vendor.out"; then
  fail "coordinator template retains vendor-prescriptive prose: $(cat "$T/vendor.out")"
fi
ok "coordinator template prose is runtime-neutral"

echo "PASS: atomic runtime switch"
