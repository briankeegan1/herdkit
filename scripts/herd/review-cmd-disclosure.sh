#!/usr/bin/env bash
# review-cmd-disclosure.sh — THE shared REVIEWER VERIFICATION-COMMAND DISCLOSURE resolver (HERD-810).
#
# WHY THIS EXISTS
# --------------
# PR #863's retained reviewer log (herd-review-863-uQaOIy): a Codex adversarial reviewer decided to
# PROVE its finding by replaying a test suite in a temporary checkout. The copied command carried an
# `rm -rf "$tmpdir"` cleanup trap, Codex's command policy REJECTED it ("rm -f style commands are not
# permitted"), and the reviewer went on to print its final `REVIEW: BLOCK` line without ever saying
# that the verification it intended NEVER RAN. The verdict line the gate reads was byte-for-byte the
# shape of a verified finding; the only evidence that the check was unexecuted was one `ERROR
# codex_core::tools::router` line buried in the stream — invisible to the watcher, the coordinator,
# `herd why`, and anyone reading the PR comment. An unexecuted check mistaken for evidence is the
# SILENTLY-WRONG outcome the review gate exists to prevent, turned on the gate itself.
#
# WHAT IT DOES
# ------------
# A SECOND, independent pass over the reviewer's captured output that extracts every verification
# command the runtime REJECTED (its command policy refused to run it) or FAILED TO LAUNCH (the exec
# itself errored — never the command's own non-zero exit, which IS a result), and renders them as
# durable, machine-readable disclosure lines:
#
#     UNEXECUTED: <rejected|failed> | <the command, one line, capped>
#
# herd-review.sh (the ONLY caller in the engine) appends those lines to the RETAINED review log and
# writes them into the sha-keyed RESULT FILE ahead of the verdict (the same slot RUBRIC: lines use),
# journals one `review_cmd_unexecuted` event, and annotates a PASS with an `advisory:` segment so the
# existing advisory surface carries the disclosure — while a BLOCK is left VERBATIM: a BLOCK that is
# independently supported by reading the diff is still a BLOCK, and this pass can NEVER change a
# verdict (it only explains what the verdict is NOT backed by). pysrc/herd/live_runtime.py's
# parse_unexecuted_cmds is the consumer-side twin of herd_review_unexecuted_cmds.
#
# FAIL-CLOSED FOR PROVENANCE: when the log the reviewer wrote to cannot be read at all, the resolver
# does NOT answer "nothing was rejected" (an absence of evidence it cannot actually vouch for); it
# emits a single `UNEXECUTED: unknown | …` line, so the outcome records that verification provenance
# could not be established. Everything else fails SOFT: a log with no recognized signature yields no
# lines, and no caller ever aborts on this resolver's exit status.
#
# SIGNATURES RECOGNIZED (deterministic text scan, no runtime introspection):
#   • Codex exec router:  `... exec_command failed for `<cmd>`: CreateProcess { message: "Rejected(...` → rejected
#   • Codex exec router:  `... exec_command failed for `<cmd>`: <anything else>`                          → failed
#   • Claude permission:  a streamed `tool_result` whose error text says the Bash command was denied /
#                         requires approval — rendered by herd-review.sh's stream formatter as a plain
#                         line — is matched on `Permission denied for tool` / `requires approval` with a
#                         `command:`-tagged body                                                         → rejected
# The command text is the runtime's own quoted argv (the zsh -lc wrapper included) so an operator sees
# EXACTLY what was refused, not a paraphrase.
#
# Ship-dormant: herd-review.sh consults this file only when REVIEW_CMD_DISCLOSURE=on; with the key off
# (default) nothing here is sourced and every review output is byte-identical to before HERD-810.
# Sourceable (functions only) AND executable (`review-cmd-disclosure.sh <logfile>` prints the lines).

# herd_review_unexecuted_cmds <logfile> — print one `<kind>\t<cmd>` line per rejected/failed reviewer
# command found in <logfile>, in stream order, de-duplicated (the same rejected command retried
# verbatim is ONE disclosure). Prints nothing when none is recognized. Returns 0 always when the log
# is readable; returns 2 (and prints nothing) when it is not — the caller decides what "unknown" means.
herd_review_unexecuted_cmds() {
  local _log="${1:-}"
  [ -n "$_log" ] && [ -r "$_log" ] || return 2
  command -v python3 >/dev/null 2>&1 || return 2
  python3 - "$_log" <<'PY' 2>/dev/null || return 2
import re, sys

path = sys.argv[1]
try:
    with open(path, encoding="utf-8", errors="replace") as fh:
        text = fh.read()
except Exception:
    sys.exit(2)

# Codex exec router: "exec_command failed for `<cmd>`: <reason>". The command is the runtime's own
# backtick-quoted argv; it may contain backticks itself only inside the reason's escaped re-quote, so
# the FIRST "`: " after the opening backtick closes it (verified against the PR #863 retained log).
CODEX = re.compile(r"exec_command failed for `(?P<cmd>.*?)`: (?P<reason>.*)$")
CLAUDE = re.compile(r"(?:Permission denied for tool|requires approval|permission was denied)[^\n]*?command:\s*(?P<cmd>.+)$", re.I)

seen = set()
out = []
for raw in text.splitlines():
    line = raw.strip()
    if not line:
        continue
    m = CODEX.search(line)
    if m:
        cmd = m.group("cmd").strip()
        kind = "rejected" if "Rejected(" in m.group("reason") else "failed"
    else:
        m = CLAUDE.search(line)
        if not m:
            continue
        cmd = m.group("cmd").strip()
        kind = "rejected"
    if not cmd:
        continue
    key = (kind, cmd)
    if key in seen:
        continue
    seen.add(key)
    out.append("%s\t%s" % (kind, cmd))
sys.stdout.write("".join(o + "\n" for o in out))
PY
}

# herd_review_disclosure_lines <logfile> — the durable `UNEXECUTED: <kind> | <cmd>` lines for the
# result file / retained log. The command is flattened to ONE line, has every '|' replaced by '¦' (the
# result-file and advisory grammars are ' | '-separated, so a pipe inside the command must never
# split a field), and is capped at 300 chars. Fail-closed: an unreadable log (or no python3) yields
# exactly one `UNEXECUTED: unknown | …` line — the caller must never conclude "all checks ran" from
# silence it cannot vouch for. Prints nothing when the log is readable and carries no signature.
herd_review_disclosure_lines() {
  local _log="${1:-}" _raw _rc=0
  _raw="$(herd_review_unexecuted_cmds "$_log")" || _rc=$?
  if [ "$_rc" -ne 0 ]; then
    printf 'UNEXECUTED: unknown | reviewer output at %s could not be read — verification provenance cannot be established\n' "${_log:-<none>}"
    return 0
  fi
  [ -n "$_raw" ] || return 0
  printf '%s\n' "$_raw" | awk -F'\t' '
    NF >= 2 {
      kind = $1; cmd = $2
      for (i = 3; i <= NF; i++) cmd = cmd "\t" $i
      gsub(/\|/, "\302\246", cmd)
      gsub(/[\r\n]+/, " ", cmd)
      if (length(cmd) > 300) cmd = substr(cmd, 1, 297) "..."
      printf "UNEXECUTED: %s | %s\n", kind, cmd
    }'
  return 0
}

# herd_review_disclosure_advisory <disclosure-lines> — render the disclosure as the ' advisory:'
# segment(s) a PASS verdict carries (HERD-105 grammar: ' — advisory: <note> | advisory: <note>'). One
# segment per line, each a short, single-line note; the note names the kind and the command so the
# journaled review_advisory event is self-explanatory. Prints the segments WITHOUT the leading ' — '
# / ' | ' joiner — the caller picks the joiner from whether the PASS already carries advisories.
herd_review_disclosure_advisory() {
  printf '%s\n' "${1:-}" | awk '
    /^UNEXECUTED: / {
      sub(/^UNEXECUTED: /, "")
      split($0, f, " \\| ")
      kind = f[1]; cmd = substr($0, length(kind) + 4)
      if (length(cmd) > 160) cmd = substr(cmd, 1, 157) "..."
      if (n++) printf " | "
      printf "advisory: reviewer verification command %s — NOT executed, this verdict is not backed by it: %s", kind, cmd
    }
    END { if (n) printf "\n" }'
}

# CLI: `review-cmd-disclosure.sh <logfile>` prints the disclosure lines (exit 0; exit 2 on usage).
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  [ -n "${1:-}" ] || { echo "usage: review-cmd-disclosure.sh <reviewer-logfile>" >&2; exit 2; }
  herd_review_disclosure_lines "$1"
fi
