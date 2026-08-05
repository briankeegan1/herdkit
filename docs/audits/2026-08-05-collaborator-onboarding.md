<!-- Provenance: herdkit fleet-room session, 2026-08-05. Committed as the durable evidence base for epic HERD-517. -->

> **Date:** 2026-08-05
> **Provenance:** a live fleet-room onboarding session — an operator standing up a **clone** of
> `Chase84000/emberglen-godot` as a *collaborator*, not the project's author. Six distinct defects
> were hit before the herd ran at all. Every engine-code claim below was verified against live code
> (`file:line`) by the coordinator the same day.
> **Program:** evidence base for **HERD-517** (EPIC: collaborator onboarding for an existing herd
> project). Each finding is filed as a child item; line numbers are as of this commit.

---

# Collaborator onboarding audit — 2026-08-05

## The shape of it

A herd project **commits** `.herd/config`, and that baseline carries the author's *absolute*
`PROJECT_ROOT` and `WORKTREES_DIR`. So the moment a second person clones the project, every path the
engine resolves — lanes, watcher lock, worktree pool, journal — points into somebody else's home
directory. Nothing in the CLI said so, and nothing offered to fix it.

That single fact is the root of findings 1, 3 and 4. Findings 2, 5 and 6 are the secondary walls the
operator hit *while working around it*. The epic's goal: **`git clone` → one documented command → a
working control room, zero hand-edits.**

---

## The six findings

### 1. `herd fleet register` resolves the AUTHOR's committed path

Registering the clone recorded `/home/chase/...` as the project root. The shared reader
`_herd_read_project_config` (`scripts/herd/herd-config.sh:106`) sources **only** `$1/.herd/config` —
never the `.herd/config.local` overlay — and falls back to the register-argument path only when
`PROJECT_ROOT` is *empty*. A committed absolute path therefore always wins, however dead it is on
this machine. `herd fleet`'s thin adopter is `scripts/herd/fleet.sh:63`.
→ **HERD-518.** Source the overlay after the baseline (the main loader's order), then prefer the
argument path when the resolved root does not exist here.

### 2. `herd config set` on a watcher key HANGS with no control room

`cmd_config_set`'s change-awareness drives a full `herd reload` for any `requires=watcher` key
(`bin/herd:3236`) — and `PROJECT_ROOT`/`WORKTREES_DIR` are exactly that. On a just-cloned project
there is no watcher, no panes and no herdr socket on the other end: no timeout, no no-watcher
detection, no output. The suppression seam already existed but was private to init and governance
adoption (`HERD_INIT_DEFER_APPLY=1`, `bin/herd:942`); setting it by hand was the operator's
workaround.
→ **HERD-519(a).** Detect no-live-watcher and skip with a printed note; bound the remaining socket
calls. (`herd adopt` uses the deferral seam directly — see finding 3.)

### 3. No `adopt` / `init --existing` — localization was a manual sequence

Verified: no `cmd_adopt` and no `init --existing` anywhere in `bin/herd`. Localizing a clone meant
knowing to run two `herd config set --local` writes, `mkdir -p` the worktree pool, and add an ignore
line — a sequence nobody discovers unaided, even though the machine-scope routing and the overlay it
routes to already existed (`bin/herd:2591` scope resolution, `bin/herd:2734` overlay creation).
→ **HERD-520 — the centerpiece, closed by this PR.** `herd adopt [path]` (`bin/herd:1747`) is that
sequence: non-interactive, idempotent, overlay-only, doctor-checked.

### 4. A clone's `.gitignore` does not cover `.herd/config.local`

`herd init` only ensures the overlay is ignored on *conditional* paths — the grounding interview's
graphify accept (`bin/herd:856`). `herd fleet new` compensates unconditionally and documents the gap
in a comment (`scripts/herd/fleet.sh:240-245`), but a project stood up by plain `herd init` ships
without the rule, so the overlay shows up untracked in every collaborator's `git status` — one
`git add -A` from being committed with somebody's machine paths in it.
→ **HERD-519(b).** Make `cmd_init` ensure it unconditionally. (`herd adopt` guarantees it per
checkout via `.git/info/exclude` — see finding 6 for why not `.gitignore`.)

### 5. A herdr client/server protocol mismatch is a wall with no way through

herdr server `0.7.5` (protocol 17) against CLI `0.8.0` (protocol 19) blocked **every** socket
command, `scripts/herd/coordinator.sh` included. `herdr update --handoff` is disabled for Homebrew
installs, so the operator's only route was hand-downloading a matching release binary.
`herd-preflight.sh` does a JSON *shape* probe plus an opt-in version floor
(`scripts/herd/herd-preflight.sh:93`, `HERDR_MIN_VERSION`, default empty) — no protocol comparison
and no remediation advice, so the doctor flagged nothing actionable.
→ **HERD-521.** Detect the client/server protocol pair, print a concrete fix (restart path, exact
release-download pattern, Homebrew caveat). Advice only — never an auto-fetch of binaries.

### 6. `herd render` dirties every fresh clone

The per-machine rendered skills are kept out of git by appending to the **committed** `.gitignore`
(`bin/herd:613` and `:624`, via `_ensure_gitignored` at `:335`). Idempotent, but on a clone whose
author has not committed those lines it leaves the checkout dirty the first time anything renders —
which then reads as real dirt to the sweep, the stale-base check and the operator alike.
→ **HERD-519(c).** Route per-machine artifact ignores to `.git/info/exclude`: checkout-local, git
honors it identically, and no `git status` ever reports it. `herd adopt` already does this for the
overlay, which is why adopting a clone leaves `git status` empty.

---

## Reading across the six

Two patterns worth naming, both instances of herdkit's dominant defect shape — *a mechanism that is
correct for the author and blind to the second person*:

- **The committed/per-machine boundary is enforced on the write side but not the read side.** The
  overlay, the machine scope, and `config set --local` all exist and work. But the fleet reader
  (1) ignores the overlay, `init` (4) does not guarantee it is ignored, and `render` (6) treats a
  per-machine artifact with a committed mechanism. The layering is sound; three call sites had not
  been moved onto it.
- **Every wall was silent.** The hang (2) printed nothing, the foreign path (1) printed a plausible
  wrong answer, the protocol mismatch (5) reported a dep that was "present". A guard that reports
  clean because it is looking at the wrong surface is the failure mode, not a missing guard.
