"""herd status — FORMAT stage of the read-only control-room snapshot (HERD-307, P1b, EPIC HERD-300).

`herd status` is a LIVE-ENVIRONMENT snapshot (ps / gh / driver-seam / colours / timing dup-detect),
not a journal reader like P1's why/log/cost — so it is ported via a bash-gathers / python-formats
split. scripts/herd/status.sh's _status_gather runs every live probe and emits ONE <US>-delimited
snapshot (the stable parity seam); this module consumes it and renders output byte-identical to the
historical bash formatter (_status_format_bash, kept in place as the fail-soft fallback). Only this
pure FORMAT stage can be golden-tested — the live probes in gather deliberately get no golden.

Renders into an in-memory buffer and writes it in ONE shot at the very end, then exits 0 (healthy) or
1 (attention). A mid-render exception therefore leaves stdout EMPTY, so bin/herd's dispatch detects the
empty output and falls back to the bash formatter (never a half-rendered report, never a red row).

Snapshot record grammar (fields joined by US=\x1f), mirrored from status.sh:
  COLORS <b> <d> <g> <y> <r> <x> · WORKSPACE <name> · ROOT <root>
  WATCHER <state> <pid1> <count> <pids>   state in down|alive|handoff|dup
  BCOUNTS <build> <done> <idle> <dead> · BUILDER <verdict> <slug> <prnum>
  PRCOUNT <n> · PR <num> <branch> <mergeable> <mstate> <review> <health> <decision> <attn>
  BACKLOG file <open> <inprog> | BACKLOG other <backend>
  CODEMAP <present 0|1> <fresh 0|1> · ATTENTION <0|1> · REASONS <string>
"""
import sys

US = "\x1f"


def _to_int(s):
    try:
        return int(s)
    except (TypeError, ValueError):
        return 0


def main():
    b = d = g = y = r = x = ""
    workspace = root = ""
    w_state, w_pid1, w_count, w_pids = "down", "", "0", ""
    n_build = n_done = n_idle = n_dead = "0"
    builders = []            # (verdict, slug, prnum)
    n_prs = "0"
    prs = []                 # (num, branch, mergeable, mstate, review, health, decision, attn)
    bl_kind = bl_open = bl_inprog = bl_backend = ""
    cm_present = cm_fresh = "0"
    attention = "0"
    reasons = ""

    for line in sys.stdin.read().split("\n"):
        if not line:
            continue
        parts = line.split(US)
        key = parts[0]
        f = parts[1:]

        def gf(i):
            return f[i] if i < len(f) else ""

        if key == "COLORS":
            b, d, g, y, r, x = gf(0), gf(1), gf(2), gf(3), gf(4), gf(5)
        elif key == "WORKSPACE":
            workspace = gf(0)
        elif key == "ROOT":
            root = gf(0)
        elif key == "WATCHER":
            w_state, w_pid1, w_count, w_pids = gf(0), gf(1), gf(2), gf(3)
        elif key == "BCOUNTS":
            n_build, n_done, n_idle, n_dead = gf(0), gf(1), gf(2), gf(3)
        elif key == "BUILDER":
            builders.append((gf(0), gf(1), gf(2)))
        elif key == "PRCOUNT":
            n_prs = gf(0)
        elif key == "PR":
            prs.append(tuple(gf(i) for i in range(8)))
        elif key == "BACKLOG":
            bl_kind = gf(0)
            if bl_kind == "file":
                bl_open, bl_inprog = gf(1), gf(2)
            else:
                bl_backend = gf(1)
        elif key == "CODEMAP":
            cm_present, cm_fresh = gf(0), gf(1)
        elif key == "ATTENTION":
            attention = gf(0)
        elif key == "REASONS":
            reasons = gf(0)

    out = []
    out.append("%s🐑 herd status%s · %s%s%s · %s%s%s\n\n" % (b, x, b, workspace, x, d, root, x))

    if w_state == "dup":
        out.append("  %sWATCHER%s   %s⚠ %s watcher mains alive%s (pids %s) %s— duplicates race the gate; stop the extras: 'herd pane watch' (or kill all but one)%s\n"
                   % (b, x, r, w_count, x, w_pids, d, x))
    elif w_state == "handoff":
        out.append("  %sWATCHER%s   %salive%s (pid %s) %s· engine-update restart handoff in progress%s\n"
                   % (b, x, g, x, w_pid1, d, x))
    elif w_state == "alive":
        out.append("  %sWATCHER%s   %salive%s (pid %s)\n" % (b, x, g, x, w_pid1))
    else:
        out.append("  %sWATCHER%s   %sdown%s %s(no herd-watch-<workspace> process / pid lock)%s\n"
                   % (b, x, y, x, d, x))

    dcol = r if _to_int(n_dead) > 0 else ""
    out.append("  %sBUILDERS%s  %d building · %d done · %d idle · %s%d dead%s\n"
               % (b, x, _to_int(n_build), _to_int(n_done), _to_int(n_idle), dcol, _to_int(n_dead), x))
    for verdict, slug, prnum in builders:
        sl = "%-24s" % slug
        prsuf = " · PR #%s" % prnum if prnum else ""
        if verdict == "building":
            out.append("    %s🔨%s %s%s%s building\n" % (g, x, b, sl, x))
        elif verdict == "done":
            out.append("    %s✅%s %s%s%s done%s\n" % (g, x, b, sl, x, prsuf))
        elif verdict == "idle":
            out.append("    %s💤 %s idle · no PR%s\n" % (d, sl, x))
        elif verdict == "agentdead":
            out.append("    %s💀 %s%s%s %sAGENT DEAD (session unwakeable%s) — re-task by hand%s\n"
                       % (r, b, sl, x, r, prsuf, x))
        elif verdict == "agentmissing":
            out.append("    %s🫥 %s%s%s %sAGENT MISSING (no agent pane%s) — re-task by hand%s\n"
                       % (r, b, sl, x, r, prsuf, x))
        elif verdict == "dead":
            out.append("    %s💀 %s%s%s %sDEAD (no agent, no PR, no commits)%s\n" % (r, b, sl, x, r, x))

    out.append("  %sPRS%s       %d open\n" % (b, x, _to_int(n_prs)))
    for (pnum, pbr, pmerge, pmstate, preview, phealth, pdec, pattn) in prs:
        mcol = r if pattn == "1" else g
        out.append("    %s#%s%s %s%-24s%s %s%s%s%s%s%s%s\n" % (
            d, pnum, x, b, pbr[:24], x,
            mcol, (pmerge or "UNKNOWN"), x,
            (" · %s" % pmstate) if pmstate else "",
            (" · review %s" % preview) if preview else "",
            (" · health %s" % phealth) if phealth else "",
            (" · %s" % pdec) if pdec else ""))

    if bl_kind == "file":
        out.append("  %sBACKLOG%s   %s open · %s in-progress\n" % (b, x, bl_open, bl_inprog))
    else:
        out.append("  %sBACKLOG%s   %s(backend: %s — no local counts)%s\n" % (b, x, d, bl_backend, x))

    if cm_present == "1":
        if cm_fresh == "1":
            out.append("  %sCODEMAP%s   %sfresh%s\n" % (b, x, d, x))
        else:
            out.append("  %sCODEMAP%s   %sstale · run `herd codemap` to refresh%s\n" % (b, x, d, x))

    out.append("\n")
    if attention == "1":
        out.append("%s⚠️  attention:%s%s\n" % (y, reasons, x))
        sys.stdout.write("".join(out))
        sys.exit(1)
    out.append("%s✅ healthy%s\n" % (g, x))
    sys.stdout.write("".join(out))
    sys.exit(0)


if __name__ == "__main__":
    main()
