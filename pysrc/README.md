# `pysrc/` — the herdkit engine, ported to Python (EPIC HERD-300)

This tree holds the **stdlib-only** Python package that the engine core migrates into, one seam
at a time, under the strangler plan in [`docs/spikes/engine-port-python.md`](../docs/spikes/engine-port-python.md).

## Layout (this is the packaging story P1 proves)

```
pysrc/                     added to PYTHONPATH; the import root
  herd/                    the engine package (import name: herd)
    __init__.py            package marker + the port contract
    why.py                 `herd why <pr#>`  reader   →  python3 -m herd.why
    log.py                 `herd log` formatter        →  python3 -m herd.log
    cost.py                `herd cost` reader          →  python3 -m herd.cost
    status.py              `herd status` FORMAT stage  →  python3 -m herd.status
```

Each command is a **submodule run as a script** (`python3 -m herd.<cmd>`), keeping the existing
`herd` CLI names. `bin/herd` derives the import root from its own install location
(`HERDKIT_HOME/pysrc`) and prepends it to `PYTHONPATH`, so no install step is required — `python3`
is already a hard engine dependency and **no external packages are added**.

## What is ported in P1 (HERD-302)

The three **read-only journal readers** — `why`, `log`, `cost`. They are pure READERS: they open
journal files read-only and print, with **zero mutation** of any state. `bin/herd` still resolves
`.herd/config`, the journal paths, and (for `cost --full`) the live-scan lines in bash exactly as
before, then hands them to these modules via stdin + environment variables — so each module
receives byte-for-byte the same input the historical inline `python3 -c` program did.

## What is ported in P1b (HERD-307): `herd status`, via a gather/format split

`herd status` is a **live-environment snapshot** (watcher liveness, `gh`, the herdr driver seam,
theme colours, timing-based duplicate detection), not a journal reader — so it cannot be ported
wholesale like the readers. Instead it is split at a **stable serialization seam**:

- **GATHER** (`scripts/herd/status.sh` → `_status_gather`) runs every live probe, does all
  classification, and emits ONE colour-resolved, `\x1f`-delimited snapshot. This is the only stage
  that touches the live environment, so it deliberately gets **no golden**.
- **FORMAT** consumes that snapshot and renders the report. Two byte-identical implementations exist:
  `pysrc/herd/status.py` (preferred) and the historical bash `_status_format_bash` (the fail-soft
  fallback, kept in place). Both read the **same** snapshot, so output cannot fork.

`_status_run` wires them: gather once into a rewindable temp file, then format via Python, falling
back to bash on `HERD_ENGINE_PY=0` or any import/exec failure (empty output). The palette flows
through the snapshot's `COLORS` record — resolved from `HERD_THEME` by `cmd_status` exactly as
before — so the colour seam is honoured identically on both paths. The exit contract (non-zero when
something needs attention) rides the snapshot's `ATTENTION` field, so both formatters agree.

Because the FORMAT stage is pure over the snapshot, it **can** be golden-tested even though the live
probes cannot: committed snapshot fixtures under `tests/fixtures/status/` are formatted both ways and
cmp'd byte-identical (incl. exit codes). The live-probe gather paths get no golden — that is the
point of the split.

## The fail-soft contract

`bin/herd` routes each ported command to its module, but **keeps the inline `python3 -c` program**
as a byte-identical fallback. If the package fails to import — or a module exits nonzero with no
output — the CLI silently runs the builtin instead, emitting at most a one-line stderr notice and
**never a red row** (`AGENTS.md` → *Fail-soft*). The module source and the inline fallback are the
*same program*, so output is identical either way. `HERD_ENGINE_PY=0` forces the builtin path.

Because the fallback must exist, the bash bodies are **not deleted** in this PR (a `set -e`-safe
reader can't fall back to a function it deleted). Retiring the inline fallback is a deliberate
follow-up once the port is trusted across projects.

## Testing

`tests/test-py-readers.sh` (wired into `tests/herd.bats`) is the golden **parity** suite: on a
fixture journal it drives the real `bin/herd` both ways (`HERD_ENGINE_PY=1` vs `0`) across every
ported output mode and asserts byte-for-byte identical stdout + exit code, plus the fail-soft
fallback behavior. For `herd status` it drives the FORMAT stage both ways over the committed snapshot
fixtures via the `HERD_STATUS_SNAPSHOT_FILE` seam (which skips gather). `HERD_PYSRC` is an env
override used only by that test to point at a broken tree; `HERD_STATUS_SNAPSHOT_FILE` names a
snapshot to format directly instead of gathering one — both are test-only seams, not config keys.
