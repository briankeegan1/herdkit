#!/usr/bin/env bash
# test-codex-plugin-manifest.sh — hermetic, network-free validation of the CODEX plugin wrapper.
#
# suite-deps: plugins/herdkit-coordinator/skills/herd-coordinator/SKILL.md
#
# The Codex-side sibling of tests/test-plugin-manifest.sh (which guards the Claude Code plugin under
# plugin/). Same doctrine, same shape: the plugin is a THIN packaging layer, the herdkit CLI stays
# the source of truth, and the wrapper skill delegates to the CLI-rendered coordinator instead of
# forking it. Section 4 asserts on the REAL, committed SKILL.md's frontmatter and delegation
# contract, hence the `suite-deps:` header above — a docs-scoped selection that ran only the
# doc-drift/caps-sync/conformance lints must still select this test.
#
# Codex's packaging convention (verified against codex-cli 0.147.0 and its first-party
# `plugin-creator` system skill, whose references/plugin-json-spec.md is the canonical spec):
#   <marketplace-root>/.agents/plugins/marketplace.json   lists plugins; entry source is an OBJECT
#                                                         {"source":"local","path":"./plugins/<name>"}
#                                                         resolved relative to the marketplace root
#   <marketplace-root>/plugins/<name>/.codex-plugin/plugin.json   the plugin manifest
#   <marketplace-root>/plugins/<name>/skills/<skill>/SKILL.md     skills, keyed by `name:` frontmatter
# This differs from the Claude plugin on every one of those points (.claude-plugin/, a STRING source,
# no interface block), which is exactly why it gets its own test rather than a flag on the old one.
#
# Hermetic: parses the committed files only. It never installs anything and never invokes `codex`,
# so it runs identically on a machine with no Codex CLI at all.
# Run:  bash tests/test-codex-plugin-manifest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PLUGIN_DIR="$REPO/plugins/herdkit-coordinator"
PLUGIN_MANIFEST="$PLUGIN_DIR/.codex-plugin/plugin.json"
MARKETPLACE="$REPO/.agents/plugins/marketplace.json"
SKILL="$PLUGIN_DIR/skills/herd-coordinator/SKILL.md"

PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

command -v python3 >/dev/null 2>&1 || fail "python3 required to parse JSON"

# ── 1. Every packaging file exists ───────────────────────────────────────────────────────────────
[ -f "$PLUGIN_MANIFEST" ] || fail "missing Codex plugin manifest: plugins/herdkit-coordinator/.codex-plugin/plugin.json"
[ -f "$MARKETPLACE" ]     || fail "missing Codex marketplace manifest: .agents/plugins/marketplace.json"
[ -f "$SKILL" ]           || fail "missing wrapper skill: plugins/herdkit-coordinator/skills/herd-coordinator/SKILL.md"
pass

# ── 2. plugin.json matches the ingestion contract Codex's own validator enforces ─────────────────
# Mirrors $CODEX_HOME/skills/.system/plugin-creator/scripts/validate_plugin.py: the allowed top-level
# key set (an unsupported key — `hooks` is the documented example — is REJECTED, not ignored), strict
# semver, the required author/interface fields, and the `skills` path contract. Asserted here so the
# manifest stays valid on a machine that has no Codex installed to run the real validator.
python3 - "$PLUGIN_MANIFEST" "$PLUGIN_DIR" <<'PY' || fail "plugin.json is not valid JSON or violates the Codex plugin manifest contract"
import json, os, re, sys
m = json.load(open(sys.argv[1])); root = sys.argv[2]
allowed = {"id","name","version","description","skills","apps","mcpServers","interface",
           "author","homepage","repository","license","keywords"}
extra = sorted(set(m) - allowed)
assert not extra, "plugin.json has unsupported field/s Codex validation rejects: %s" % extra
for k in ("name","version","description"):
    assert isinstance(m.get(k), str) and m[k].strip(), "plugin.json %r must be a non-empty string" % k
semver = r"^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)(?:-[0-9A-Za-z.-]+)?(?:\+[0-9A-Za-z.-]+)?$"
assert re.match(semver, m["version"]), "plugin.json 'version' must be strict semver, got %r" % m["version"]
author = m.get("author")
assert isinstance(author, dict), "plugin.json 'author' must be an object"
assert not (set(author) - {"name","email","url"}), "plugin.json 'author' has unsupported fields"
assert isinstance(author.get("name"), str) and author["name"].strip(), "plugin.json 'author.name' required"
# `skills` must resolve to exactly "skills", and the directory it names must really exist.
if m.get("skills") is not None:
    assert m["skills"].rstrip("/").lstrip("./") == "skills", "plugin.json 'skills' must resolve to './skills/'"
    assert os.path.isdir(os.path.join(root, "skills")), "plugin.json declares 'skills' but skills/ is missing"
# Companion-file fields must not be declared without the companion file (validator rejects that).
for field, companion in (("apps", ".app.json"), ("mcpServers", ".mcp.json")):
    if isinstance(m.get(field), str):
        assert os.path.isfile(os.path.join(root, companion)), \
            "plugin.json declares %r but %s does not exist" % (field, companion)
iface = m.get("interface")
assert isinstance(iface, dict), "plugin.json 'interface' must be an object"
for k in ("displayName","shortDescription","longDescription","developerName","category"):
    assert isinstance(iface.get(k), str) and iface[k].strip(), "plugin.json 'interface.%s' required" % k
caps = iface.get("capabilities")
assert isinstance(caps, list) and caps and all(isinstance(c, str) and c.strip() for c in caps), \
    "plugin.json 'interface.capabilities' must be a non-empty array of strings"
dp = iface.get("defaultPrompt", iface.get("default_prompt"))
assert isinstance(dp, list) and dp, "plugin.json 'interface.defaultPrompt' must be a non-empty array"
# Only the first 3 starter prompts are shown, and each is capped at 128 chars — keep them usable.
assert len(dp) <= 3, "interface.defaultPrompt: entries past the first 3 are dropped by Codex (%d given)" % len(dp)
assert all(isinstance(p, str) and 0 < len(p) <= 128 for p in dp), \
    "interface.defaultPrompt entries must be non-empty and <=128 chars (longer ones are truncated)"
for k in ("websiteURL","privacyPolicyURL","termsOfServiceURL"):
    if k in iface:
        assert iface[k].startswith("https://"), "plugin.json 'interface.%s' must be an absolute https:// URL" % k
# Asset paths must point at real files inside the plugin archive.
for k in ("composerIcon","logo","logoDark"):
    if k in iface:
        assert os.path.isfile(os.path.join(root, iface[k])), "plugin.json 'interface.%s' points to a missing file" % k
for i, s in enumerate(iface.get("screenshots", [])):
    assert os.path.isfile(os.path.join(root, s)), "plugin.json 'interface.screenshots[%d]' points to a missing file" % i
# No leftover scaffold placeholders (the validator's own preflight check).
assert "[TODO:" not in json.dumps(m), "plugin.json still contains a '[TODO: ...]' placeholder"
PY
plugin_name="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["name"])' "$PLUGIN_MANIFEST")" \
  || fail "could not read plugin.json 'name'"
[ "$plugin_name" = "herdkit-coordinator" ] \
  || fail "plugin.json name expected 'herdkit-coordinator', got '$plugin_name'"
pass

# ── 3. marketplace.json is valid and its entry resolves to the real plugin directory ────────────
# The Codex marketplace entry differs from the Claude one in shape: `source` is an OBJECT and the
# entry carries a required `policy` + `category`. The path resolves against the MARKETPLACE ROOT —
# the directory holding .agents/, i.e. the repo root — which is what `codex plugin marketplace add
# <repo-root>` configures.
python3 - "$MARKETPLACE" "$REPO" "$plugin_name" <<'PY' || fail "marketplace.json invalid or does not reference the plugin"
import json, os, sys
mkt_path, repo, want_name = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(mkt_path))
assert isinstance(m.get("name"), str) and m["name"], "marketplace 'name' must be a non-empty string"
iface = m.get("interface")
if iface is not None:
    assert isinstance(iface, dict), "marketplace 'interface' must be an object"
    assert isinstance(iface.get("displayName"), str) and iface["displayName"], \
        "marketplace 'interface.displayName' must be a non-empty string when 'interface' is present"
plugins = m.get("plugins")
assert isinstance(plugins, list) and plugins, "marketplace 'plugins' must be a non-empty list"
entry = next((p for p in plugins if p.get("name") == want_name), None)
assert entry is not None, "marketplace does not list plugin %r" % want_name
src = entry.get("source")
assert isinstance(src, dict), "Codex plugin entry 'source' must be an OBJECT (Claude's is a string)"
assert src.get("source") == "local", "plugin entry 'source.source' must be 'local' for a repo marketplace"
path = src.get("path")
assert isinstance(path, str) and path.startswith("./"), "plugin entry 'source.path' must be a './'-relative path"
policy = entry.get("policy")
assert isinstance(policy, dict), "plugin entry 'policy' is required"
assert policy.get("installation") in ("NOT_AVAILABLE", "AVAILABLE", "INSTALLED_BY_DEFAULT"), \
    "plugin entry 'policy.installation' must be one of NOT_AVAILABLE/AVAILABLE/INSTALLED_BY_DEFAULT"
assert policy.get("authentication") in ("ON_INSTALL", "ON_USE"), \
    "plugin entry 'policy.authentication' must be ON_INSTALL or ON_USE"
assert isinstance(entry.get("category"), str) and entry["category"], "plugin entry 'category' is required"
# The listing must point at real files — and at the SAME plugin (no name drift between the two files).
resolved = os.path.normpath(os.path.join(repo, path))
manifest = os.path.join(resolved, ".codex-plugin", "plugin.json")
assert os.path.isfile(manifest), "marketplace source %r does not contain .codex-plugin/plugin.json" % path
pm = json.load(open(manifest))
assert pm.get("name") == want_name, "source manifest name %r != marketplace entry name %r" % (pm.get("name"), want_name)
# The plugin folder name must equal the plugin name (Codex's documented required behavior).
assert os.path.basename(resolved) == want_name, \
    "plugin folder %r must be named after the plugin %r" % (os.path.basename(resolved), want_name)
PY
pass

# ── 4. The wrapper skill is a real Codex skill and DELEGATES to the CLI ─────────────────────────
# Codex keys a skill by its `name:` frontmatter field (Claude's coordinator template carries only
# `description:`), so `name` is asserted here where the Claude test asserts only `description`.
python3 - "$SKILL" <<'PY' || fail "SKILL.md is not a valid delegating wrapper"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
assert text.startswith("---\n"), "SKILL.md must open with a YAML frontmatter block"
end = text.find("\n---", 4)
assert end != -1, "SKILL.md frontmatter is not closed"
fm = text[4:end]
# Codex's validator requires BOTH a name and a description, and rejects disable-model-invocation.
for key in ("name:", "description:"):
    assert key in fm, "SKILL.md frontmatter must include a %r field" % key
assert "name: herd-coordinator" in fm, "SKILL.md frontmatter 'name' must be 'herd-coordinator'"
for banned in ("disable-model-invocation:", "disable_model_invocation:"):
    assert banned not in fm, "SKILL.md must not set %r (Codex validation requires it be false/absent)" % banned
# Delegation contract: the wrapper must invoke the CLI render step and hand off to the
# CLI-rendered coordinator file — this is what keeps it a wrapper and not a fork.
assert "herd render" in text, "wrapper must call 'herd render' (the CLI is the source of truth)"
assert ".agents/skills/herd-coordinator/SKILL.md" in text, \
    "wrapper must hand off to the Codex-rendered coordinator skill path"
# Guard against forking: the wrapper must not paste the coordinator's own operating sections.
low = text.lower()
for banned in ("## on invocation", "## implement an item", "{{workspace_name}}"):
    assert banned not in low, "wrapper appears to duplicate coordinator logic (found %r)" % banned
PY
pass

# ── 5. The wrapper must not be confused with the CLI-RENDERED skill of the same name ────────────
# Both are named `herd-coordinator`; Codex namespaces the plugin one as
# `herdkit-coordinator:herd-coordinator`, so they coexist. The committed wrapper must therefore stay
# the BOOTSTRAP (it points AT the render), never a copy of it — if this file ever started carrying
# rendered tokens it would be a fork wearing the render's name.
grep -q '{{' "$SKILL" && fail "wrapper SKILL.md contains unrendered '{{...}}' tokens — it must not be a copy of the template"
pass

# ── 6. The Codex packaging must not disturb the Claude packaging ────────────────────────────────
# Step 10 is ADDITIVE: the Claude plugin keeps its own manifest, marketplace and wrapper, at their
# own paths. A future refactor that tried to "unify" the two by moving a Claude file under plugins/
# would break `/plugin install` silently, so pin the separation.
[ -f "$REPO/plugin/.claude-plugin/plugin.json" ] \
  || fail "the Claude plugin manifest disappeared — the Codex packaging must be purely additive"
[ -f "$REPO/.claude-plugin/marketplace.json" ] \
  || fail "the Claude marketplace disappeared — the Codex packaging must be purely additive"
[ "$MARKETPLACE" != "$REPO/.claude-plugin/marketplace.json" ] || fail "marketplace paths must not collide"
pass

echo "PASS ($PASS assertions) — Codex plugin manifest, marketplace, and wrapper skill are valid + consistent"
