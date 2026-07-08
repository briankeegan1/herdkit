# herdkit on Windows

**WSL2 is the supported way to run herdkit on Windows — and the only one we recommend.**

herdkit is a bash engine with deep Unix assumptions (a POSIX shell, `python3` at the usual
locations, a UTF-8 locale, real ttys). Native **Git Bash** diverges from all of these enough that
we no longer recommend it: it works for the core CLI in a pinch, but the full workflow is spotty.
Run herdkit under **WSL2 (Ubuntu)**, where it behaves exactly as on Linux.

> The CI matrix reflects this: the `ubuntu` leg **is** the Windows/WSL2 coverage (WSL2 semantics
> are Linux semantics), and the `windows` leg is a small advisory smoke, not a full-suite gate.

---

## Setup (WSL2 — the supported path)

From an elevated PowerShell:

```powershell
wsl --install -d Ubuntu
```

Reboot if prompted, launch **Ubuntu** from the Start menu, then inside the WSL2 shell run the
**standard Linux quickstart** — nothing Windows-specific:

```bash
# one-command install (clones to ~/.herdkit, wires PATH, runs the dependency doctor)
curl -fsSL https://raw.githubusercontent.com/briankeegan1/herdkit/main/install.sh | bash

# then, from the project you want to herd:
cd your-project
herd init
herd doctor      # verify git, gh (+auth), claude, python3
```

Keep your repos on the Linux filesystem (`~/…` inside WSL2), not `/mnt/c/…`, for correct
permissions and speed.

---

## What works today in WSL2 — an honest status

WSL2 is the **direction** and the supported Windows path. Not every surface is feature-complete
inside it yet; here is the accurate picture as of 2026-07-08.

### The headless automation runs today

Set `HERD_DRIVER=headless` in `.herd/config`. In this mode the **load-bearing automation runs with
no herdr panes at all** — the watcher's merge gating, the engine journal, notifications, and
usage-limit detection all work headless, and **builder** agents run detached. This is the part of
herdkit that actually merges PRs, and it works in WSL2 today (see
[`templates/drivers/headless.driver`](../templates/drivers/headless.driver) and
[`docs/macos-unattended-permissions.md`](docs/macos-unattended-permissions.md) for the headless
model).

### Two things are still herdr-bound — tracked, not yet done

1. **The full control-room *view* (herdr panes/tabs) needs a Linux `herdr` build.** herdkit drives
   the [`herdr`](../README.md) terminal multiplexer for its live cockpit. This repo does not ship or
   reference a Linux `herdr` binary, so **the full paneled control room in WSL2 is pending a herdr
   Linux build.** Until then, use the headless driver above — the cockpit is an optional *view*, not
   a dependency.

2. **Six coordinator-side lanes still shell out to `herdr agent start`.** Per
   [`docs/audit-2026-07-06.md`](audit-2026-07-06.md) **finding D1**, the `coordinator`, `resolver`,
   `reviewer`, `scribe`, `researcher`, and `fleet` lanes hardcode `herdr agent start … -- claude`,
   so under `HERD_DRIVER=headless` today they still require herdr — only **builders** are fully
   paneless. Routing those six launch sites through `driver.sh start-agent` (the registry and
   fail-soft semantics already exist) is the tracked follow-up that closes the headless/WSL2 gap.

**In short:** WSL2 is the only supported Windows path; the headless watcher + builders work there
now; full feature-completeness inside WSL2 is gated on a Linux `herdr` build and audit finding D1,
both tracked as engine items — not claims of current fact.

---

## Verify your setup

```bash
herd doctor                       # one-pass dependency check with per-platform install hints
bash scripts/ci/run-suite.sh      # run the hermetic suite the way CI does
```

`herd doctor` reports every missing/broken dependency at once and (on a missing `herdr`) points
Windows users at WSL2.

---

## Appendix — Git Bash (unsupported / best-effort)

> Native Git Bash is **not supported**. It has no `python3`, a non-UTF-8 default locale, and no real
> tty for the cockpit — divergences that make the hermetic suite structurally red under Git Bash
> (the concrete tests are catalogued in
> [`tests/known-env-sensitive.tsv`](../tests/known-env-sensitive.tsv)). If you cannot use WSL2, the
> fixes below get the **core CLI** working best-effort. Prefer WSL2.

**1. Line endings — handled by `.gitattributes`.** A CRLF checkout breaks bash (a trailing `\r`
rides every shebang), sourced `*.driver` bindings, and the exact-literal greps over `*.tsv`. The
repo's [`.gitattributes`](../.gitattributes) forces `eol=lf` on all engine files, so a fresh clone
is correct regardless of `core.autocrlf`. If you cloned before it landed:
`git add --renormalize .`.

**2. `python3` shim — Git Bash ships none.** herdkit and `herd doctor` call `python3`:

```bash
mkdir -p ~/bin
printf '#!/usr/bin/env bash\nexec python "$@"\n' > ~/bin/python3   # or: exec py "$@"
chmod +x ~/bin/python3
export PATH="$HOME/bin:$PATH"        # add to ~/.bashrc to persist
```

Tests that rebuild a minimal `PATH` as `/usr/bin:/bin` still can't see it (that path has no Windows
Python) — those are the Git-Bash XFAIL set in `tests/known-env-sensitive.tsv`. WSL2 avoids the
problem entirely.

**3. `LANG=C.UTF-8` — for the emoji greps.** Surfaces grep for `✅ ❌ 🟢`; a non-UTF-8 locale breaks
the match:

```bash
echo 'export LANG=C.UTF-8'   >> ~/.bashrc
echo 'export LC_ALL=C.UTF-8' >> ~/.bashrc
```

**4. Terminal / cockpit.** The herdr paneled cockpit is a Unix-terminal surface and is not the
Windows path at all — use `HERD_DRIVER=headless` (above), which runs the load-bearing pipeline with
no panes.
