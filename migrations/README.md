# herdkit engine contract migrations

When the engine **contract version** (`HERD_VERSION` in a consumer's `.herd/config`) bumps from
`vN` to `vM`, `herd upgrade` inherits the breaking change by running the ordered migration scripts
in this directory — one per contract step — so the consumer's config is transformed to the new
contract **without clobbering their custom answers**.

The runner lives in `bin/herd` (`run_migrations`, wired into `cmd_upgrade`): it reads the OLD
`HERD_VERSION` (before the bump) and the target contract version, then applies every pending
migration in ascending order exactly once, idempotently, with a per-migration summary and a
rollback-safe config snapshot. When nothing is pending it is a no-op — today's upgrade behavior.

## Naming convention

```
migrations/
  v1-to-v2.sh    # one script per single contract step (N → N+1)
  v2-to-v3.sh
  ...
```

A project at `v1` upgrading to `v3` runs `v1-to-v2.sh` then `v2-to-v3.sh`, in that order. A step
with **no** script is skipped — not every version bump needs a config change.

## Migration script contract

Each script is invoked by the runner as:

```
bash migrations/vN-to-vM.sh <project-root>
```

The runner provides, via the environment:

| Provided | What it is |
|----------|------------|
| `HERD_CONFIG` | absolute path to `<project-root>/.herd/config` |
| `_config_file_value <cfg> <KEY>` | read a key's value (`''` when unset) — exported shell function |
| `_config_put_value <cfg> <KEY> <VALUE>` | idempotent, comment-preserving in-place write — exported shell function |

`_config_file_value` / `_config_put_value` are the SAME read/write primitives `herd config` uses.
**Reuse them** — never hand-parse or rewrite `.herd/config` yourself.

A migration script **MUST**:

- Make **targeted, idempotent** edits to `.herd/config` only. Re-running the script must be a safe
  no-op (guard on whether the change is already applied before writing).
- **Never** delete or overwrite a consumer's custom keys / answers — only add or rewrite the
  specific keys the contract step introduces or changes.
- **Never** touch `DENY_PATHS` or `.herd/secrets`.
- Exit `0` on success (including an already-applied no-op).
- Exit **non-zero** on an unresolvable conflict — the runner then restores the pre-upgrade config
  and aborts the whole upgrade (leaving `HERD_VERSION` un-bumped), escalating to a human.

## Example: `v1-to-v2.sh`

Adopts the primary `MERGE_POLICY` lever from the legacy `WATCHER_AUTOMERGE` boolean
(`true`→`auto`, `false`→`observe`) for pre-`MERGE_POLICY` configs, preserving `WATCHER_AUTOMERGE`
itself and doing nothing when `MERGE_POLICY` is already pinned.
