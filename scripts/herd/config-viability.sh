#!/usr/bin/env bash
# config-viability.sh — EXTERNAL-CONSISTENCY PROBES (HERD-355): validate .herd/config against LIVE
# external reality — the GitHub repo's merge settings, its branch protection, and the runtime a
# driver-qualified model resolves to — catching config-vs-ENVIRONMENT mismatches that today land as
# SILENT gate failures hours later instead of at set time:
#   • MERGE_METHOD=merge while the repo DISALLOWS merge commits → 53 silent merge refusals (HERD-354)
#   • branch protection REQUIRES a `herd/gates` check the engine no longer posts (GATE_STATUS=off,
#     HERD-352) → every PR sits permanently BLOCKED on a missing required check
#   • MODEL_REVIEW=<driver>:<model> whose runtime binary is absent, or whose driver has no driveable
#     dispatch binding → the review gate stalls/INFRA-fails (HERD-311)
#
# ONE shared implementation, sourced (never executed) by BOTH surfaces so they can never disagree:
#   • `herd config set <coupled-key> <value>` — a targeted probe at write time. A PROVEN mismatch
#     REFUSES the write, naming BOTH sides; an unprovable/offline probe WARNS and proceeds.
#   • `herd doctor` — a new "Config viability (external consistency)" section that probes every
#     externally-coupled key in the effective config and reports each ✓/⚠/✗ (advisory, never a gate).
#
# THE CHECKPOINT SEAM: which keys are externally coupled — and which probe covers each — is DECLARED
# in templates/capabilities.tsv's `env_coupling` column, NOT hard-coded here. A config key with an
# empty env_coupling is skipped; a NEW externally-coupled key auto-covers itself simply by naming its
# probe token there. The probe tokens config-viability.sh implements are: merge_method, delete_branch,
# required_checks, model_driver.
#
# CONVENTIONS (mirror AGENTS.md's fail-soft doctrine):
#   • probes read LIVE external state on EVERY run — no seat-local cache that can go stale (multi-seat).
#   • fail-soft OFFLINE: a probe that cannot reach gh / read the repo WARNS, never a red, never blocks.
#   • advisory by default: only a DEFINITIVELY-read mismatch REFUSES an interactive set; everything
#     else warns. A batch apply (HERD_INIT_DEFER_APPLY=1: init / governance apply) never probes — the
#     operator runs `herd doctor` for the viability picture after a bulk configuration.
#   • zero-secret, zero-mutation: read-only `gh` calls under a hard timeout; no repo/GitHub writes.
#
# CONTRACT
#   herd_config_viability_probe <key> <value>
#       Emit ONE result line "<STATUS>\t<message>" to stdout and ALWAYS return 0. STATUS is one of:
#         OK        probe ran; config is consistent with live external reality
#         WARN      advisory divergence OR the probe degraded (offline / gh missing / unexpected shape)
#         MISMATCH  a PROVEN config-vs-reality mismatch (an interactive set REFUSES on this)
#         SKIP      the key has no env_coupling (nothing to probe) or probing is bypassed
#   herd_config_viability_doctor_section
#       Render the doctor's advisory section for every coupled key in the effective config; return 0.
#   herd_config_viability_note <key> <value> <status> <message> [source]
#       Journal a config_viability event AND refresh the machine-readable report file the coordinator
#       reads at session start. Fail-soft; always returns 0.
#
# Test seams (all optional; production is byte-identical when unset):
#   HERD_CV_GH=<cmd>               override the gh binary (hermetic stubs). Default: gh.
#   HERD_CV_REPO=<owner/name>      override repo resolution (skip `gh repo view`).
#   HERD_CV_TIMEOUT=<secs>         per-gh-call wall-clock bound (default 6).
#   HERD_SKIP_CONFIG_VIABILITY=1   bypass every probe (STATUS=SKIP), like HERD_SKIP_DOCTOR.
#   HERD_CAPABILITIES_FILE         the manifest to read env_coupling from (shared with `herd config`).
#   HERD_CONFIG_VIABILITY_REPORT   the report file path (default $WORKTREES_DIR/.herd/config-viability.json).

# Idempotence guard: sourced by bin/herd; defines functions only, no side effects at source time.
if [ -z "${HERD_CONFIG_VIABILITY_LIB:-}" ]; then
HERD_CONFIG_VIABILITY_LIB=1

_CV_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"

# _cv_caps_file — the capabilities manifest (env_coupling column lives here). Shared default with
# `herd config`; overridable for hermetic tests via HERD_CAPABILITIES_FILE.
_cv_caps_file() {
  printf '%s' "${HERD_CAPABILITIES_FILE:-${TEMPLATES_DIR:-$_CV_DIR/../../templates}/capabilities.tsv}"
}

# _cv_env_coupling <key> — the env_coupling probe token declared for KEY's kind=config row, or empty
# when the key is not externally coupled / not in the manifest. Reads the header to locate the column
# by NAME, so it is robust to column re-ordering.
_cv_env_coupling() {
  local caps; caps="$(_cv_caps_file)"
  [ -f "$caps" ] || return 0
  awk -F'\t' -v k="$1" '
    NR==1 { for (i=1;i<=NF;i++) if ($i=="env_coupling") col=i; next }
    $2=="config" && $1==k { if (col) { v=$col; gsub(/[[:space:]]+$/,"",v); print v } exit }
  ' "$caps"
}

# _cv_coupled_keys — every kind=config key that DECLARES a non-empty env_coupling, one per line.
_cv_coupled_keys() {
  local caps; caps="$(_cv_caps_file)"
  [ -f "$caps" ] || return 0
  awk -F'\t' '
    NR==1 { for (i=1;i<=NF;i++) if ($i=="env_coupling") col=i; next }
    $2=="config" && col { v=$col; gsub(/[[:space:]]+$/,"",v); if (v!="") print $1 }
  ' "$caps"
}

# _cv_gh <args...> — a read-only gh call under a hard wall-clock timeout. Honors HERD_CV_GH (test
# stub) and HERD_CV_TIMEOUT. Returns the gh exit code, or 3 when the binary is not even on PATH so a
# caller can distinguish "gh absent" from "gh ran and failed".
_cv_gh() {
  local gh="${HERD_CV_GH:-gh}" t="${HERD_CV_TIMEOUT:-6}"
  command -v "$gh" >/dev/null 2>&1 || return 3
  if command -v timeout >/dev/null 2>&1; then timeout "$t" "$gh" "$@"; return $?; fi
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$t" "$gh" "$@"; return $?; fi
  "$gh" "$@"
}

# _cv_repo — resolve the current repo as owner/name. HERD_CV_REPO overrides (tests / detached CI);
# otherwise `gh repo view`. Empty output / any failure returns non-zero so probes fail-soft to WARN.
_cv_repo() {
  if [ -n "${HERD_CV_REPO:-}" ]; then printf '%s' "$HERD_CV_REPO"; return 0; fi
  local out
  out="$(_cv_gh repo view --json nameWithOwner --jq .nameWithOwner 2>/dev/null)" || return 1
  [ -n "$out" ] || return 1
  printf '%s' "$out"
}

# _cv_json_get <json> <key> — print a top-level JSON value (a bool as true/false), empty when absent.
_cv_json_get() {
  CV_JSON="$1" CV_KEY="$2" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ["CV_JSON"])
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
v = d.get(os.environ["CV_KEY"])
if v is None:
    sys.exit(0)
print("true" if v is True else "false" if v is False else v)
' 2>/dev/null
}

# _cv_merge_allowed_list <repos-json> — the comma-joined method names the repo currently allows.
_cv_merge_allowed_list() {
  CV_JSON="$1" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ["CV_JSON"])
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
m = [("allow_merge_commit","merge"), ("allow_squash_merge","squash"), ("allow_rebase_merge","rebase")]
print(",".join(name for flag, name in m if d.get(flag) is True))
' 2>/dev/null
}

# _cv_required_check_list <branch-json> — the required-status-check contexts declared by branch
# protection, one per line. Reads the nested protection.required_status_checks (contexts + checks).
_cv_required_check_list() {
  CV_JSON="$1" python3 -c '
import os, json, sys
try:
    d = json.loads(os.environ["CV_JSON"])
except Exception:
    sys.exit(0)
if not isinstance(d, dict):
    sys.exit(0)
prot = d.get("protection") or {}
rsc = prot.get("required_status_checks") or {}
names = set(rsc.get("contexts") or [])
for c in (rsc.get("checks") or []):
    if isinstance(c, dict) and c.get("context"):
        names.add(c["context"])
for n in sorted(n for n in names if n):
    print(n)
' 2>/dev/null
}

# ── Probe: MERGE_METHOD vs the repo's allow_*_merge flags (HERD-354) ──────────────────────────────
_cv_probe_merge_method() {
  local val="$1" repo json flag allowed allowed_list
  repo="$(_cv_repo)" || { printf 'WARN\tMERGE_METHOD=%s — cannot resolve the GitHub repo (gh offline or unavailable); merge-method consistency not checked.' "$val"; return 0; }
  json="$(_cv_gh api "repos/$repo" 2>/dev/null)" || { printf 'WARN\tMERGE_METHOD=%s — could not read %s merge settings (gh offline / no access); not checked.' "$val" "$repo"; return 0; }
  case "$val" in
    merge)  flag=allow_merge_commit ;;
    squash) flag=allow_squash_merge ;;
    rebase) flag=allow_rebase_merge ;;
    *)      printf 'OK\tMERGE_METHOD=%s — no external merge-flag mapping for this value; nothing to check.' "$val"; return 0 ;;
  esac
  allowed="$(_cv_json_get "$json" "$flag")"
  allowed_list="$(_cv_merge_allowed_list "$json")"
  case "$allowed" in
    false)
      printf 'MISMATCH\tMERGE_METHOD=%s but repo %s has %s=false — the watcher'"'"'s `gh pr merge --%s` will be REFUSED by GitHub (the HERD-354 silent-merge-refusal footgun). Repo allows: %s. Fix: enable %s merges in the repo Settings→General→"Merge button", or set MERGE_METHOD to an allowed method.' \
        "$val" "$repo" "$flag" "$val" "${allowed_list:-<none>}" "$val" ;;
    true)
      printf 'OK\tMERGE_METHOD=%s — repo %s allows it (%s=true).' "$val" "$repo" "$flag" ;;
    *)
      printf 'WARN\tMERGE_METHOD=%s — repo %s did not report %s (unexpected API shape); not checked.' "$val" "$repo" "$flag" ;;
  esac
}

# ── Probe: DELETE_BRANCH_ON_MERGE vs the repo's delete_branch_on_merge default (advisory) ──────────
# The watcher passes --delete-branch per-merge when DELETE_BRANCH_ON_MERGE=true, so a repo default of
# false is NOT a hard failure — a merged branch is deleted iff EITHER side is true. Divergence is
# therefore advisory (WARN naming both sides), never a refusal.
_cv_probe_delete_branch() {
  local val="$1" repo json repo_flag want
  repo="$(_cv_repo)" || { printf 'WARN\tDELETE_BRANCH_ON_MERGE=%s — cannot resolve the GitHub repo (gh offline or unavailable); not checked.' "$val"; return 0; }
  json="$(_cv_gh api "repos/$repo" 2>/dev/null)" || { printf 'WARN\tDELETE_BRANCH_ON_MERGE=%s — could not read %s settings (gh offline / no access); not checked.' "$val" "$repo"; return 0; }
  repo_flag="$(_cv_json_get "$json" delete_branch_on_merge)"
  [ -n "$repo_flag" ] || { printf 'WARN\tDELETE_BRANCH_ON_MERGE=%s — repo %s did not report delete_branch_on_merge (unexpected API shape); not checked.' "$val" "$repo"; return 0; }
  case "$val" in true|false) want="$val" ;; *) want=false ;; esac
  if [ "$want" = "$repo_flag" ]; then
    printf 'OK\tDELETE_BRANCH_ON_MERGE=%s matches repo %s delete_branch_on_merge=%s.' "$val" "$repo" "$repo_flag"
  else
    printf 'WARN\tDELETE_BRANCH_ON_MERGE=%s diverges from repo %s default delete_branch_on_merge=%s — the watcher passes --delete-branch per-merge when true, so a merged branch is deleted iff EITHER is true (advisory). Align them to avoid a surprise.' "$val" "$repo" "$repo_flag"
  fi
}

# ── Probe: GATE_STATUS vs branch-protection required checks (HERD-352) ─────────────────────────────
# The engine posts a `herd/gates` commit status iff GATE_STATUS=on. If branch protection REQUIRES
# `herd/gates` but GATE_STATUS=off, the watcher never posts it and every PR sits permanently BLOCKED
# on the missing required check — a PROVEN mismatch. Uses the branch object (protected + nested
# protection) so an unprotected branch is a clean OK, not a 404-driven false warn.
_cv_probe_required_checks() {
  local val="$1" repo branch json protected contexts posts_gates
  repo="$(_cv_repo)" || { printf 'WARN\tGATE_STATUS=%s — cannot resolve the GitHub repo (gh offline or unavailable); required-check consistency not checked.' "$val"; return 0; }
  branch="${DEFAULT_BRANCH:-main}"; branch="${branch#origin/}"
  json="$(_cv_gh api "repos/$repo/branches/$branch" 2>/dev/null)" || { printf 'WARN\tGATE_STATUS=%s — could not read branch %s on %s (gh offline / no access); required-check consistency not checked.' "$val" "$branch" "$repo"; return 0; }
  protected="$(_cv_json_get "$json" protected)"
  posts_gates=no; [ "$val" = on ] && posts_gates=yes
  if [ "$protected" != "true" ]; then
    printf 'OK\tGATE_STATUS=%s — branch %s on %s has no protection requiring a status check; nothing to enforce against.' "$val" "$branch" "$repo"
    return 0
  fi
  contexts="$(_cv_required_check_list "$json")"
  if grep -qx 'herd/gates' <<< "$contexts"; then
    if [ "$posts_gates" = no ]; then
      printf 'MISMATCH\tGATE_STATUS=%s but branch protection on %s REQUIRES the status check `herd/gates` — the watcher only posts that check when GATE_STATUS=on, so with it off EVERY PR stays permanently BLOCKED (missing required check; the HERD-352 footgun). Fix: set GATE_STATUS=on, or remove `herd/gates` from the required checks on %s.' "$val" "$branch" "$branch"
    else
      printf 'OK\tGATE_STATUS=on and branch protection on %s requires `herd/gates` — the watcher posts it, so the gate is fail-safe across seats.' "$branch"
    fi
    return 0
  fi
  # herd/gates is not a required check.
  if [ "$posts_gates" = yes ] && [ -z "$contexts" ]; then
    printf 'OK\tGATE_STATUS=on; branch protection on %s requires no status checks (the herd/gates blessing is posted but not enforced — harmless). Pair it with a required `herd/gates` check to make the gate fail-safe (docs/governance-gates.md).' "$branch"
  else
    printf 'OK\tGATE_STATUS=%s; branch protection on %s does not require `herd/gates`.' "$val" "$branch"
  fi
}

# ── Probe: driver-qualified MODEL_* vs binary presence AND dispatch-path capability binding (HERD-311)
# Two live checks against the resolved runtime driver:
#   (1) BINARY PRESENCE — the driver's runtime binary must be on PATH for the review dispatch to launch
#       it. Absent → WARN (a per-machine provisioning gap, not a config-vs-config error; another seat
#       may have it, and MODEL_REVIEW is machine-scoped — the spawn-time HERD-282 preflight is the hard
#       gate). Reported ⚠ in the doctor so the operator sees the reviewer can't run here.
#   (2) DISPATCH-PATH CAPABILITY BINDING — the single-review + panel paths drive the model through the
#       driver's DRIVER_AGENT_ONESHOT_EXEC one-shot seam. A driver whose one-shot binding is ABSENT or
#       a @degrade: sentinel can NEVER be driven headlessly for review regardless of the machine — a
#       PROVEN, structural mismatch → MISMATCH (an interactive set refuses).
# Makes NO gh call (PATH + the shipped .driver files are the live state), so it works fully offline.
_cv_probe_model_driver() {
  local key="$1" val="$2" res drv binary binding
  [ -n "$val" ] || { printf 'OK\t%s is empty — the default driver applies; nothing to probe.' "$key"; return 0; }
  command -v herd_model_resolve >/dev/null 2>&1 || { printf 'SKIP\t'; return 0; }
  if ! res="$(herd_model_resolve "$val" 2>/dev/null)"; then
    printf 'WARN\t%s=%s does not resolve to a known <driver>:<model> ref (set-time ref validation refuses this separately); driver-capability probe skipped.' "$key" "$val"
    return 0
  fi
  drv="${res%%$'\t'*}"
  binding="$(herd_driver_agent_value DRIVER_AGENT_ONESHOT_EXEC "" "$drv" 2>/dev/null || true)"
  case "$binding" in
    ''|@degrade:*)
      printf 'MISMATCH\t%s=%s resolves to driver `%s` which has NO driveable one-shot exec binding (DRIVER_AGENT_ONESHOT_EXEC is %s) — the review dispatch path cannot run it headlessly and the gate would stall (the HERD-311 undriveable-reviewer footgun). Fix: use a driver whose one-shot exec is bound (claude/codex/grok), or a bare model id.' \
        "$key" "$val" "$drv" "${binding:-unset}"
      return 0 ;;
  esac
  binary="$(herd_driver_agent_runtime "$drv" 2>/dev/null || true)"
  if [ -n "$binary" ] && ! command -v "$binary" >/dev/null 2>&1; then
    printf 'WARN\t%s=%s resolves to driver `%s` whose runtime binary `%s` is NOT on PATH here — the pre-merge review would INFRA-fail on THIS machine until it is installed (MODEL_REVIEW is machine-scoped; the spawn-time preflight is the hard gate). Fix: install `%s`, or set %s to a bare model id.' \
      "$key" "$val" "$drv" "$binary" "$binary" "$key"
    return 0
  fi
  printf 'OK\t%s=%s — driver `%s` runtime `%s` is present and its one-shot exec is driveable.' "$key" "$val" "$drv" "${binary:-<default>}"
}

# herd_config_viability_probe <key> <value> — dispatch KEY's declared env_coupling probe. Prints one
# "<STATUS>\t<message>" line and ALWAYS returns 0; SKIP (empty message) when KEY is not coupled.
herd_config_viability_probe() {
  local key="${1:-}" val="${2:-}" token
  [ "${HERD_SKIP_CONFIG_VIABILITY:-}" = "1" ] && { printf 'SKIP\t'; return 0; }
  token="$(_cv_env_coupling "$key")"
  [ -n "$token" ] || { printf 'SKIP\t'; return 0; }
  case "$token" in
    merge_method)    _cv_probe_merge_method "$val" ;;
    delete_branch)   _cv_probe_delete_branch "$val" ;;
    required_checks) _cv_probe_required_checks "$val" ;;
    model_driver)    _cv_probe_model_driver "$key" "$val" ;;
    *)               printf 'SKIP\tunknown env_coupling probe token "%s" for %s' "$token" "$key" ;;
  esac
  return 0
}

# ── Machine-readable viability report + journal event (layer b) ───────────────────────────────────
# _cv_report_path — where the machine-readable report lands: next to the engine journal in the shared
# worktree pool ($WORKTREES_DIR/.herd/), so a coordinator on any seat reads the same live picture.
# HERD_CONFIG_VIABILITY_REPORT overrides (tests). Empty (no WORKTREES_DIR) → no destination.
_cv_report_path() {
  if [ -n "${HERD_CONFIG_VIABILITY_REPORT:-}" ]; then printf '%s' "$HERD_CONFIG_VIABILITY_REPORT"; return 0; fi
  [ -n "${WORKTREES_DIR:-}" ] || return 1
  printf '%s' "$WORKTREES_DIR/.herd/config-viability.json"
}

# _cv_report_merge <source> — read TSV rows (key<TAB>value<TAB>status<TAB>detail) on stdin and MERGE
# them into the report JSON keyed by config key, refreshing each key's live verdict. Atomic replace.
# Fail-soft: no destination / no python3 / any error just drops the update.
_cv_report_merge() {
  local path dir; path="$(_cv_report_path)" || return 0
  dir="$(dirname "$path")"
  mkdir -p "$dir" 2>/dev/null || return 0
  CV_PATH="$path" CV_SOURCE="${1:-probe}" python3 -c '
import os, sys, json, time
path = os.environ["CV_PATH"]; source = os.environ["CV_SOURCE"]
try:
    with open(path) as f:
        doc = json.load(f)
    if not isinstance(doc, dict):
        doc = {}
except Exception:
    doc = {}
res = doc.get("results")
if not isinstance(res, dict):
    res = {}
ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
for line in sys.stdin:
    line = line.rstrip("\n")
    if not line:
        continue
    parts = line.split("\t")
    if len(parts) < 4:
        continue
    k, v, st, detail = parts[0], parts[1], parts[2], parts[3]
    res[k] = {"value": v, "status": st, "detail": detail, "checked": ts, "source": source}
doc["schema"] = "herd.config_viability/1"
doc["generated"] = ts
doc["results"] = res
doc["mismatches"] = sorted(k for k, r in res.items() if r.get("status") == "MISMATCH")
tmp = path + ".tmp"
with open(tmp, "w") as f:
    json.dump(doc, f, indent=2, sort_keys=True)
    f.write("\n")
os.replace(tmp, path)
' 2>/dev/null || return 0
}

# herd_config_viability_note <key> <value> <status> <message> [source] — record ONE probe result to
# the engine journal (config_viability event) and refresh the report file. Always returns 0.
herd_config_viability_note() {
  local key="${1:-}" val="${2:-}" status="${3:-}" msg="${4:-}" source="${5:-probe}"
  [ -n "$key" ] || return 0
  if command -v journal_append >/dev/null 2>&1; then
    journal_append config_viability component config key "$key" value "$val" status "$status" detail "$msg" source "$source" 2>/dev/null || true
  fi
  printf '%s\t%s\t%s\t%s\n' "$key" "$val" "$status" "$msg" | _cv_report_merge "$source" 2>/dev/null || true
  return 0
}

# ── Doctor section (layer a, the report surface) ──────────────────────────────────────────────────
# _cv_doctor_render_rows — iterate every coupled key that resolves a value in the (already-sourced)
# effective config, probe it, print a ✓/⚠/✗ line, and record it to the report + journal. Runs inside
# the config-sourcing subshell in herd_config_viability_doctor_section, so ${!key} reads live values.
_cv_doctor_render_rows() {
  local key val out status msg any=0
  while IFS= read -r key; do
    [ -n "$key" ] || continue
    val="${!key:-}"
    out="$(herd_config_viability_probe "$key" "$val" 2>/dev/null || true)"
    status="${out%%$'\t'*}"; msg="${out#*$'\t'}"
    # Each probe message self-names the key=value, so the row prints only the marker + message.
    case "$status" in
      OK)       printf '  \xe2\x9c\x93 %s\n' "$msg"; any=1 ;;
      WARN)     printf '  \xe2\x9a\xa0 %s\n' "$msg"; any=1 ;;
      MISMATCH) printf '  \xe2\x9c\x97 %s\n' "$msg"; any=1 ;;
      *)        continue ;;
    esac
    herd_config_viability_note "$key" "$val" "$status" "$msg" doctor
  done < <(_cv_coupled_keys)
  [ "$any" -eq 1 ] || printf '  \xe2\x9c\x93 no externally-coupled config keys resolve a value in this project.\n'
  printf '  \033[2m(advisory — probes read live GitHub / PATH state each run; an offline probe warns, never blocks)\033[0m\n'
}

# herd_config_viability_doctor_section — the "Config viability (external consistency)" doctor section.
# Advisory: renders each coupled key's live verdict; NEVER changes the doctor's exit contract. Sources
# the effective config (baseline + per-user overlay) in a SUBSHELL so the probes see live values and
# WORKTREES_DIR without polluting the doctor's process. No-op when no project config / no coupled keys.
herd_config_viability_doctor_section() {
  [ "${HERD_SKIP_CONFIG_VIABILITY:-}" = "1" ] && return 0
  local caps cfg coupled overlay
  caps="$(_cv_caps_file)"; [ -f "$caps" ] || return 0
  coupled="$(_cv_coupled_keys)"; [ -n "$coupled" ] || return 0
  cfg=""
  if command -v _herd_doctor_find_config >/dev/null 2>&1; then cfg="$(_herd_doctor_find_config)"; fi
  [ -n "$cfg" ] && [ -f "$cfg" ] || return 0
  overlay="$(dirname "$cfg")/config.local"
  printf '\nConfig viability (external consistency):\n'
  (
    set +u
    # shellcheck source=/dev/null
    . "$cfg" 2>/dev/null || true
    # shellcheck source=/dev/null
    [ -f "$overlay" ] && { . "$overlay" 2>/dev/null || true; }
    _cv_doctor_render_rows
  )
  return 0
}

fi
