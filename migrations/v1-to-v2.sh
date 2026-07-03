#!/usr/bin/env bash
# migrations/v1-to-v2.sh — engine contract v1 → v2.
#
# Contract change: MERGE_POLICY is the primary merge-gate lever; the older WATCHER_AUTOMERGE boolean
# is legacy (kept only for backwards compatibility with pre-v1 configs — see templates/capabilities.tsv).
# A pre-MERGE_POLICY config that only carries WATCHER_AUTOMERGE inherits an EXPLICIT MERGE_POLICY so
# the consumer's merge behavior is preserved once the fallback goes away.
#
# Invoked by the herd upgrade migration runner (bin/herd: run_migrations) as:
#     bash migrations/v1-to-v2.sh <project-root>
# The runner exports HERD_CONFIG plus the _config_file_value / _config_put_value helpers. This is a
# TARGETED, IDEMPOTENT edit: it only adds MERGE_POLICY when absent, never removes WATCHER_AUTOMERGE
# or any custom key, and never touches DENY_PATHS / .herd/secrets. Exit 0 on success, non-zero on an
# unresolvable conflict (escalates to a human via the runner's rollback).
set -euo pipefail

root="${1:?usage: v1-to-v2.sh <project-root>}"
cfg="${HERD_CONFIG:-$root/.herd/config}"
[ -f "$cfg" ] || { echo "v1-to-v2: no .herd/config at $root" >&2; exit 1; }

# The runner exports these shared config primitives; refuse to hand-parse if they are missing.
command -v _config_file_value >/dev/null 2>&1 && command -v _config_put_value >/dev/null 2>&1 \
  || { echo "v1-to-v2: config read/write helpers not provided by the runner" >&2; exit 1; }

# Idempotent guard: if MERGE_POLICY is already pinned, this migration has nothing to do. Never
# overwrite a consumer's explicit choice.
existing="$(_config_file_value "$cfg" MERGE_POLICY)"
if [ -n "$existing" ]; then
  echo "v1-to-v2: MERGE_POLICY already set (\"$existing\") — no change"
  exit 0
fi

# Derive the explicit policy from the legacy boolean, preserving WATCHER_AUTOMERGE itself.
legacy="$(_config_file_value "$cfg" WATCHER_AUTOMERGE)"
case "$legacy" in
  true|1|yes|on)  policy=auto ;;
  false|0|no|off) policy=observe ;;
  "")             policy=auto ;;   # no legacy lever either → the engine's default
  *)              echo "v1-to-v2: unrecognised WATCHER_AUTOMERGE=\"$legacy\" — cannot map to MERGE_POLICY" >&2; exit 1 ;;
esac

_config_put_value "$cfg" MERGE_POLICY "$policy"
echo "v1-to-v2: set MERGE_POLICY=$policy (from WATCHER_AUTOMERGE=\"${legacy:-<unset>}\")"
exit 0
