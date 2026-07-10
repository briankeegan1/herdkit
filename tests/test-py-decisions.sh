#!/usr/bin/env bash
# test-py-decisions.sh — GOLDEN PARITY tests for the P2 pure decision core (HERD-303, EPIC HERD-300).
#
# P2 ports the watcher's PURE decision logic to stdlib Python (pysrc/herd/decisions.py): the
# merge-policy resolver, the merge-decision helper (_hold_decision), and the refix-budget
# arithmetic (per-rail budgets review/health/stale/ci, refund-on-green via sha-keyed reset rows,
# the lifetime total that ignores resets, and the derived 3× total ceiling). The bash watcher keeps
# its implementation UNCHANGED — this test proves the two agree, decision-for-decision, on identical
# inputs. That parity harness is what P3's shadow-mode state machine builds on.
#
# ONE ARGV, TWO IMPLEMENTATIONS, ONE PROCESS EACH. A fixture-table of cases is written once; then:
#   • BASH  — a harness sources scripts/herd/agent-watch.sh in LIB MODE (AGENT_WATCH_LIB=1 returns
#     right after the function defs, before the watch loop) EXACTLY ONCE, then reads every case from
#     stdin, re-applies that case's knobs (REFIX_STATE / REFIX_MAX_ROUNDS / MERGE_POLICY /
#     WATCHER_AUTOMERGE — the config load would otherwise clobber them), and calls the REAL functions.
#     No copy of the bash logic lives here, so it cannot drift.
#   • PYTHON — `python3 -m herd.decisions --batch` reads the SAME case stream in one process and calls
#     the pure functions.
# Both emit one line per case; we diff the two streams. (Sourcing the 12k-line watcher per case is
# far too slow — batching keeps the whole suite to two interpreter starts.)
#
# The refix WRITERS (record_refix / refix_rail_reset — impure: append with a live timestamp + journal)
# are intentionally NOT ported and NOT tested here; the fixtures ARE the exact ledger rows those
# writers would produce (bounce: "<epoch> <pr> <sha> <slug> <kind>"; reset: "... <kind> reset").
#
# Fully hermetic + stdlib-only: no journal/watcher/panes/gh/network/HOME touched, no external python
# deps (python3 stdlib only — the P1 packaging rule). Run:  bash tests/test-py-decisions.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO="$(cd "$HERE/.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FAIL: python3 required" >&2; exit 1; }
[ -f "$REPO/scripts/herd/agent-watch.sh" ] || { echo "FAIL: agent-watch.sh missing" >&2; exit 1; }
[ -f "$REPO/pysrc/herd/decisions.py" ]     || { echo "FAIL: pysrc/herd/decisions.py missing" >&2; exit 1; }

T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
fail() { echo "FAIL: $1" >&2; exit 1; }

SEP=$'\x1f'                 # non-whitespace field sep: preserves empty fields (unlike tab under IFS)
CASES="$T/cases"; : > "$CASES"
ncases=0

# emit <state|@U> <rmr|@U> <mp|@U> <wa|@U> <verb> [args...]  — append one case line.
# @U = the variable is UNSET; "" = the variable is set to empty. Refix verbs always pass a real
# <state>; policy/hold verbs pass @U (they never read the ledger).
emit() {
  local line="$1$SEP$2$SEP$3$SEP$4$SEP$5"; shift 5
  local a
  for a in "$@"; do line="$line$SEP$a"; done
  printf '%s\n' "$line" >> "$CASES"
  ncases=$((ncases + 1))
}

# ── the BASH harness: source the watcher's real functions ONCE, then stream cases from stdin ────
HARNESS="$T/harness.sh"
cat > "$HARNESS" <<HSH
set -uo pipefail
export AGENT_WATCH_LIB=1
source "$REPO/scripts/herd/agent-watch.sh" >/dev/null 2>&1 || { echo "SOURCE_FAIL" >&2; exit 3; }
SEP=\$'\x1f'
while IFS="\$SEP" read -ra F; do
  [ "\${#F[@]}" -ge 5 ] || continue
  if [ "\${F[0]}" = @U ]; then unset REFIX_STATE;      else REFIX_STATE="\${F[0]}"; fi
  if [ "\${F[1]}" = @U ]; then unset REFIX_MAX_ROUNDS; else REFIX_MAX_ROUNDS="\${F[1]}"; fi
  if [ "\${F[2]}" = @U ]; then unset MERGE_POLICY;     else MERGE_POLICY="\${F[2]}"; fi
  if [ "\${F[3]}" = @U ]; then unset WATCHER_AUTOMERGE;else WATCHER_AUTOMERGE="\${F[3]}"; fi
  verb="\${F[4]}"; args=( "\${F[@]:5}" )
  # Each function is captured via \$(...) — which strips trailing newlines symmetrically — and
  # re-emitted as EXACTLY ONE line. This normalizes the mix of newline conventions in the bash
  # (refix_*_cap / the empty-ledger fast paths use \`printf '%s'\` with NO newline; the awk readers
  # print one) so every case yields one output line, matching python's value+"\\n" per case.
  out=""
  case "\$verb" in
    rail_cap)         out="\$(refix_rail_cap)" ;;
    total_cap)        out="\$(refix_total_cap)" ;;
    attempted)        if refix_attempted "\${args[@]}"; then out=yes; else out=no; fi ;;
    total_count)      out="\$(refix_total_count "\${args[@]}")" ;;
    rail_count)       out="\$(refix_rail_count "\${args[@]}")" ;;
    round_count_kind) out="\$(refix_round_count_kind "\${args[@]}")" ;;
    budget_reason)    out="\$(_refix_budget_reason "\${args[@]}" || true)" ;;
    effective_policy) out="\$(_effective_merge_policy)" ;;
    legacy_policy)    out="\$(_legacy_automerge_policy)" ;;
    is_typo)          if _merge_policy_is_typo; then out=yes; else out=no; fi ;;
    hold_decision)    out="\$(_hold_decision "\${args[@]}")" ;;
    *) echo "BAD_VERB \$verb" >&2; exit 4 ;;
  esac
  printf '%s\n' "\$out"
done
HSH

# ── (1) curated refix-budget fixtures — the edge cases the arithmetic must get right ────────────
mk() { printf '%s' "$1" > "$2"; }   # mk <content> <path>

L_EMPTY="$T/l_empty"; : > "$L_EMPTY"
emit "$L_EMPTY" 3 @U @U rail_cap
emit "$L_EMPTY" 3 @U @U total_cap
emit "$L_EMPTY" 3 @U @U rail_count 42 review
emit "$L_EMPTY" 3 @U @U total_count 42
emit "$L_EMPTY" 3 @U @U attempted 42 abc review
emit "$L_EMPTY" 3 @U @U budget_reason 42 review

# cross-rail thrash + a legacy 4-field (no-kind ⇒ review) line + a foreign PR row.
L_THRASH="$T/l_thrash"
mk $'10 42 aaa slug1\n11 42 aaa slug1 review\n12 42 bbb slug1 health\n13 42 bbb slug1 stale\n14 99 other other review\n' "$L_THRASH"
emit "$L_THRASH" 3 @U @U rail_count 42 review
emit "$L_THRASH" 3 @U @U rail_count 42 health
emit "$L_THRASH" 3 @U @U rail_count 42 stale
emit "$L_THRASH" 3 @U @U rail_count 42 ci
emit "$L_THRASH" 3 @U @U total_count 42
emit "$L_THRASH" 3 @U @U total_count 99
emit "$L_THRASH" 3 @U @U attempted 42 aaa review
emit "$L_THRASH" 3 @U @U attempted 42 bbb health
emit "$L_THRASH" 3 @U @U attempted 42 aaa health
emit "$L_THRASH" 3 @U @U attempted 42 bbb
emit "$L_THRASH" 3 @U @U round_count_kind 42 review
emit "$L_THRASH" 3 @U @U round_count_kind 42 health

# refund-on-green: a reset zeroes the RAIL count but NOT the lifetime total nor the evidence counter.
L_RESET="$T/l_reset"
mk $'20 7 s1 slug review\n21 7 s2 slug review\n22 7 s3 slug review reset\n23 7 s4 slug review\n' "$L_RESET"
emit "$L_RESET" 3 @U @U rail_count 7 review
emit "$L_RESET" 3 @U @U total_count 7
emit "$L_RESET" 3 @U @U round_count_kind 7 review
emit "$L_RESET" 3 @U @U attempted 7 s2 review
emit "$L_RESET" 3 @U @U attempted 7 s3 review
emit "$L_RESET" 3 @U @U budget_reason 7 review

# rail cap reached: three review bounces, cap 3 ⇒ blocked with the rail phrase.
L_RCAP="$T/l_rcap"
mk $'30 8 a slug review\n31 8 b slug review\n32 8 c slug review\n' "$L_RCAP"
emit "$L_RCAP" 3 @U @U rail_count 8 review
emit "$L_RCAP" 3 @U @U budget_reason 8 review
emit "$L_RCAP" 3 @U @U budget_reason 8 health

# total cap reached across rails without any single rail maxing: cap 2 ⇒ total cap 6.
L_TCAP="$T/l_tcap"
mk $'40 9 a s review\n41 9 a s health\n42 9 a s stale\n43 9 a s review\n44 9 a s health\n45 9 a s stale\n' "$L_TCAP"
emit "$L_TCAP" 2 @U @U total_cap
emit "$L_TCAP" 2 @U @U total_count 9
emit "$L_TCAP" 2 @U @U budget_reason 9 ci
emit "$L_TCAP" 2 @U @U budget_reason 9 review

# REFIX_MAX_ROUNDS coercion: garbage / 0 / empty / unset all fall back to 3 (the byte-parity domain
# is unset/empty/non-numeric/"0"/plain positive ints — zero-padded/octal forms like "00","010" are
# degenerate configs bash itself reads inconsistently, so they are deliberately out of scope; see
# refix_cap_num's docstring).
for rmr in @U "" 0 abc 1 5 12; do
  emit "$L_EMPTY" "$rmr" @U @U rail_cap
  emit "$L_EMPTY" "$rmr" @U @U total_cap
done

# ── (2) merge-policy resolver — exhaustive over recognized / typo / legacy matrix ───────────────
for mp in @U "" auto approve observe AUTO Approve garbage; do
  for wa in @U true false no off on 0 1 yes; do
    emit @U @U "$mp" "$wa" effective_policy
    emit @U @U "$mp" "$wa" legacy_policy
    emit @U @U "$mp" "$wa" is_typo
  done
done

# ── (3) the merge-decision helper — exhaustive over mode × hv × approved × hv_policy ────────────
for mode in observe approve auto bogus; do
  for hv in "" 1; do
    for ap in "" 1; do
      for hvpol in hold coordinator auto; do
        emit @U @U @U @U hold_decision "$mode" "$hv" "$ap" "$hvpol"
      done
    done
  done
done

# ── (4) DETERMINISTIC FUZZ: random ledgers, every refix verb, bash vs python must agree ─────────
RANDOM=20260710
PRS=(1 2 42); SHAS=(a b c); KINDS=(review health stale ci "")
for r in $(seq 1 60); do
  LED="$T/fuzz.$r"; : > "$LED"
  nrows=$(( RANDOM % 9 ))
  for i in $(seq 0 "$nrows"); do
    pr="${PRS[$(( RANDOM % ${#PRS[@]} ))]}"
    sha="${SHAS[$(( RANDOM % ${#SHAS[@]} ))]}"
    kind="${KINDS[$(( RANDOM % ${#KINDS[@]} ))]}"
    if [ $(( RANDOM % 4 )) -eq 0 ] && [ -n "$kind" ]; then
      printf '%s %s %s slug%s %s reset\n' "$i" "$pr" "$sha" "$i" "$kind" >> "$LED"
    elif [ -n "$kind" ]; then
      printf '%s %s %s slug%s %s\n' "$i" "$pr" "$sha" "$i" "$kind" >> "$LED"
    else
      printf '%s %s %s slug%s\n' "$i" "$pr" "$sha" "$i" >> "$LED"   # legacy 4-field
    fi
  done
  rmr=$(( (RANDOM % 4) + 1 ))
  for pr in "${PRS[@]}"; do
    emit "$LED" "$rmr" @U @U total_count "$pr"
    for kind in review health stale ci; do
      emit "$LED" "$rmr" @U @U rail_count "$pr" "$kind"
      emit "$LED" "$rmr" @U @U round_count_kind "$pr" "$kind"
      emit "$LED" "$rmr" @U @U budget_reason "$pr" "$kind"
      for sha in "${SHAS[@]}"; do
        emit "$LED" "$rmr" @U @U attempted "$pr" "$sha" "$kind"
      done
    done
  done
done

# ── run BOTH implementations over the whole case stream, ONE process each, and diff ─────────────
BOUT="$T/bash.out"; POUT="$T/py.out"
bash "$HARNESS" < "$CASES" > "$BOUT" 2>"$T/bash.err" || fail "bash harness errored: $(cat "$T/bash.err")"
PYTHONPATH="$REPO/pysrc" python3 -m herd.decisions --batch < "$CASES" > "$POUT" 2>"$T/py.err" \
  || fail "python batch errored: $(cat "$T/py.err")"

bl="$(wc -l < "$BOUT" | tr -d ' ')"; pl="$(wc -l < "$POUT" | tr -d ' ')"
[ "$bl" = "$ncases" ] || fail "bash produced $bl lines, expected $ncases cases"
[ "$pl" = "$ncases" ] || fail "python produced $pl lines, expected $ncases cases"

if ! cmp -s "$BOUT" "$POUT"; then
  # Find and show the first divergent case for a precise repro.
  ln="$(diff "$BOUT" "$POUT" | grep -m1 -oE '^[0-9]+' || echo '?')"
  echo "---- first divergence at output line $ln ----" >&2
  echo "case : $(sed -n "${ln}p" "$CASES" | tr "$SEP" ' ')" >&2
  echo "bash : $(sed -n "${ln}p" "$BOUT")" >&2
  echo "py   : $(sed -n "${ln}p" "$POUT")" >&2
  fail "decision-core parity: bash and python disagree ($ncases cases)"
fi

# ── (5) stdlib property unit tests (no hypothesis required; soft hypothesis pass if present) ────
PYTHONPATH="$REPO/pysrc" python3 "$HERE/test_decisions_props.py" >/dev/null 2>&1 \
  || fail "stdlib property unit tests failed (run: PYTHONPATH=pysrc python3 tests/test_decisions_props.py)"

echo "ALL PASS ($ncases parity cases + stdlib property units)"
