#!/usr/bin/env bash
# tests/test-sandbox-posture-matrix-data.sh — POSTURE DATA proof for the posture matrix (HERD-477
# split of HERD-153's test-sandbox-posture-matrix.sh). Asserts templates/postures.tsv defines exactly
# the eight canonical postures with the expected config keys, and posture-lib.sh reads them.
#
# This is the ONE data-shape check shared by every tests/test-sandbox-posture-matrix-<posture>.sh file
# (tests/lib/sandbox-posture-matrix-case.sh) — it runs no scenario, so it costs nothing to keep it in a
# single file rather than duplicating it eight times over.
#
# Fully hermetic: reads templates/postures.tsv only, no herdr/network/model.
# Run:  bash tests/test-sandbox-posture-matrix-data.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
POSTURES="$HERE/../templates/postures.tsv"
PLIB="$HERE/../scripts/herd/sim/posture-lib.sh"

fail(){ echo "FAIL: $1" >&2; exit 1; }
[ -f "$POSTURES" ] || fail "missing $POSTURES"
[ -f "$PLIB" ]     || fail "missing $PLIB"

# shellcheck source=/dev/null
. "$PLIB"
POSTURES_FILE="$POSTURES"

_names="$(posture_names | tr '\n' ' ')"
for p in solo-auto team-approve gated-push custom-steps observe-only full-auto docs-lab yolo; do
  case " $_names " in *" $p "*) : ;; *) fail "postures.tsv missing posture: $p" ;; esac
done
case "$(posture_keys full-auto)" in *MERGE_POLICY=auto*) : ;; *) fail "full-auto must set MERGE_POLICY=auto" ;; esac
[ "$(posture_keys team-approve)" = "MERGE_POLICY=approve HUMAN_VERIFY_POLICY=hold" ] \
  || fail "team-approve keys wrong: $(posture_keys team-approve)"
[ "$(posture_keys observe-only)" = "MERGE_POLICY=observe" ] || fail "observe-only keys wrong"
case "$(posture_keys gated-push)" in *PUSH_GATE=human*) : ;; *) fail "gated-push must set PUSH_GATE=human" ;; esac
[ "$(posture_steps_profile custom-steps)" = "approve-stage" ] || fail "custom-steps STEPS_PROFILE wrong"
# docs-lab (HERD-409/#520): a docs/research-lab bundle — cheap docs review tier + lighter models.
case "$(posture_keys docs-lab)" in *MERGE_POLICY=auto*) : ;; *) fail "docs-lab must set MERGE_POLICY=auto" ;; esac
case "$(posture_keys docs-lab)" in *DOCS_ONLY_GLOB=*)   : ;; *) fail "docs-lab must set DOCS_ONLY_GLOB" ;; esac
case "$(posture_keys docs-lab)" in *MODEL_FEATURE=*)    : ;; *) fail "docs-lab must set MODEL_FEATURE" ;; esac
case "$(posture_keys docs-lab)" in *MODEL_REVIEW=*)     : ;; *) fail "docs-lab must set MODEL_REVIEW" ;; esac
# yolo (HERD-466): the all-auto-levers drain posture. It must stay auto-merge AND keep the audit
# trail — a yolo that turns TRACKED_SPAWNS/CLAIM_REQUIRED off would be off-book, not just fast.
case "$(posture_keys yolo)" in *MERGE_POLICY=auto*)          : ;; *) fail "yolo must set MERGE_POLICY=auto" ;; esac
case "$(posture_keys yolo)" in *COORDINATOR_AUTONOMY=full*)  : ;; *) fail "yolo must set COORDINATOR_AUTONOMY=full" ;; esac
case "$(posture_keys yolo)" in *TRACKED_SPAWNS=required*)    : ;; *) fail "yolo must keep TRACKED_SPAWNS=required" ;; esac
case "$(posture_keys yolo)" in *CLAIM_REQUIRED=on*)          : ;; *) fail "yolo must keep CLAIM_REQUIRED=on" ;; esac

echo "PASS postures.tsv defines the eight canonical postures; posture-lib reads their keys"
echo "ALL PASS (data)"
