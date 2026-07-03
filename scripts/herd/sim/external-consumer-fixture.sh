#!/usr/bin/env bash
# scripts/herd/sim/external-consumer-fixture.sh — deterministic LOCAL fixture for the
# "onboard an external consumer" abstraction audit (Phase 4).
#
# Unlike scripts/herd/sim/sandbox-fixture.sh — which seeds a repo that ALREADY looks like a herd
# consumer (a BACKLOG.md in 🔜 status-emoji format, an app/ dir, a .herd/config) — this fixture is a
# SYNTHETIC, GENERIC, NON-herdkit project: a tiny Go HTTP server with NO herdkit conventions
# whatsoever. That is the whole point. Running the init/scout/config-render logic against a repo
# that shares NONE of herdkit's own assumptions (no Python, no .venv, no app/ dir, no BACKLOG.md, no
# Python-web-dashboard framework) is what SURFACES where the engine leaks those assumptions onto a
# generic consumer.
#
# Go is chosen deliberately as the maximally-different stack from herdkit's own (bash + Python):
#   • go.mod        → scout classifies lang=go, but no Go-aware template/gate exists downstream
#   • cmd/ + internal/ layout (no app/) → the seeded ^app/ heavy/surface globs never match
#   • *.go sources  → the light healthcheck profile (bash -n / py_compile only) checks NOTHING
#   • no BACKLOG.md → init offers to create a herdkit-format BACKLOG.md the project never asked for
#   • no UI-framework widgets → the interaction-gate / AppTest wording is meaningless here
#
# DETERMINISM: fixed file contents + pinned git identity/date → a byte-identical HEAD sha every run,
# exactly like sandbox-fixture.sh, so a probe or hermetic test can reset to a known starting state.
#
# THROWAWAY: builds a LOCAL repo in a tmp dir the caller chooses. No network, no hosted repo, no
# herdr panes, no model call. Mirrors sandbox-fixture.sh's conventions (pinned identity, ownership
# marker, refuse-to-clobber guard).
#
# Usage (standalone):  bash scripts/herd/sim/external-consumer-fixture.sh <target-dir>
#                      → wipes+rebuilds <target-dir>, prints the deterministic HEAD sha.
# Usage (sourced):     . scripts/herd/sim/external-consumer-fixture.sh
#                      ext_consumer_fixture_build <target-dir>
set -uo pipefail

# ── Pinned identity so the fixture's commit sha is reproducible across runs (see sandbox-fixture.sh).
_ecf_git_env() {
  export GIT_AUTHOR_NAME="ext-consumer-sim"    GIT_AUTHOR_EMAIL="sim@consumer.local"
  export GIT_COMMITTER_NAME="ext-consumer-sim" GIT_COMMITTER_EMAIL="sim@consumer.local"
  export GIT_AUTHOR_DATE="2020-01-01T00:00:00 +0000"
  export GIT_COMMITTER_DATE="2020-01-01T00:00:00 +0000"
}

# ext_consumer_fixture_files <repo> — write the (fixed) generic Go project tree. No git. Idempotent.
# A tiny real HTTP server with a unit test. Crucially it uses the CONVENTIONAL Go layout (cmd/ +
# internal/), NOT herdkit's app/ dir, and ships NO BACKLOG.md and NO .herd/ — a truly greenfield
# external consumer.
ext_consumer_fixture_files() {
  local repo="$1"
  mkdir -p "$repo/cmd/greetd" "$repo/internal/greet"

  # go.mod — the scout signal that classifies this repo as lang=go.
  cat > "$repo/go.mod" <<'GOMOD'
module example.com/greetd

go 1.22
GOMOD

  # internal/greet/greet.go — the one real function.
  cat > "$repo/internal/greet/greet.go" <<'GOGREET'
// Package greet is the synthetic consumer's one real unit of business logic.
package greet

import "fmt"

// Greeting returns a greeting for name, defaulting to "world".
func Greeting(name string) string {
	if name == "" {
		name = "world"
	}
	return fmt.Sprintf("hello, %s!", name)
}
GOGREET

  # internal/greet/greet_test.go — the health-gate target a Go-aware healthcheck WOULD run.
  cat > "$repo/internal/greet/greet_test.go" <<'GOTEST'
package greet

import "testing"

func TestGreeting(t *testing.T) {
	if got := Greeting("herd"); got != "hello, herd!" {
		t.Fatalf("Greeting(herd) = %q", got)
	}
	if got := Greeting(""); got != "hello, world!" {
		t.Fatalf("Greeting(\"\") = %q", got)
	}
}
GOTEST

  # cmd/greetd/main.go — the HTTP server entrypoint (the "app", such as it is).
  cat > "$repo/cmd/greetd/main.go" <<'GOMAIN'
// Command greetd is a tiny HTTP greeter — the synthetic external consumer's app surface.
package main

import (
	"fmt"
	"net/http"

	"example.com/greetd/internal/greet"
)

func handler(w http.ResponseWriter, r *http.Request) {
	fmt.Fprintln(w, greet.Greeting(r.URL.Query().Get("name")))
}

func main() {
	http.HandleFunc("/", handler)
	_ = http.ListenAndServe(":8080", nil)
}
GOMAIN

  # A conventional Go README — deliberately NOT a BACKLOG.md/TODO.md/ROADMAP.md, so scout finds no
  # work-tracker file and init falls through to "create a herdkit-format BACKLOG.md".
  cat > "$repo/README.md" <<'README'
# greetd

A tiny HTTP greeter. Run `go test ./...` to check it, `go run ./cmd/greetd` to serve on :8080.
README

  cat > "$repo/.gitignore" <<'GI'
/greetd
*.out
GI
}

# ext_consumer_fixture_build <target-dir> — wipe <target-dir> and rebuild the fixture as a committed
# git repo on 'main'. Prints the deterministic HEAD sha. Resettable: byte-identical every call.
ext_consumer_fixture_build() {
  local target="$1"
  [ -n "$target" ] || { echo "ext_consumer_fixture_build: target dir required" >&2; return 1; }
  # Refuse to clobber anything that isn't ours: only wipe a path carrying our ownership marker, or a
  # non-existent/empty path. Mirrors sandbox-fixture.sh's fat-finger guard.
  if [ -e "$target" ] && [ ! -e "$target/.ext-consumer-fixture" ] && [ -n "$(ls -A "$target" 2>/dev/null)" ]; then
    echo "ext_consumer_fixture_build: refusing to wipe non-fixture dir: $target" >&2
    return 1
  fi
  rm -rf "$target"
  mkdir -p "$target"

  _ecf_git_env
  git init -q "$target"
  git -C "$target" symbolic-ref HEAD refs/heads/main
  git -C "$target" config user.name  "ext-consumer-sim"
  git -C "$target" config user.email "sim@consumer.local"
  git -C "$target" config commit.gpgsign false

  ext_consumer_fixture_files "$target"
  : > "$target/.ext-consumer-fixture"        # ownership marker (also a stable extra file)

  git -C "$target" add -A
  git -C "$target" commit -q -m "seed: synthetic external (Go) consumer fixture" \
    || { echo "ext_consumer_fixture_build: commit failed" >&2; return 1; }

  git -C "$target" rev-parse HEAD
}

# ── standalone entrypoint ───────────────────────────────────────────────────────
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
  target="${1:-}"
  [ -n "$target" ] || { echo "usage: external-consumer-fixture.sh <target-dir>" >&2; exit 1; }
  sha="$(ext_consumer_fixture_build "$target")" || exit 1
  printf 'external-consumer fixture built: %s\n' "$target"
  printf 'HEAD: %s\n' "$sha"
fi
