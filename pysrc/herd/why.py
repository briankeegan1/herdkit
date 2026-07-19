"""herd why <pr#> — aggregate every journal event for one PR, chronologically.

Reads the newline-separated journal file list on stdin (live journal + rotated archives, as
resolved by bin/herd's _journal_all_files) and the target PR from $HERD_WHY_PR. Pure reader:
opens each file read-only, prints a gate-history summary, exits 0. Byte-identical to the
historical inline `python3 -c` program in bin/herd cmd_why (kept there as the fail-soft
fallback); the two share this exact source.
"""
import sys, os, json

from herd.shadow_journal import NOT_YET_SURFACED_KEYS


def main():
    pr = os.environ["HERD_WHY_PR"]
    rows = []
    for path in sys.stdin.read().split("\n"):
        path = path.strip()
        if not path:
            continue
        try:
            f = open(path, encoding="utf-8")
        except OSError:
            continue
        with f:
            for raw in f:
                raw = raw.strip()
                if not raw:
                    continue
                try:
                    o = json.loads(raw)
                except Exception:
                    continue
                if str(o.get("pr", "")) == pr:
                    rows.append(o)
    rows.sort(key=lambda o: str(o.get("ts", "")))
    if not rows:
        print("PR #%s — no journal entries found." % pr)
        sys.exit(0)

    def g(o, *ks):
        return next((str(o[k]) for k in ks if o.get(k) not in (None, "")), "")

    def describe(o):
        ev = o.get("event", "?")
        if ev == "review_dispatched":
            return "review dispatched", "sha %s · model %s · pid %s" % (g(o,"sha")[:12] or "?", g(o,"model") or "?", g(o,"pid") or "?")
        if ev == "verdict_recorded":
            return "verdict recorded", "%s (%s) · sha %s" % (g(o,"value") or "?", g(o,"source") or "?", g(o,"sha")[:12] or "?")
        if ev == "healthcheck_attempted":
            return "healthcheck attempt", "attempt %s → %s" % (g(o,"attempt") or "1", g(o,"result") or "?")
        if ev == "healthcheck_retried":
            return "healthcheck retry", "attempt %s → %s" % (g(o,"attempt") or "?", g(o,"result") or "?")
        if ev == "healthcheck_outcome":
            d = g(o,"detail")
            return "healthcheck outcome", g(o,"outcome") + (" · " + d if d else "")
        if ev == "refix_bounce":
            return "auto-refix bounce", "round %s · agent was %s" % (g(o,"round") or "?", g(o,"agent_status_before") or "?")
        if ev == "refix_wake_result":
            return "auto-refix wake", "woke=%s escalated=%s (%s → %s)" % (g(o,"woke") or "?", g(o,"escalated") or "?", g(o,"agent_status_before") or "?", g(o,"agent_status_after") or "?")
        if ev == "hold_applied":
            return "hold applied", "%s hold · sha %s" % (g(o,"kind") or "approve", g(o,"sha")[:12] or "?")
        if ev == "hold_released":
            return "hold released", "%s hold · sha %s · %s" % (g(o,"kind") or "approve", g(o,"sha")[:12] or "?", g(o,"reason") or "")
        if ev == "merge":
            return "MERGED", "sha %s · %s · %s" % (g(o,"sha")[:12] or "?", g(o,"method") or "?", g(o,"reason") or "")
        if ev == "merge_observed":
            # HERD-232: a merge this seat did NOT perform (foreign seat / gh UI), or one whose do_merge died
            # before it could record the merge. The post-merge sweep reconciled it. Distinct from `merge`
            # because only `merge` asserts that this seat owes the post-merge teardown.
            return "MERGED (observed)", "sha %s · reconciled · reap_owed %s" % (
                g(o,"sha")[:12] or "?", g(o,"reap_owed") or "?")
        if ev == "reap":
            return "reaped worktree", "reason %s" % (g(o,"reason") or "?")
        if ev == "review_log_retained":
            return "review log kept", g(o,"path")
        if ev == "infra_event":
            return "INFRA event", "%s · exit %s · %s" % (g(o,"component") or "?", g(o,"exit_code") or "?", g(o,"stderr_tail") or "")
        if ev == "sweep_closed":
            return "tab swept", "%s (%s)" % (g(o,"tab_id") or "?", g(o,"reason") or "?")
        if ev == "reload_outcome":
            return "reload", "%s → %s" % (g(o,"component") or "?", g(o,"result") or "?")
        if ev == "cost":
            return "cost", "%s · %s · $%s (in %s out %s cache_r %s cache_w %s)" % (
                g(o,"component") or "?", g(o,"model") or "?", g(o,"usd") or "?",
                g(o,"in") or "0", g(o,"out") or "0", g(o,"cache_read") or "0", g(o,"cache_write") or "0")
        extra = " ".join("%s=%s" % (k, o[k]) for k in o
                         if k not in ("ts","event","pr") and k not in NOT_YET_SURFACED_KEYS)
        return ev, extra

    print("PR #%s — gate history (%d event%s)" % (pr, len(rows), "" if len(rows)==1 else "s"))
    for o in rows:
        label, detail = describe(o)
        print("  %s  %-20s %s" % (str(o.get("ts","")), label, detail))


if __name__ == "__main__":
    main()
