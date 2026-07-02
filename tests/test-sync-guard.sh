#!/usr/bin/env bash
# test-sync-guard.sh — hermetic test of the capabilities-sync guard: a PR adding a cmd_*
# subcommand, a new config key, or a new lane script without touching
# templates/capabilities.tsv must be detected. Builds temporary git repos; no network.
# Run:  bash tests/test-sync-guard.sh
#
# The guard logic here is kept in lockstep with the guard in .herd/healthcheck.project.sh.
set -euo pipefail

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# sync_guard ROOT BASE_BRANCH — mirrors the caps-sync guard in .herd/healthcheck.project.sh.
# Returns 0 if a violation is found (guard trips), 1 if the tree is clean.
sync_guard() {
  local root="$1" base="$2"
  local changed manifest_touched new_cmds new_keys new_lanes

  changed="$(git -C "$root" diff --name-only "$base" 2>/dev/null || true)"

  manifest_touched=0
  case "$changed" in *"templates/capabilities.tsv"*) manifest_touched=1 ;; esac

  if printf '%s\n' "$changed" | grep -qxE 'bin/herd'; then
    new_cmds="$(git -C "$root" diff "$base" -- bin/herd 2>/dev/null \
      | grep -E '^\+[[:space:]]*cmd_[a-z_]+\(\)' || true)"
    if [ -n "$new_cmds" ] && [ "$manifest_touched" -eq 0 ]; then
      return 0
    fi
  fi

  if printf '%s\n' "$changed" | grep -qxE 'scripts/herd/herd-config\.sh'; then
    new_keys="$(git -C "$root" diff "$base" -- scripts/herd/herd-config.sh 2>/dev/null \
      | grep -E '^\+[[:space:]]*:[[:space:]]+"?\$\{[A-Z_]+:=' || true)"
    if [ -n "$new_keys" ] && [ "$manifest_touched" -eq 0 ]; then
      return 0
    fi
  fi

  new_lanes="$(git -C "$root" diff --diff-filter=A --name-only "$base" 2>/dev/null \
    | grep -Ex 'scripts/herd/[^/]+\.sh' | grep -vxE 'scripts/herd/herd-config\.sh' || true)"
  if [ -n "$new_lanes" ] && [ "$manifest_touched" -eq 0 ]; then
    return 0
  fi

  return 1
}

# make_repo ROOT — minimal git repo with baseline engine files on branch 'main'.
# Switches to a feature branch 'feat/test' so diffs are against main.
make_repo() {
  local r="$1"
  git -C "$r" init -q
  git -C "$r" config user.email t@t.t
  git -C "$r" config user.name t
  mkdir -p "$r/scripts/herd" "$r/bin" "$r/templates"
  printf '#!/usr/bin/env bash\ncmd_existing() { :; }\n' > "$r/bin/herd"
  printf ': "${EXISTING_KEY:=val}"\n'                    > "$r/scripts/herd/herd-config.sh"
  printf 'name\tkind\tdescription\twhen_to_surface\n'   > "$r/templates/capabilities.tsv"
  git -C "$r" add -A
  git -C "$r" commit -q -m init
  git -C "$r" checkout -q -b feat/test
}

BASE="main"

# 1. New cmd_* in bin/herd WITHOUT touching the manifest → guard trips.
R="$T/r1"; mkdir "$R"; make_repo "$R"
printf '#!/usr/bin/env bash\ncmd_existing() { :; }\ncmd_newfeature() { :; }\n' > "$R/bin/herd"
git -C "$R" add bin/herd
git -C "$R" commit -q -m "add cmd_newfeature"
if sync_guard "$R" "$BASE"; then ok; else fail "guard did not trip on new cmd_* without manifest update"; fi

# 2. New cmd_* in bin/herd WITH touching the manifest → guard passes.
R="$T/r2"; mkdir "$R"; make_repo "$R"
printf '#!/usr/bin/env bash\ncmd_existing() { :; }\ncmd_newfeature() { :; }\n' > "$R/bin/herd"
printf 'name\tkind\tdescription\twhen_to_surface\nherd newfeature\tcommand\tDoes new thing\tWhen new\n' > "$R/templates/capabilities.tsv"
git -C "$R" add bin/herd templates/capabilities.tsv
git -C "$R" commit -q -m "add cmd_newfeature with manifest"
if sync_guard "$R" "$BASE"; then fail "guard tripped when manifest was updated alongside new cmd_*"; else ok; fi

# 3. New config key in herd-config.sh WITHOUT touching the manifest → guard trips.
R="$T/r3"; mkdir "$R"; make_repo "$R"
printf ': "${EXISTING_KEY:=val}"\n: "${NEW_CONFIG_KEY:=default}"\n' > "$R/scripts/herd/herd-config.sh"
git -C "$R" add scripts/herd/herd-config.sh
git -C "$R" commit -q -m "add NEW_CONFIG_KEY"
if sync_guard "$R" "$BASE"; then ok; else fail "guard did not trip on new config key without manifest update"; fi

# 4. New config key WITH touching the manifest → guard passes.
R="$T/r4"; mkdir "$R"; make_repo "$R"
printf ': "${EXISTING_KEY:=val}"\n: "${NEW_CONFIG_KEY:=default}"\n' > "$R/scripts/herd/herd-config.sh"
printf 'name\tkind\tdescription\twhen_to_surface\nNEW_CONFIG_KEY\tconfig\tA new key\tWhen new\n' > "$R/templates/capabilities.tsv"
git -C "$R" add scripts/herd/herd-config.sh templates/capabilities.tsv
git -C "$R" commit -q -m "add NEW_CONFIG_KEY with manifest"
if sync_guard "$R" "$BASE"; then fail "guard tripped when manifest was updated alongside new config key"; else ok; fi

# 5. New lane script in scripts/herd/ WITHOUT touching the manifest → guard trips.
R="$T/r5"; mkdir "$R"; make_repo "$R"
printf '#!/usr/bin/env bash\necho new-lane\n' > "$R/scripts/herd/herd-newlane.sh"
git -C "$R" add scripts/herd/herd-newlane.sh
git -C "$R" commit -q -m "add herd-newlane.sh"
if sync_guard "$R" "$BASE"; then ok; else fail "guard did not trip on new lane script without manifest update"; fi

# 6. New lane script WITH touching the manifest → guard passes.
R="$T/r6"; mkdir "$R"; make_repo "$R"
printf '#!/usr/bin/env bash\necho new-lane\n' > "$R/scripts/herd/herd-newlane.sh"
printf 'name\tkind\tdescription\twhen_to_surface\nherd-newlane.sh\tlane\tNew lane\tWhen new lane\n' > "$R/templates/capabilities.tsv"
git -C "$R" add scripts/herd/herd-newlane.sh templates/capabilities.tsv
git -C "$R" commit -q -m "add herd-newlane.sh with manifest"
if sync_guard "$R" "$BASE"; then fail "guard tripped when manifest was updated alongside new lane script"; else ok; fi

# 7. Cosmetic change to herd-config.sh (no new key) → guard passes.
R="$T/r7"; mkdir "$R"; make_repo "$R"
printf ': "${EXISTING_KEY:=val}"\n# a comment\n' > "$R/scripts/herd/herd-config.sh"
git -C "$R" add scripts/herd/herd-config.sh
git -C "$R" commit -q -m "cosmetic comment in herd-config.sh"
if sync_guard "$R" "$BASE"; then fail "guard tripped on cosmetic herd-config.sh change"; else ok; fi

# 8. New file in scripts/herd/backends/ (not a top-level lane) → guard passes.
R="$T/r8"; mkdir "$R"; make_repo "$R"
mkdir -p "$R/scripts/herd/backends"
printf '#!/usr/bin/env bash\n_backend_add_item(){ :; }\n' > "$R/scripts/herd/backends/newbackend.sh"
git -C "$R" add scripts/herd/backends/newbackend.sh
git -C "$R" commit -q -m "add new backend"
if sync_guard "$R" "$BASE"; then fail "guard tripped on scripts/herd/backends/ addition"; else ok; fi

# 9. REGRESSION: editing an existing lane script (not adding a new one) → guard passes.
R="$T/r9"; mkdir "$R"; make_repo "$R"
# Seed an existing lane on main so it's tracked before the feature branch.
printf '#!/usr/bin/env bash\necho old-content\n' > "$R/scripts/herd/agent-watch.sh"
git -C "$R" add scripts/herd/agent-watch.sh
git -C "$R" commit -q -m "add existing lane" --allow-empty
git -C "$R" checkout -q main 2>/dev/null || git -C "$R" checkout -q -b main feat/test
# Recreate properly: init on main, commit existing lane, then branch.
R="$T/r9b"; mkdir "$R"
git -C "$R" init -q
git -C "$R" config user.email t@t.t
git -C "$R" config user.name t
mkdir -p "$R/scripts/herd" "$R/bin" "$R/templates"
printf '#!/usr/bin/env bash\ncmd_existing() { :; }\n'              > "$R/bin/herd"
printf ': "${EXISTING_KEY:=val}"\n'                                > "$R/scripts/herd/herd-config.sh"
printf '#!/usr/bin/env bash\necho old-content\n'                   > "$R/scripts/herd/agent-watch.sh"
printf 'name\tkind\tdescription\twhen_to_surface\n'               > "$R/templates/capabilities.tsv"
git -C "$R" add -A
git -C "$R" commit -q -m init
git -C "$R" checkout -q -b feat/test
# Now modify the existing lane (bugfix) — NOT adding it, just editing it.
printf '#!/usr/bin/env bash\necho new-content\n'                   > "$R/scripts/herd/agent-watch.sh"
git -C "$R" add scripts/herd/agent-watch.sh
git -C "$R" commit -q -m "bugfix agent-watch.sh"
if sync_guard "$R" "$BASE"; then fail "guard tripped on edit to EXISTING lane (not an addition)"; else ok; fi

echo "ALL PASS ($pass checks)"
