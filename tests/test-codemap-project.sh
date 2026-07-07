#!/usr/bin/env bash
# test-codemap-project.sh — hermetic test for PROJECT-mode `herd codemap` (HERD-79).
#
# `herd codemap` has two modes, auto-selected from the tree it maps:
#   • ENGINE mode  — the herdkit repo itself (byte-identical to the historical map).
#   • PROJECT mode — a CONSUMING project's OWN source tree, language-aware (node/python/go/rust/java),
#                    emitting the same section shapes (module roles, who-imports-whom, config-key →
#                    consumer) with an OPTIONAL graphify enrichment.
#
# This test builds tiny throwaway fixture trees per language (no network, no model, no herdr) and
# drives the REAL scripts/herd/codemap.sh against them via HERD_CODEMAP_ROOT/HERD_CODEMAP_OUT so the
# committed docs/codemap.md is never touched. It asserts, for each mode:
#   • the right mode is auto-detected (engine → "Who sources whom"; project → "Who imports whom")
#   • module roles, local import edges, and env-var config keys are mapped
#   • DETERMINISM: two independent generations of an unchanged tree are byte-identical
#   • the determinism guardrails hold: no absolute path and no timestamp leak into the map
#   • ENGINE mode stays byte-identical on a frozen fixture engine tree, and the real herdkit repo
#     still maps as ENGINE (HERD-79 did not flip herdkit itself to project mode)
#   • the graphify enrichment appears when GRAPHIFY_BIN + graphify-out/graph.json are present and is
#     absent (fail-soft) otherwise
#
# Run:  bash tests/test-codemap-project.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT_REPO="$(cd "$HERE/.." && pwd)"
CODEMAP="$ROOT_REPO/scripts/herd/codemap.sh"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail(){ echo "FAIL: $1" >&2; exit 1; }
pass=0; ok(){ pass=$((pass+1)); }
command -v git >/dev/null 2>&1 || fail "git required"
[ -f "$CODEMAP" ] || fail "codemap.sh not found at $CODEMAP"

# gen <root> <out> [env KEY=VAL ...] — run codemap.sh against <root>, writing <out>. Extra args are
# exported for the run (e.g. GRAPHIFY_BIN=...). Never sets HERD_CODEMAP_ROOT to the engine repo.
gen(){
  local root="$1" out="$2"; shift 2
  env "$@" HERD_CODEMAP_ROOT="$root" HERD_CODEMAP_OUT="$out" bash "$CODEMAP" </dev/null >/dev/null 2>&1 \
    || fail "codemap.sh exited non-zero for $root"
  [ -s "$out" ] || fail "codemap emitted nothing for $root"
}

# guardrails <out> — the determinism guardrails shared by every map: no absolute path, no timestamp.
guardrails(){
  local out="$1"
  if grep -qE '(^|[^a-zA-Z0-9_])/(Users|home|tmp|var|private)/' "$out"; then
    fail "map leaked an absolute path: $out"
  fi
  grep -qiE '[0-9]{4}-[0-9]{2}-[0-9]{2}' "$out" && fail "map leaked a date/timestamp: $out"
  return 0
}

# determinism <root> <out> — a second independent generation must be byte-identical.
determinism(){
  local root="$1" out="$2" out2="$T/det.md"
  gen "$root" "$out2"
  cmp -s "$out" "$out2" || fail "non-deterministic map for $root (two generations differ)"
}

# ══ NODE ════════════════════════════════════════════════════════════════════════════════════════
N="$T/node"; mkdir -p "$N/src"
printf '{ "name": "demo" }\n' > "$N/package.json"
cat > "$N/src/index.js" <<'EOF'
// index.js — app entrypoint wiring the server together.
import { start } from './server';
const port = process.env.PORT || 3000;
const key = process.env["API_KEY"];
start(port, key);
EOF
cat > "$N/src/server.js" <<'EOF'
// server.js — HTTP server bootstrap.
const cfg = require('./config');
const dbg = process.env.DEBUG;
module.exports.start = () => {};
EOF
cat > "$N/src/config.js" <<'EOF'
/* config.js — reads runtime configuration from the environment. */
const region = process.env.AWS_REGION;
EOF
NO="$T/node.md"; gen "$N" "$NO"
head -1 "$NO" | grep -qF -- '# node codemap'                          || fail "node: wrong title: $(head -1 "$NO")"
grep -qF "a native scan of this project's node source tree" "$NO"  || fail "node: missing mode/lang banner"
grep -qF -- '## Who imports whom'                                     "$NO" || fail "node: not project mode (no imports section)"
grep -qF -- '## Who sources whom'                                     "$NO" && fail "node: leaked the ENGINE 'sources whom' section"
grep -qF -- '- `src/index.js` — app entrypoint wiring the server together.' "$NO" || fail "node: missing module role"
grep -qF -- '- `src/index.js` → `./server`'                           "$NO" || fail "node: missing local import edge"
grep -qF -- '- `API_KEY` → `src/index.js`'                            "$NO" || fail "node: missing env config key (bracket form)"
grep -qF -- '- `PORT` → `src/index.js`'                               "$NO" || fail "node: missing env config key (dot form)"
guardrails "$NO"; determinism "$N" "$NO"; ok
echo "PASS node project map"

# ══ PYTHON ══════════════════════════════════════════════════════════════════════════════════════
P="$T/py"; mkdir -p "$P/pkg"
printf '[project]\nname = "demo"\n' > "$P/pyproject.toml"
cat > "$P/app.py" <<'EOF'
#!/usr/bin/env python3
"""app.py — CLI entrypoint for the demo service."""
import os
from pkg import worker
from .helpers import setup
TOKEN = os.getenv("SERVICE_TOKEN")
HOST = os.environ["DB_HOST"]
EOF
cat > "$P/helpers.py" <<'EOF'
# helpers.py — small shared utilities.
import os
level = os.environ.get("LOG_LEVEL")
EOF
: > "$P/pkg/__init__.py"
cat > "$P/pkg/worker.py" <<'EOF'
"""
worker.py — background job runner.
"""
import os
q = os.getenv("QUEUE_URL")
EOF
PO="$T/py.md"; gen "$P" "$PO"
head -1 "$PO" | grep -qF -- '# py codemap'                            || fail "py: wrong title"
grep -qF "a native scan of this project's python source tree" "$PO" || fail "py: missing python banner"
grep -qF -- '- `pkg/worker.py` — background job runner.'              "$PO" || fail "py: missing multi-line docstring role"
grep -qF -- '- `app.py` — CLI entrypoint for the demo service.'       "$PO" || fail "py: missing one-line docstring role"
grep -qF -- '- `app.py` → `.helpers`, `pkg`'                          "$PO" || fail "py: missing local import edges (relative + package)"
grep -qF -- '- `DB_HOST` → `app.py`'                                  "$PO" || fail "py: missing os.environ[] key"
grep -qF -- '- `LOG_LEVEL` → `helpers.py`'                            "$PO" || fail "py: missing os.environ.get key"
grep -qF -- '- `SERVICE_TOKEN` → `app.py`'                            "$PO" || fail "py: missing os.getenv key"
guardrails "$PO"; determinism "$P" "$PO"; ok
echo "PASS python project map"

# ══ GO ══════════════════════════════════════════════════════════════════════════════════════════
G="$T/go"; mkdir -p "$G/util"
printf 'module example.com/demo\n\ngo 1.21\n' > "$G/go.mod"
cat > "$G/main.go" <<'EOF'
// main.go — program entrypoint.
package main

import (
	"fmt"
	"example.com/demo/util"
)

func main() { fmt.Println(util.Env()) }
EOF
cat > "$G/util/env.go" <<'EOF'
// env.go — environment helpers.
package util

import "os"

func Env() string { return os.Getenv("GO_MODE") + os.Getenv("REGION") }
EOF
GO="$T/go.md"; gen "$G" "$GO"
head -1 "$GO" | grep -qF -- '# go codemap'                            || fail "go: wrong title"
grep -qF -- '- `main.go` — program entrypoint.'                       "$GO" || fail "go: missing module role"
grep -qF -- '- `main.go` → `util`'                                    "$GO" || fail "go: missing module-local import edge"
grep -qF -- '- `GO_MODE` → `util/env.go`'                             "$GO" || fail "go: missing os.Getenv key"
grep -qF -- '- `REGION` → `util/env.go`'                              "$GO" || fail "go: missing 2nd os.Getenv key on same line"
guardrails "$GO"; determinism "$G" "$GO"; ok
echo "PASS go project map"

# ══ RUST ════════════════════════════════════════════════════════════════════════════════════════
R="$T/rs"; mkdir -p "$R/src"
printf '[package]\nname = "demo"\n' > "$R/Cargo.toml"
cat > "$R/src/main.rs" <<'EOF'
//! main.rs — binary entrypoint.
use crate::config::load;
mod config;

fn main() { let _ = load(); }
EOF
cat > "$R/src/config.rs" <<'EOF'
// config.rs — configuration loader.
use std::env;

pub fn load() -> String { env::var("RUST_ENDPOINT").unwrap_or_default() }
EOF
RO="$T/rs.md"; gen "$R" "$RO"
head -1 "$RO" | grep -qF -- '# rs codemap'                            || fail "rust: wrong title"
grep -qF -- '- `src/main.rs` — binary entrypoint.'                    "$RO" || fail "rust: missing //! doc-comment role"
grep -qF -- '- `src/main.rs` → `crate::config::load`, `mod config`'   "$RO" || fail "rust: missing use/mod import edges"
grep -qF -- '- `RUST_ENDPOINT` → `src/config.rs`'                     "$RO" || fail "rust: missing env::var key"
guardrails "$RO"; determinism "$R" "$RO"; ok
echo "PASS rust project map"

# ══ JAVA ════════════════════════════════════════════════════════════════════════════════════════
J="$T/java"; mkdir -p "$J/src/com/demo"
printf '<project></project>\n' > "$J/pom.xml"
cat > "$J/src/com/demo/App.java" <<'EOF'
// App.java — application entrypoint.
package com.demo;

import com.demo.Config;

public class App {
    public static void main(String[] a) { System.out.println(new Config().get()); }
}
EOF
cat > "$J/src/com/demo/Config.java" <<'EOF'
// Config.java — reads settings from the environment.
package com.demo;

public class Config {
    public String get() { return System.getenv("JAVA_HOME_X"); }
}
EOF
JO="$T/java.md"; gen "$J" "$JO"
head -1 "$JO" | grep -qF -- '# java codemap'                          || fail "java: wrong title"
grep -qF -- '- `src/com/demo/App.java` — application entrypoint.'     "$JO" || fail "java: missing module role"
grep -qF -- '- `src/com/demo/App.java` → `com.demo.Config`'           "$JO" || fail "java: missing declared-package import edge"
grep -qF -- '- `JAVA_HOME_X` → `src/com/demo/Config.java`'            "$JO" || fail "java: missing System.getenv key"
guardrails "$JO"; determinism "$J" "$JO"; ok
echo "PASS java project map"

# ══ UNKNOWN language — graceful, deterministic, still project mode ══════════════════════════════
U="$T/unknown"; mkdir -p "$U"; printf 'hello\n' > "$U/README.txt"
UO="$T/unknown.md"; gen "$U" "$UO"
grep -qF -- 'No recognized source tree detected'  "$UO" || fail "unknown: missing graceful no-source notice"
grep -qF -- '## Who sources whom'                 "$UO" && fail "unknown: leaked engine section"
guardrails "$UO"; determinism "$U" "$UO"; ok
echo "PASS unknown-language graceful map"

# ══ GRAPHIFY ENRICHMENT (optional, fail-soft) ═══════════════════════════════════════════════════
# A file→file `imports` edge graphify resolves that the native relative-specifier scan would NOT
# (n_index → n_util). It must surface ONLY when GRAPHIFY_BIN resolves AND graph.json exists.
mkdir -p "$N/graphify-out"
cat > "$N/graphify-out/graph.json" <<'EOF'
{
  "nodes": [
    {"id": "n_index", "source_file": "src/index.js", "metadata": {"kind": "file"}},
    {"id": "n_util",  "source_file": "src/util.js",  "metadata": {"kind": "file"}},
    {"id": "n_ext",   "label": "lodash",             "metadata": {"kind": "module"}}
  ],
  "links": [
    {"source": "n_index", "target": "n_util", "relation": "imports"},
    {"source": "n_index", "target": "n_ext",  "relation": "imports"},
    {"source": "n_index", "target": "n_index", "relation": "imports"}
  ]
}
EOF
STUB="$T/graphify-stub"; printf '#!/bin/sh\nexit 0\n' > "$STUB"; chmod +x "$STUB"
if command -v python3 >/dev/null 2>&1; then
  NG="$T/node-graphify.md"; gen "$N" "$NG" "GRAPHIFY_BIN=$STUB"
  grep -qF -- '### graphify-enriched cross-file edges'  "$NG" || fail "graphify: enrichment subsection missing when resolvable"
  grep -qF -- '- `src/index.js` → `src/util.js`'        "$NG" || fail "graphify: file→file edge missing"
  grep -qF -- 'src/index.js` → `lodash'                 "$NG" && fail "graphify: leaked a non-file (module) edge"
  guardrails "$NG"
  # determinism WITH the same graphify inputs (the generic helper regenerates without them).
  NG2="$T/node-graphify2.md"; gen "$N" "$NG2" "GRAPHIFY_BIN=$STUB"
  cmp -s "$NG" "$NG2" || fail "graphify: enriched map is non-deterministic"
  # Fail-soft WITHOUT graph.json: even with GRAPHIFY_BIN resolvable, no graph.json → no enrichment
  # and the map is byte-identical to the plain (no-graphify) run.
  rm -rf "$N/graphify-out"
  NN="$T/node-nograph.md"; gen "$N" "$NN" "GRAPHIFY_BIN=$STUB"
  grep -qF -- '### graphify-enriched' "$NN" && fail "graphify: enriched with no graph.json present (not fail-soft)"
  cmp -s "$NO" "$NN" || fail "graphify: resolvable binary but no graph.json changed the plain map"
  ok
  echo "PASS graphify enrichment (present + fail-soft without graph.json)"
else
  rm -rf "$N/graphify-out"
  echo "SKIP graphify enrichment (python3 not installed)"
fi

# ══ ENGINE MODE — byte-identical on a frozen fixture engine tree ════════════════════════════════
# A minimal tree carrying the engine SIGNATURE (bin/herd + scripts/herd/codemap.sh +
# templates/capabilities.tsv) must be auto-detected as ENGINE and rendered with the historical
# engine shapes ("Who sources whom", config-key list from capabilities.tsv) — NOT the project shapes.
E="$T/engine"; mkdir -p "$E/bin" "$E/scripts/herd" "$E/templates"
cat > "$E/bin/herd" <<'EOF'
#!/usr/bin/env bash
# herd — tiny fixture CLI.
:
EOF
cat > "$E/scripts/herd/herd-config.sh" <<'EOF'
#!/usr/bin/env bash
# herd-config.sh — fixture loader.
: "${FIX_KEY:=default}"
EOF
cat > "$E/scripts/herd/codemap.sh" <<'EOF'
#!/usr/bin/env bash
# codemap.sh — fixture stub (only needed for the engine signature).
:
EOF
cat > "$E/scripts/herd/alpha.sh" <<'EOF'
#!/usr/bin/env bash
# alpha.sh — the alpha module.
. "$HERE/herd-config.sh"
echo "$FIX_KEY"
EOF
printf 'name\tkind\tdescription\twhen_to_surface\nFIX_KEY\tconfig\tA fixture key\tWhen fixture\n' \
  > "$E/templates/capabilities.tsv"
EO="$T/engine.md"; gen "$E" "$EO"
head -1 "$EO" | grep -qF -- '# herdkit codemap'           || fail "engine: wrong title (mode not engine): $(head -1 "$EO")"
grep -qF -- '## Who sources whom'    "$EO"                || fail "engine: missing engine 'sources whom' section"
grep -qF -- '## Who imports whom'    "$EO"                && fail "engine: leaked the PROJECT 'imports whom' section"
grep -qF -- '- `alpha.sh` — the alpha module.'  "$EO"    || fail "engine: missing module role"
grep -qF -- '- `alpha.sh` → `herd-config.sh`'   "$EO"    || fail "engine: missing source edge"
grep -qF -- '- `FIX_KEY` → `alpha.sh`'          "$EO"    || fail "engine: missing config-key → consumer"
guardrails "$EO"; determinism "$E" "$EO"; ok
echo "PASS engine-mode byte-identical (frozen fixture)"

# The REAL herdkit repo must still map as ENGINE (HERD-79 did not flip it to project mode). No
# HERD_CODEMAP_ROOT override → the default resolution picks the engine repo this script ships in.
RO_REAL="$T/real.md"
HERD_CODEMAP_OUT="$RO_REAL" bash "$CODEMAP" </dev/null >/dev/null 2>&1 || fail "real-repo codemap failed"
head -1 "$RO_REAL" | grep -qF -- '# herdkit codemap' || fail "real repo no longer maps as ENGINE"
grep -qF -- '## Who sources whom' "$RO_REAL"          || fail "real repo lost its engine 'sources whom' section"
ok
echo "PASS real herdkit repo still maps as ENGINE"

echo "PASS ($pass assertions)"
