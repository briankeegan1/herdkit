#!/usr/bin/env bash
# test-cli-symlink.sh — hermetic test that `herd` works when installed via the documented
# symlink (ln -s .../bin/herd /somewhere/bin/herd) and invoked through that symlink from a
# cwd OUTSIDE the repo. Regression for: HERDKIT_HOME computed from $0/BASH_SOURCE without
# resolving symlinks → SCRIPTS_DIR resolved to the SYMLINK's prefix → sourcing
# scripts/herd/herd-config.sh dies "No such file or directory". No network, no claude.
# Run:  bash tests/test-cli-symlink.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
HERD="$HERE/../bin/herd"
REAL_HOME="$(cd "$HERE/.." && pwd)"
fail(){ echo "FAIL: $1" >&2; exit 1; }

# Sanity: home we expect the CLI to resolve to.
[ -f "$REAL_HOME/scripts/herd/herd-config.sh" ] || fail "test bug: real herd-config.sh missing"

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT

# A real project with a .herd/config, so a subcommand proceeds to source herd-config.sh
# (subcommands die early on a missing config — we need to get PAST that to the source line).
proj="$T/project"; mkdir -p "$proj"
git -C "$proj" init -q
git -C "$proj" config user.email t@t.t; git -C "$proj" config user.name t
( cd "$proj" && git commit -q --allow-empty -m init )
( cd "$proj" && HERD_NONINTERACTIVE=1 bash "$HERD" init >/dev/null ) || fail "herd init failed"
[ -f "$proj/.herd/config" ] || fail "init did not write .herd/config"

# The documented install: a symlink to the repo's bin/herd, in a prefix OUTSIDE the repo.
prefix="$T/opt/bin"; mkdir -p "$prefix"
ln -s "$HERD" "$prefix/herd"

# Invoke through the symlink, from inside the (out-of-repo) project. `backlog` sources
# $SCRIPTS_DIR/herd-config.sh — the exact line the unresolved-symlink bug blew up on.
out="$( cd "$proj" && "$prefix/herd" backlog 2>&1 )" || true

# Must NOT have resolved SCRIPTS_DIR to the symlink's prefix, and must NOT have failed to
# source herd-config.sh (both are signatures of home == symlink dir instead of real home).
printf '%s\n' "$out" | grep -q "$prefix/scripts/herd" \
  && fail "SCRIPTS_DIR resolved to the symlink prefix instead of real home: $out"
printf '%s\n' "$out" | grep -q "$T/scripts/herd" \
  && fail "SCRIPTS_DIR resolved under the symlink tree instead of real home: $out"
printf '%s\n' "$out" | grep -q "herd-config.sh: No such file or directory" \
  && fail "could not source herd-config.sh from real home (symlink not resolved): $out"
printf '%s\n' "$out" | grep -q "No such file or directory" \
  && fail "symlinked invocation errored on a missing file (wrong home): $out"

echo "ALL PASS"
