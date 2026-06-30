#!/usr/bin/env bash
# test-leakguard.sh — hermetic test of the single-consumer leak-guard: the scan that fails the
# healthcheck if a single-consumer (Northstar) literal leaks into herdkit's generic engine surface
# (scripts/herd + bin/herd + templates). Builds fake engine trees in a temp dir; no network. Run:
#     bash tests/test-leakguard.sh
# This mirrors the leak-guard step in .herd/healthcheck.project.sh (kept in lockstep with it).
set -euo pipefail

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
pass=0
fail(){ echo "FAIL: $1" >&2; exit 1; }
ok(){ pass=$((pass+1)); }

# leak_scan ROOT — the leak-guard logic, identical to the healthcheck step. Exits 0 if a
# single-consumer literal leaked (a "trip"), 1 if the tree is clean. The "$HOME/source/myproject"
# generic placeholder is allowed; every other $HOME/source/ path is a leak.
leak_scan() {
  local root="$1"
  local leak_pat='northstar|/Users/macbookpro|\$HOME/source/|streamlit|app/dashboard\.py'
  local files=()
  while IFS= read -r f; do [ -n "$f" ] && files+=("$f"); done < <(
    { find "$root/scripts/herd" -type f 2>/dev/null
      [ -f "$root/bin/herd" ] && echo "$root/bin/herd"
      find "$root/templates" -type f 2>/dev/null; } | sort -u
  )
  [ "${#files[@]}" -gt 0 ] || return 1
  grep -HinE "$leak_pat" "${files[@]}" 2>/dev/null | grep -vE '\$HOME/source/myproject' >/dev/null
}

# A minimal, clean fake engine tree.
make_clean_tree() {
  local r="$1"
  mkdir -p "$r/scripts/herd/backends" "$r/bin" "$r/templates"
  printf '#!/usr/bin/env bash\necho "generic engine"\n'            > "$r/scripts/herd/coordinator.sh"
  printf '#!/usr/bin/env bash\n_backend_add_item(){ :; }\n'        > "$r/scripts/herd/backends/file.sh"
  printf '#!/usr/bin/env bash\necho herd\n'                        > "$r/bin/herd"
  # the documented generic placeholder — must NOT trip the guard
  printf 'PROJECT_ROOT="$HOME/source/myproject"\nWORKTREES_DIR="$HOME/source/myproject-trees"\n' \
    > "$r/templates/config.example"
}

# 1. A planted single-consumer literal in scripts/herd/foo.sh TRIPS the guard.
make_clean_tree "$T/leaky"
printf '#!/usr/bin/env bash\n# wire up the northstar dashboard\n' > "$T/leaky/scripts/herd/foo.sh"
if leak_scan "$T/leaky"; then ok; else fail "guard did not trip on planted 'northstar' literal"; fi

# 1b. Other single-consumer literals also trip (streamlit, app/dashboard.py, hardcoded home path).
for lit in 'run streamlit run' 'open app/dashboard.py' 'cd /Users/macbookpro/source/northstar'; do
  make_clean_tree "$T/leaky2"
  printf '#!/usr/bin/env bash\n# %s\n' "$lit" > "$T/leaky2/scripts/herd/bar.sh"
  if leak_scan "$T/leaky2"; then ok; else fail "guard did not trip on literal: $lit"; fi
  rm -rf "$T/leaky2"
done

# 2. A clean fake tree (with only the generic "$HOME/source/myproject" placeholder) PASSES.
make_clean_tree "$T/clean"
if leak_scan "$T/clean"; then fail "guard tripped on a clean tree (generic placeholder)"; else ok; fi

# 3. A leak planted in bin/herd and in templates/ is also caught.
make_clean_tree "$T/leaky3"
printf '#!/usr/bin/env bash\nopen app/dashboard.py\n' > "$T/leaky3/bin/herd"
if leak_scan "$T/leaky3"; then ok; else fail "guard did not catch leak in bin/herd"; fi

make_clean_tree "$T/leaky4"
printf 'PROJECT_ROOT="$HOME/source/northstar"\n' > "$T/leaky4/templates/config.example"
if leak_scan "$T/leaky4"; then ok; else fail "guard did not catch non-generic \$HOME/source/ path in templates"; fi

echo "ALL PASS ($pass checks)"
