#!/usr/bin/env bash
# test-plugin-manifest.sh — hermetic, network-free validation of the Claude Code plugin wrapper.
#
# The plugin is a THIN packaging layer: the herdkit CLI stays the source of truth and the plugin
# skill delegates to the CLI-rendered coordinator. This test asserts the packaging is valid JSON
# and internally consistent — the manifest, the marketplace listing, and the wrapper skill all
# point at the expected pieces — WITHOUT installing anything or touching the network/herdr.
# Run:  bash tests/test-plugin-manifest.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

PLUGIN_MANIFEST="$REPO/plugin/.claude-plugin/plugin.json"
MARKETPLACE="$REPO/.claude-plugin/marketplace.json"
SKILL="$REPO/plugin/skills/herd-coordinator/SKILL.md"

PASS=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass(){ PASS=$((PASS+1)); }

command -v python3 >/dev/null 2>&1 || fail "python3 required to parse JSON"

# ── 1. Every packaging file exists ───────────────────────────────────────────────────────────────
[ -f "$PLUGIN_MANIFEST" ] || fail "missing plugin manifest: plugin/.claude-plugin/plugin.json"
[ -f "$MARKETPLACE" ]     || fail "missing marketplace manifest: .claude-plugin/marketplace.json"
[ -f "$SKILL" ]           || fail "missing wrapper skill: plugin/skills/herd-coordinator/SKILL.md"
pass

# ── 2. plugin.json is valid JSON with the expected identity ─────────────────────────────────────
plugin_name="$(python3 - "$PLUGIN_MANIFEST" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
assert isinstance(m.get("name"), str) and m["name"], "plugin.json 'name' must be a non-empty string"
# version + description are what a marketplace/UI surfaces — keep them present.
assert m.get("version"), "plugin.json should declare a 'version'"
assert m.get("description"), "plugin.json should declare a 'description'"
print(m["name"])
PY
)" || fail "plugin.json is not valid JSON or missing required fields"
[ "$plugin_name" = "herdkit-coordinator" ] \
  || fail "plugin.json name expected 'herdkit-coordinator', got '$plugin_name'"
pass

# ── 3. marketplace.json is valid JSON and references the plugin by name + resolvable source ─────
python3 - "$MARKETPLACE" "$REPO" "$plugin_name" <<'PY' || fail "marketplace.json invalid or does not reference the plugin"
import json, os, sys
mkt_path, repo, want_name = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(mkt_path))
assert isinstance(m.get("name"), str) and m["name"], "marketplace 'name' must be a non-empty string"
plugins = m.get("plugins")
assert isinstance(plugins, list) and plugins, "marketplace 'plugins' must be a non-empty list"
entry = next((p for p in plugins if p.get("name") == want_name), None)
assert entry is not None, "marketplace does not list plugin %r" % want_name
src = entry.get("source")
assert isinstance(src, str) and src, "plugin entry 'source' must be a relative path string"
# The source is relative to the marketplace root (the repo root here): it must resolve to the
# directory that actually holds the plugin manifest — proving the listing points at real files.
resolved = os.path.normpath(os.path.join(repo, src))
manifest = os.path.join(resolved, ".claude-plugin", "plugin.json")
assert os.path.isfile(manifest), "marketplace source %r does not contain .claude-plugin/plugin.json" % src
# And the pointed-at manifest must be the SAME plugin (no name drift between the two files).
pm = json.load(open(manifest))
assert pm.get("name") == want_name, "source manifest name %r != marketplace entry name %r" % (pm.get("name"), want_name)
PY
pass

# ── 4. The wrapper skill is a real skill (frontmatter description) and DELEGATES to the CLI ──────
python3 - "$SKILL" <<'PY' || fail "SKILL.md is not a valid delegating wrapper"
import sys
text = open(sys.argv[1], encoding="utf-8").read()
# Frontmatter: a description is REQUIRED for Claude to invoke a skill.
assert text.startswith("---"), "SKILL.md must open with a YAML frontmatter block"
fm = text.split("---", 2)[1]
assert "description:" in fm, "SKILL.md frontmatter must include a 'description'"
# Delegation contract: the wrapper must invoke the CLI render step and hand off to the
# CLI-rendered coordinator file — this is what keeps it a wrapper and not a fork.
assert "herd render" in text, "wrapper must call 'herd render' (the CLI is the source of truth)"
assert ".claude/commands/coordinator.md" in text, \
    "wrapper must hand off to the CLI-rendered coordinator skill path"
# Guard against forking: the wrapper must not paste the coordinator's own operating sections.
low = text.lower()
for banned in ("## on invocation", "## implement an item", "{{workspace_name}}"):
    assert banned not in low, "wrapper appears to duplicate coordinator logic (found %r)" % banned
PY
pass

echo "PASS ($PASS assertions) — plugin manifest, marketplace, and wrapper skill are valid + consistent"
