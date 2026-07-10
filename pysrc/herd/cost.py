"""herd cost [--pr N] [--full] — aggregate the journal's `cost` events into a spend rollup.

Reads the newline-separated journal file list on stdin (live journal + rotated archives) and:
  $HERD_COST_PR         drill into one PR when set (else the full rollup)
  $HERD_COST_FULL        "1" appends the live-session (coordinator/scribe/researcher) section
  $HERD_COST_FULL_LINES  pre-formatted "component=.. model=.. .. usd=.." lines (from bash's
                         cost_report_full) — this module NEVER scans a transcript itself
  $HERD_COST_FULL_NOTE   the "nothing to add" note when there are no such lines

Pure reader, zero mutation. Byte-identical to the historical inline `python3 -c` program in
bin/herd cmd_cost (kept there as the fail-soft fallback); the two share this exact source.
"""
import sys, os, json


def main():
    want_pr = os.environ.get("HERD_COST_PR", "")
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
                if o.get("event") != "cost":
                    continue
                rows.append(o)

    def fnum(v):
        try:
            return float(v)
        except (TypeError, ValueError):
            return 0.0

    # `herd cost --full` augmentation: the live-scanned coordinator/scribe/researcher spend, passed in
    # as pre-formatted "component=.. model=.. in=.. .. usd=.. msgs=.." lines from cost_report_full. This
    # section is APPENDED to the merge-recorded rollup and never alters it, so default `herd cost`
    # (FULL != "1") is byte-for-byte unchanged.
    FULL = os.environ.get("HERD_COST_FULL", "") == "1"
    FULL_LINES = os.environ.get("HERD_COST_FULL_LINES", "")
    FULL_NOTE = os.environ.get("HERD_COST_FULL_NOTE", "")

    def _parse_kv_lines(s):
        out = []
        for line in s.split("\n"):
            line = line.strip()
            if not line:
                continue
            d = {}
            for kv in line.split():
                if "=" in kv:
                    k, v = kv.split("=", 1)
                    d[k] = v
            if d.get("component"):
                out.append(d)
        return out

    def print_full_section(base_usd):
        # base_usd = the merge-recorded (builder+review) total; the session total sums it with the
        # live-scanned agents so the operator sees a COMPLETE session figure, not just per-PR spend.
        print("")
        print("Live session agents (herd cost --full — scanned live from transcripts):")
        agents = _parse_kv_lines(FULL_LINES)
        extra = 0.0
        if not agents:
            print("  %s" % (FULL_NOTE or "no coordinator/scribe/researcher transcript found — nothing to add"))
        else:
            for d in agents:
                usd = fnum(d.get("usd")); extra += usd
                print("  %-11s %-18s $%9.4f  (in %s out %s cache_r %s cache_w %s · %s msgs)" % (
                    d.get("component", "?"), d.get("model", "?"), usd,
                    d.get("in", "0"), d.get("out", "0"), d.get("cache_read", "0"), d.get("cache_write", "0"), d.get("msgs", "0")))
        print("")
        print("Session total (builder+review+coordinator+scribe+researcher): $%.4f" % (base_usd + extra))

    if want_pr:
        rows = [o for o in rows if str(o.get("pr", "")) == want_pr]

    if not rows:
        if want_pr:
            print("PR #%s — no cost events recorded." % want_pr)
        else:
            print("No cost events recorded yet.")
            print("  (the watcher journals a `cost` event for each builder at merge time)")
            if FULL:
                print_full_section(0.0)
        sys.exit(0)

    if want_pr:
        print("PR #%s — cost breakdown" % want_pr)
        total = 0.0
        for o in sorted(rows, key=lambda o: str(o.get("component",""))):
            usd = fnum(o.get("usd")); total += usd
            print("  %-8s %-18s $%9.4f  (in %s out %s cache_r %s cache_w %s · %s msgs)" % (
                str(o.get("component","?")), str(o.get("model","?")), usd,
                o.get("in",0), o.get("out",0), o.get("cache_read",0), o.get("cache_write",0), o.get("msgs",0)))
        print("  %-8s %-18s $%9.4f" % ("TOTAL", "", total))
        sys.exit(0)

    # Full rollup.
    per_pr = {}          # pr -> usd
    by_component = {}     # component -> usd
    by_model = {}         # model -> usd
    merged = set()        # PRs with a builder cost event
    grand = 0.0
    for o in rows:
        prn = str(o.get("pr", "?"))
        usd = fnum(o.get("usd"))
        comp = str(o.get("component", "?"))
        model = str(o.get("model", "?"))
        per_pr[prn] = per_pr.get(prn, 0.0) + usd
        by_component[comp] = by_component.get(comp, 0.0) + usd
        by_model[model] = by_model.get(model, 0.0) + usd
        grand += usd
        if comp == "builder":
            merged.add(prn)

    def _prkey(p):
        try:
            return (0, int(p))
        except ValueError:
            return (1, p)

    print("Cost per PR (%d PR%s with cost events):" % (len(per_pr), "" if len(per_pr)==1 else "s"))
    for prn in sorted(per_pr, key=_prkey):
        print("  PR #%-6s $%9.4f" % (prn, per_pr[prn]))
    print("")
    print("By component:")
    for comp in sorted(by_component, key=lambda c: -by_component[c]):
        print("  %-10s $%9.4f" % (comp, by_component[comp]))
    print("By model:")
    for model in sorted(by_model, key=lambda m: -by_model[m]):
        print("  %-18s $%9.4f" % (model, by_model[model]))
    # HERD-151: surface any UNPRICED model explicitly so a foreign/runtime-qualified ref that priced at $0
    # is never read as free. A ?-flagged model id (or a journaled unpriced>0) is the signal.
    _unpriced_models = sorted({m for m in by_model if m.endswith("?")})
    if _unpriced_models or any(fnum(o.get("unpriced", 0)) > 0 for o in rows):
        print("  [!] unpriced (no price in the cost table, counted at $0): %s"
              % (", ".join(_unpriced_models) or "see model? flags above"))
    print("")
    print("Total spend recorded:   $%.4f" % grand)
    print("Merged PRs (billed):     %d" % len(merged))
    if merged:
        print("Cost per merged PR:      $%.4f" % (grand / len(merged)))
    if FULL:
        print_full_section(grand)


if __name__ == "__main__":
    main()
