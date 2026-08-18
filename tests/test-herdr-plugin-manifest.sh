#!/usr/bin/env bash
# test-herdr-plugin-manifest.sh — hermetic, network-free validation of the HERDR plugin package.
#
# suite-deps: herdr-plugin.toml packaging/herdr/action.sh packaging/herdr/pane.sh packaging/herdr/README.md
#
# The herdr-side sibling of tests/test-plugin-manifest.sh (Claude Code plugin under plugin/) and
# tests/test-codex-plugin-manifest.sh (Codex plugin under plugins/). Same doctrine: a THIN packaging
# layer over the CLI. herdr's plugin convention (https://herdr.dev/docs/plugins/, verified against
# herdr 0.8.0 `herdr plugin link`): a `herdr-plugin.toml` at the repo root (so the marketplace's
# `herdr plugin install owner/repo` finds it) with required top-level id/name/version/
# min_herdr_version, `[[actions]]` (id/title/contexts/command), `[[panes]]` (id/title/placement/
# command) and optional `[[build]]` — id charset: plugin id [A-Za-z0-9.:_-], action/pane ids the
# same MINUS the dot; every id unique within its kind.
#
# Hermetic: parses the committed manifest with a purpose-built reader for the SUBSET of TOML the
# manifest uses (top-level `key = <string|array>`, `[[table]]` arrays of the same), so it runs on a
# python3 with no tomllib (3.9 here) and never invokes `herdr`. Sections 4-6 assert the two helper
# scripts the manifest points at exist, parse, and keep the contract that makes the actions work:
# action.sh resolves the workspace cwd from HERDR_PLUGIN_CONTEXT_JSON and calls
# `herdr plugin pane open` with --cwd + --target-pane (a split MUST target a pane) and NEVER
# --workspace alongside --target-pane (herdr 0.8.0 rejects the split then); pane.sh runs the
# plugin's OWN bin/herd (PATH-first) for every verb the manifest declares.
# Run:  bash tests/test-herdr-plugin-manifest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"
MANIFEST="$REPO/herdr-plugin.toml"
ACTION="$REPO/packaging/herdr/action.sh"
PANE="$REPO/packaging/herdr/pane.sh"

PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }
command -v python3 >/dev/null 2>&1 || fail "python3 required"

# ── 1. The packaging files exist where the convention needs them ────────────────────────────────
[ -f "$MANIFEST" ] || fail "missing herdr-plugin.toml at the repo ROOT (herdr plugin install owner/repo reads it there)"
[ -f "$ACTION" ]   || fail "missing packaging/herdr/action.sh"
[ -f "$PANE" ]     || fail "missing packaging/herdr/pane.sh"
[ -f "$REPO/packaging/herdr/README.md" ] || fail "missing packaging/herdr/README.md"
[ -x "$REPO/install.sh" ] || fail "install.sh must be executable — it is the [[build]] step"
pass

# ── 2. Manifest parses + honours herdr's contract (required fields, id charsets, uniqueness) ─────
# Emits one "KIND<TAB>ID<TAB>COMMAND-JSON" line per action/pane for the later sections.
ENTRIES="$(python3 - "$MANIFEST" <<'PY'
import json, re, sys
top, tables, cur = {}, [], None
def val(raw):
    raw = raw.strip()
    if raw.startswith('"'):
        m = re.match(r'^"((?:[^"\\]|\\.)*)"\s*(#.*)?$', raw); assert m, "bad string: %s" % raw
        return json.loads('"' + m.group(1) + '"')
    if raw.startswith('['):
        m = re.match(r'^(\[.*\])\s*(#.*)?$', raw); assert m, "bad array: %s" % raw
        return json.loads(m.group(1))
    raise AssertionError("unsupported value: %s" % raw)
for ln in open(sys.argv[1], encoding="utf-8"):
    s = ln.strip()
    if not s or s.startswith("#"): continue
    m = re.match(r'^\[\[([A-Za-z_]+)\]\]$', s)
    if m:
        cur = {"__kind": m.group(1)}; tables.append(cur); continue
    m = re.match(r'^([A-Za-z_]+)\s*=\s*(.+)$', s); assert m, "unparseable line: %s" % s
    (cur if cur is not None else top)[m.group(1)] = val(m.group(2))
for k in ("id", "name", "version", "min_herdr_version"):
    assert isinstance(top.get(k), str) and top[k].strip(), "top-level %r must be a non-empty string" % k
assert re.fullmatch(r'[A-Za-z0-9.:_-]+', top["id"]), "plugin id charset: %r" % top["id"]
assert re.fullmatch(r'\d+\.\d+\.\d+', top["version"]), "version must be semver: %r" % top["version"]
assert re.fullmatch(r'\d+\.\d+\.\d+', top["min_herdr_version"]), "min_herdr_version must be semver"
assert isinstance(top.get("description"), str) and top["description"], "description required for the marketplace card"
assert top.get("platforms") == ["macos", "linux"], "platforms must be [macos, linux] (Windows is WSL2-only)"
kinds = {}
for t in tables: kinds.setdefault(t["__kind"], []).append(t)
assert set(kinds) <= {"build", "actions", "panes", "events", "link_handlers", "startup"}, "unknown table %s" % set(kinds)
assert kinds.get("build") and kinds["build"][0].get("command") == ["bash", "install.sh"], "[[build]] must run install.sh"
for kind in ("actions", "panes"):
    ids = [t.get("id") for t in kinds.get(kind, [])]
    assert ids, "no [[%s]]" % kind
    assert len(ids) == len(set(ids)), "%s ids not unique: %s" % (kind, ids)
    for t in kinds[kind]:
        assert re.fullmatch(r'[A-Za-z0-9:_-]+', t.get("id") or ""), "%s id charset (no dots): %r" % (kind, t.get("id"))
        assert isinstance(t.get("title"), str) and t["title"], "%s %r needs a title" % (kind, t["id"])
        assert isinstance(t.get("command"), list) and t["command"], "%s %r needs a command array" % (kind, t["id"])
for a in kinds["actions"]:
    assert a.get("contexts") == ["workspace"], "action %r must be workspace-scoped" % a["id"]
    assert a["command"][:2] == ["bash", "packaging/herdr/action.sh"] and len(a["command"]) == 3, \
        "action %r must be `bash packaging/herdr/action.sh <verb>`" % a["id"]
    assert a["command"][2] == a["id"], "action %r: verb must equal the action id" % a["id"]
for p in kinds["panes"]:
    assert p.get("placement") in ("overlay", "popup", "split", "tab", "zoomed"), "pane %r placement" % p["id"]
    assert "packaging/herdr/pane.sh" in " ".join(p["command"]) and "$HERDR_PLUGIN_ROOT" in " ".join(p["command"]), \
        "pane %r must exec packaging/herdr/pane.sh via $HERDR_PLUGIN_ROOT (panes cwd is the PROJECT, not the plugin root)" % p["id"]
assert [p["id"] for p in kinds["panes"]] == ["run"], "exactly one pane entrypoint `run` (actions multiplex on HERDKIT_VERB)"
for t in tables:
    print("%s\t%s\t%s" % (t["__kind"], t.get("id", ""), json.dumps(t.get("command"))))
PY
)" || fail "herdr-plugin.toml violates the herdr plugin manifest contract"
pass

# ── 3. Doctrine: version pinned to the sibling plugin manifests, id stable, description mentions herdr
_v="$(printf '%s\n' "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' "$REPO/plugin/.claude-plugin/plugin.json")")"
grep -q "^version = \"$_v\"" "$MANIFEST" || fail "herdr-plugin.toml version must track plugin/.claude-plugin/plugin.json ($_v)"
grep -q '^id = "herdkit"$' "$MANIFEST" || fail "plugin id must stay 'herdkit' (qualified action ids herdkit.<verb> are user-facing keybinding targets)"
grep -q 'briankeegan1/herdkit' "$MANIFEST" || fail "manifest header must carry the install incantation (herdr plugin install briankeegan1/herdkit)"
pass

# ── 4. Helper scripts parse and are executable ──────────────────────────────────────────────────
bash -n "$ACTION" || fail "action.sh does not parse"
bash -n "$PANE"   || fail "pane.sh does not parse"
[ -x "$ACTION" ] && [ -x "$PANE" ] || fail "action.sh / pane.sh must be executable"
pass

# ── 5. action.sh: every manifest verb accepted, unknown verb refused, pane-open argv contract ────
verbs="$(printf '%s\n' "$ENTRIES" | awk -F'\t' '$1=="actions"{print $2}')"
[ -n "$verbs" ] || fail "no action verbs parsed"
_out="$(HERDR_BIN_PATH=echo HERDR_PLUGIN_ID=herdkit HERDR_WORKSPACE_ID=wX HERDR_PANE_ID='' \
        HERDR_PLUGIN_CONTEXT_JSON='{"workspace_cwd":"'"$REPO"'","focused_pane_id":"wX:p1","workspace_id":"wX"}' \
        bash "$ACTION" bogus-verb 2>&1)" && fail "action.sh accepted an unknown verb"
grep -q "unknown verb" <<<"$_out" || fail "action.sh unknown-verb error text missing: $_out"
for v in $verbs; do
  _out="$(HERDR_BIN_PATH=echo HERDR_PLUGIN_ID=herdkit HERDR_WORKSPACE_ID=wX HERDR_PANE_ID='' \
          HERDR_PLUGIN_CONTEXT_JSON='{"workspace_cwd":"'"$REPO"'","focused_pane_id":"wX:p1","workspace_id":"wX"}' \
          bash "$ACTION" "$v" 2>&1)" || fail "action.sh $v failed: $_out"
  case "$_out" in
    "plugin pane open "*) ;;
    *) fail "action.sh $v must exec 'herdr plugin pane open …', got: $_out" ;;
  esac
  grep -q -- "--plugin herdkit --entrypoint run" <<<"$_out" || fail "$v: wrong plugin/entrypoint: $_out"
  grep -q -- "--placement split" <<<"$_out" || fail "$v: default placement must be split: $_out"
  grep -q -- "--cwd $REPO" <<<"$_out" || fail "$v: must pass the workspace cwd from the context JSON: $_out"
  grep -q -- "--target-pane wX:p1" <<<"$_out" || fail "$v: a split must target the focused pane: $_out"
  grep -q -- "--env HERDKIT_VERB=$v" <<<"$_out" || fail "$v: verb must travel in HERDKIT_VERB: $_out"
  grep -q -- "--workspace" <<<"$_out" && fail "$v: --workspace alongside --target-pane makes herdr 0.8.0 reject the split: $_out"
done
# No focused pane in the context (and none in env) → degrade to a tab in the workspace, never a bare split.
_out="$(HERDR_BIN_PATH=echo HERDR_PLUGIN_ID=herdkit HERDR_WORKSPACE_ID=wX HERDR_PANE_ID='' \
        HERDR_PLUGIN_CONTEXT_JSON='{"workspace_cwd":"'"$REPO"'"}' bash "$ACTION" status 2>&1)" || fail "action.sh (no pane) failed: $_out"
grep -q -- "--placement tab" <<<"$_out" || fail "no focused pane must degrade to --placement tab: $_out"
grep -q -- "--workspace wX" <<<"$_out" || fail "tab placement must carry --workspace: $_out"
grep -q -- "--target-pane" <<<"$_out" && fail "tab placement must not pass --target-pane: $_out"
# focused_pane_cwd is the fallback when workspace_cwd is absent; an unresolvable cwd is a hard error.
_out="$(HERDR_BIN_PATH=echo HERDR_PLUGIN_ID=herdkit HERDR_PLUGIN_CONTEXT_JSON='{"focused_pane_cwd":"'"$REPO"'","focused_pane_id":"wX:p1"}' bash "$ACTION" status 2>&1)" || fail "focused_pane_cwd fallback failed: $_out"
grep -q -- "--cwd $REPO" <<<"$_out" || fail "focused_pane_cwd fallback not honoured: $_out"
_out="$(HERDR_BIN_PATH=echo HERDR_PLUGIN_ID=herdkit HERDR_PLUGIN_CONTEXT_JSON='{"workspace_cwd":"/nonexistent/x"}' bash "$ACTION" status 2>&1)" && fail "action.sh must refuse an unresolvable cwd"
grep -q "could not resolve" <<<"$_out" || fail "unresolvable-cwd error text missing: $_out"
pass

# ── 6. pane.sh: PATH-first plugin bin, every verb dispatches to herd, one-shot verbs hold ────────
# Stub `herd` + coordinator.sh in a scratch plugin root; a probe verb proves the dispatch table
# without running the real engine. stdin=/dev/null so hold()'s read returns at once.
scratch="$(mktemp -d)"; trap 'rm -rf "$scratch"' EXIT
mkdir -p "$scratch/bin" "$scratch/scripts/herd" "$scratch/packaging/herdr"
cp "$PANE" "$scratch/packaging/herdr/pane.sh"
printf '#!/usr/bin/env bash\necho "STUB-HERD $*"; echo "HOME=$HERDKIT_HOME"; exit 3\n' > "$scratch/bin/herd"
printf '#!/usr/bin/env bash\necho "STUB-COORD $*"\n' > "$scratch/scripts/herd/coordinator.sh"
chmod +x "$scratch/bin/herd" "$scratch/scripts/herd/coordinator.sh"
grep -q 'export PATH="$root/bin:$PATH"' "$PANE" || fail "pane.sh must put the plugin's own bin/ FIRST on PATH"
grep -q 'HERDR_PLUGIN_ROOT' "$PANE" || fail "pane.sh must root itself at HERDR_PLUGIN_ROOT"
for v in $verbs; do
  grep -q "^  $v)" "$PANE" || fail "pane.sh has no dispatch arm for manifest verb '$v'"
done
rc=0; _out="$(cd "$scratch" && HERDR_PLUGIN_ROOT="$scratch" HERDKIT_VERB=status bash packaging/herdr/pane.sh </dev/null 2>&1)" || rc=$?
grep -q "STUB-HERD status" <<<"$_out" || fail "status verb did not run the plugin's herd: $_out"
grep -q "HOME=$scratch" <<<"$_out" || fail "pane.sh must export HERDKIT_HOME=plugin root: $_out"
grep -q "status finished (exit 3) — press Enter" <<<"$_out" || fail "one-shot verb must hold with the verb's exit status: $_out"
[ "$rc" -eq 3 ] || fail "pane.sh must exit with the verb's status (got $rc)"
_out="$(cd "$scratch" && HERDR_PLUGIN_ROOT="$scratch" HERDKIT_VERB=backlog bash packaging/herdr/pane.sh </dev/null 2>&1)" || true
grep -q "STUB-HERD backlog --rich" <<<"$_out" || fail "backlog verb must run 'herd backlog --rich': $_out"
_out="$(cd "$scratch" && HERDR_PLUGIN_ROOT="$scratch" HERDKIT_VERB=launch bash packaging/herdr/pane.sh </dev/null 2>&1)" || true
grep -q "STUB-COORD" <<<"$_out" || fail "launch verb must run scripts/herd/coordinator.sh from the plugin root: $_out"
_out="$(cd "$scratch" && HERDR_PLUGIN_ROOT="$scratch" HERDKIT_VERB=nope bash packaging/herdr/pane.sh </dev/null 2>&1)" && fail "pane.sh accepted an unknown verb"
grep -q "unknown HERDKIT_VERB" <<<"$_out" || fail "pane.sh unknown-verb text missing: $_out"
# `init` execs herd directly (interactive) — no hold.
_out="$(cd "$scratch" && HERDR_PLUGIN_ROOT="$scratch" HERDKIT_VERB=init bash packaging/herdr/pane.sh </dev/null 2>&1)" || true
grep -q "STUB-HERD init" <<<"$_out" || fail "init verb must exec herd init: $_out"
grep -q "press Enter" <<<"$_out" && fail "init is interactive and must NOT hold: $_out"
# A pane run with no HERDR_PLUGIN_ROOT and no bin/herd next to it refuses loudly.
_out="$(cd "$scratch" && HERDR_PLUGIN_ROOT=/nonexistent/plugin HERDKIT_VERB=status bash "$scratch/packaging/herdr/pane.sh" </dev/null 2>&1)" || true
# (falls back to its own location → scratch root, which HAS the stub herd → still dispatches)
grep -q "STUB-HERD status" <<<"$_out" || fail "pane.sh must fall back to its own checkout when HERDR_PLUGIN_ROOT is bogus: $_out"
pass

echo "test-herdr-plugin-manifest: ALL PASS ($PASS sections)"
