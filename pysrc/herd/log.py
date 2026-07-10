"""herd log — format engine journal JSONL lines, one readable line each.

Reads raw journal lines on stdin (bin/herd feeds it either the live journal file or a
`tail -n 20 -f` stream) and prints one line per event. $HERD_LOG_PR filters to a single PR
when set. Pure formatter, zero mutation. Byte-identical to the historical inline `_JOURNAL_FMT`
program in bin/herd, kept there as the fail-soft fallback; the two share this exact source.
"""
import sys, os, json


def main():
    want_pr = os.environ.get("HERD_LOG_PR", "")
    def pr_of(o):
        v = o.get("pr")
        return "" if v is None else str(v)
    for raw in sys.stdin:
        raw = raw.strip()
        if not raw:
            continue
        try:
            o = json.loads(raw)
        except Exception:
            continue
        if want_pr and pr_of(o) != want_pr:
            continue
        ts = str(o.get("ts", ""))
        ev = str(o.get("event", "?"))
        rest = " ".join("%s=%s" % (k, o[k]) for k in o if k not in ("ts", "event"))
        print("%s  %-22s %s" % (ts, ev, rest))


if __name__ == "__main__":
    main()
