# herdkit on Windows

herdkit is a bash engine. It runs on Windows two ways:

1. **WSL2 (Ubuntu) — recommended.** A real Linux userland: `python3`, a UTF-8 locale, and
   `/usr/bin/python3` are all where the engine expects them. The hermetic suite is green here
   exactly as on Linux/macOS, and the CI matrix's WSL2-equivalent leg is `ubuntu-latest`.
2. **Git Bash (Git for Windows) — supported, best-effort.** Works for the core CLI and the
   headless driver, but three environment gaps need one-time fixes (below). The CI `windows`
   leg runs under Git Bash and is **documented-partial**: known env-only failures are marked
   XFAIL, not hacked green (see [`tests/known-env-sensitive.tsv`](../tests/known-env-sensitive.tsv)).

If you can install WSL2, do — it sidesteps every issue below. `wsl --install -d Ubuntu` from an
elevated PowerShell, then clone and run herdkit from inside the Ubuntu shell.

---

## Git Bash: the three fixes

These are grounded in a second operator's real Git Bash environment — the failure modes are
concrete, not hypothetical.

### 1. Line endings — already handled by `.gitattributes`

A CRLF checkout breaks every `*.sh` (a trailing `\r` rides the shebang → `bash\r: No such file`),
every `*.driver` (corrupts sourced KEY=value), and every `*.tsv` (breaks the exact-literal greps
the caps-sync / conformance gates rely on). The repo's [`.gitattributes`](../.gitattributes) forces
`eol=lf` on all engine files, so a fresh clone is correct regardless of your global
`core.autocrlf`. If you cloned **before** `.gitattributes` landed, renormalize once:

```bash
git rm --cached -r . >/dev/null
git reset --hard
# or, to renormalize without discarding local edits:
git add --renormalize .
```

### 2. `python3` shim — Git Bash ships no `python3`

herdkit (and `herd doctor`, and several hermetic tests that rebuild a minimal `PATH` via
`env -i … PATH=/usr/bin:/bin`) call **`python3`**. Git for Windows has no `python3` on `PATH`
even when Python is installed as `python` / `py`. Add a shim once:

```bash
# Point python3 at your real interpreter. Adjust the target to `py` if that's what you have.
mkdir -p ~/bin
printf '#!/usr/bin/env bash\nexec python "$@"\n' > ~/bin/python3
chmod +x ~/bin/python3
# Ensure ~/bin is early on PATH (add to ~/.bashrc to persist):
export PATH="$HOME/bin:$PATH"
python3 --version   # should now work
```

The CI `windows` leg installs this exact shim before running the suite. Tests that reconstruct
`PATH` as `/usr/bin:/bin` (which has no Windows Python) still can't see it and are the XFAIL set
in [`tests/known-env-sensitive.tsv`](../tests/known-env-sensitive.tsv) — WSL2 fixes them outright.

### 3. `LANG=C.UTF-8` — for the emoji greps

Many surfaces (status banners, backlog views, tests) grep for `✅ ❌ 🟢`. Under a non-UTF-8 Git
Bash locale those bytes don't match and you get spurious failures. Export a UTF-8 locale:

```bash
export LANG=C.UTF-8
export LC_ALL=C.UTF-8
# persist it:
echo 'export LANG=C.UTF-8'   >> ~/.bashrc
echo 'export LC_ALL=C.UTF-8' >> ~/.bashrc
```

The CI matrix sets `LANG=C.UTF-8` / `LC_ALL=C.UTF-8` on every leg for the same reason.

### 4. Terminal spawn — the herdr cockpit

The full herdr control room (panes/tabs) is a Unix-terminal surface and is **not** the supported
Windows path — use the **headless driver** (`HERD_DRIVER=headless` in `.herd/config`), which is
designed so every load-bearing behavior (watcher merge gating, journal, notifications, limit
detection) runs with **no herdr panes at all** (see
[`templates/drivers/headless.driver`](../templates/drivers/headless.driver)). The herdr cockpit
becomes an optional *view* you run from WSL2 or another host, not a dependency.

---

## Verify your setup

```bash
herd doctor                 # one-pass dependency check with per-platform hints
bash scripts/ci/run-suite.sh   # run the hermetic suite the way CI does
```

`herd doctor` already guards the Windows cp1252/UTF-8 case and reports every missing/broken
dependency at once with install hints. On Git Bash, expect the
[`known-env-sensitive`](../tests/known-env-sensitive.tsv) tests to report as `XFAIL` — that's
correct, not a regression. If anything **outside** that list fails, it's a real bug; please report
it.
