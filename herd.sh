#!/usr/bin/env bash
# herd.sh — boot herdkit's own control room.
# A repo-root convenience wrapper: launch the coordinator (the 2-pane control room) for this
# checkout. Any args pass straight through to coordinator.sh.
exec bash "$(dirname "$0")/scripts/herd/coordinator.sh" "$@"
