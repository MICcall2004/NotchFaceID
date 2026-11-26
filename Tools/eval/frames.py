#!/usr/bin/env python3
"""Tune the match and liveness bars on frames recorded by NotchFaceID.

The app writes this only when the menu's "판정 기록 (CSV)" is on. It contains numbers,
never images or embeddings. Label each scan run by what was in front of the camera:

    python3 Tools/eval/frames.py                       # ~/Library/.../frames.csv
    python3 Tools/eval/frames.py frames.csv 1-3=me 4-6=photo 7-9=video 10=other

A range may be repeated (`1-3=me 11-12=me`). Runs with no label are ignored.
Standard library only.
"""
import csv
import math
import os
import statistics
import sys

DEFAULT = os.path.expanduser("~/Library/Application Support/NotchFaceID/frames.csv")
LABELS = ("me", "photo", "video", "other")
COLUMNS = "time,run,mode,distance,centroid,v2Live,v1seLive,live,width,aspect,yaw,roll,eyes,verdict".split(",")


def usage(code=2):
    print(__doc__.strip(), file=sys.stderr if code else sys.stdout)
    sys.exit(code)


def number(text):
    if text is None or text == "":
        return None
    try:
        value = float(text)
    except ValueError:
        return None
    return value if math.isfinite(value) else None


def percentiles(values, points=(5, 50, 95)):
    values = sorted(values)
    if not values:
        return ["-"] * len(points)
    out = []
    for p in points:
        index = min(len(values) - 1, max(0, round(p / 100 * (len(values) - 1))))
        out.append("%.3f" % values[index])
    return out


def mean_std(values):
    if not values:
        return "-"
    if len(values) == 1:
        return "%.3f" % values[0]
    return "%.3f±%.3f" % (statistics.mean(values), statistics.pstdev(values))


def parse_labels(args):
    labels = {}
    for arg in args:
        if "=" not in arg:
            usage()
        runs, label = arg.split("=", 1)
        if label not in LABELS:
            print("unknown label %r (use %s)" % (label, ", ".join(LABELS)), file=sys.stderr)
            usage()
        for part in runs.split(","):
            if "-" in part:
                a, b = part.split("-", 1)
                first, last = int(a), int(b)
            else:
                first = last = int(part)
            if first > last:
                first, last = last, first
            for run in range(first, last + 1):
                labels[run] = label
    return labels


class Row:
    __slots__ = ("time", "run", "mode", "distance", "centroid", "live", "v2", "v1se", "eyes", "width", "label", "verdict")

    def __init__(self, record):
        self.time = number(record.get("time")) or 0.0
        self.run = int(record.get("run") or 0)
        self.mode = record.get("mode") or ""
        self.distance = number(record.get("distance"))
        self.centroid = number(record.get("centroid"))
        self.live = number(record.get("live"))
        self.v2 = number(record.get("v2Live"))
        self.v1se = number(record.get("v1seLive"))
        self.eyes = number(record.get("eyes"))
        self.width = number(record.get("width"))
        self.label = "unlabeled"
        self.verdict = record.get("verdict") or ""


def load(path, labels):
    rows = []
    with open(path, newline="", encoding="utf-8") as handle:
        reader = csv.DictReader(handle)
        missing = [c for c in COLUMNS if c not in (reader.fieldnames or [])]
        if missing:
            print("missing columns: %s" % ", ".join(missing), file=sys.stderr)
            sys.exit(1)
        for record in reader:
            row = Row(record)
            # End rows and enrollment rows have no distance. A frame verdict may be "spoof"
            # too, so never filter on the verdict text here.
            if row.mode != "scanning" or row.distance is None:
                continue
            row.label = labels.get(row.run, "unlabeled")
            rows.append(row)
    return rows


def accepted(row, key, threshold, live):
    score = getattr(row, key)
    return score is not None and row.live is not None and score <= threshold and row.live >= live


def sweep(rows, key, frr_max=0.05):
    """Return the rule that blocks the most photo/video frames while keeping me at or under frr_max."""
    me = [r for r in rows if r.label == "me"]
    spoof = [r for r in rows if r.label in ("photo", "video")]
    if not me or not spoof:
        return None
    best = None
    threshold = 0.30
    while threshold <= 0.8001:
        live = 0.20
        while live <= 0.9501:
            frr = sum(1 for r in me if not accepted(r, key, threshold, live)) / len(me)
            if frr <= frr_max:
                rate = sum(1 for r in spoof if accepted(r, key, threshold, live)) / len(spoof)
                # Block the most spoof frames; break ties with the lower FRR.
                candidate = (rate, frr, threshold, live)
                if best is None or candidate < best:
                    best = candidate
            live += 0.05
        threshold += 0.01
    return best


def main(argv):
    if not argv or argv[0] in ("-h", "--help"):
        usage(0)
    path = argv[0]
    if not os.path.exists(path):
        print("no such file: %s\nTurn on 판정 기록 (CSV) in the menu and scan first." % path, file=sys.stderr)
        return 1
    rows = load(path, parse_labels(argv[1:]))
    if not rows:
        print("no scanning frames with a distance (enrollment and end rows are ignored)")
        return 1

    counts = {label: sum(1 for r in rows if r.label == label) for label in LABELS + ("unlabeled",)}
    print("frames: " + ", ".join("%s %d" % (k, v) for k, v in counts.items() if v))
    print("(runs with no label are ignored below)\n")

    print("%-9s %5s  %-17s %-17s %-17s %-9s %-9s" % ("label", "n", "distance p5/p50/p95", "centroid p5/p50/p95", "live p5/p50/p95", "eyes mean", "width"))
    for label in LABELS:
        group = [r for r in rows if r.label == label]
        if not group:
            continue
        d = percentiles([r.distance for r in group if r.distance is not None])
        c = percentiles([r.centroid for r in group if r.centroid is not None])
        l = percentiles([r.live for r in group if r.live is not None])
        e = [r.eyes for r in group if r.eyes is not None]
        w = [r.width for r in group if r.width is not None]
        print("%-9s %5d  %-17s %-17s %-17s %-9s %-9s" % (
            label, len(group), "/".join(d), "/".join(c), "/".join(l), mean_std(e),
            "%.0f" % statistics.mean(w) if w else "-"))

    print("\nbest rule per score (me FRR <= 5%, then the fewest photo/video frames accepted)")
    for key in ("distance", "centroid"):
        best = sweep(rows, key)
        if best:
            rate, frr, threshold, live = best
            print("  %-8s <= %.2f and live >= %.2f   me FRR %.1f%%   photo/video accepted %.1f%%"
                  % (key, threshold, live, frr * 100, rate * 100))
        else:
            print("  %-8s needs at least one me run and one photo/video run" % key)
    print("  defaults  distance <= 0.57 and live >= 0.50   (current hard clamp: 0.64 / 0.30)")

    # How often the two scores disagree about the same frame.
    both = [r for r in rows if r.distance is not None and r.centroid is not None]
    if both:
        closer_min = sum(1 for r in both if r.distance < r.centroid)
        print("\nmin-template closer than centroid on %d/%d frames (%.0f%%)"
              % (closer_min, len(both), 100 * closer_min / len(both)))

    # Frame cadence and blink signal, per scanning run.
    intervals, jitter, lows = [], [], []
    by_run = {}
    for row in rows:
        by_run.setdefault(row.run, []).append(row)
    for run, group in by_run.items():
        group.sort(key=lambda r: r.time)
        if len(group) > 2:
            gaps = [b.time - a.time for a, b in zip(group, group[1:]) if b.time > a.time]
            intervals.extend(gaps)
        if group[0].label == "me":
            eyes = [r.eyes for r in group if r.eyes is not None]
            if len(eyes) > 2:
                jitter.append(statistics.pstdev(eyes))
                lows.append(min(eyes))
    if intervals:
        intervals.sort()
        print("\nframe interval: median %.0f ms, p95 %.0f ms (~%.1f fps)"
              % (statistics.median(intervals) * 1000,
                 intervals[min(len(intervals) - 1, int(len(intervals) * 0.95))] * 1000,
                 1 / statistics.median(intervals) if statistics.median(intervals) else 0))
    if jitter:
        jitter.sort()
        lows.sort()
        print("eyes (me runs): within-run sd median %.3f, p95 %.3f; run minimum median %.3f, p5 %.3f"
              % (statistics.median(jitter),
                 jitter[min(len(jitter) - 1, int(len(jitter) * 0.95))],
                 statistics.median(lows),
                 lows[max(0, int(len(lows) * 0.05))]))
        print("  A blink needs the per-run minimum to fall clearly below the open-eye median before it can gate a scan.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:] or [DEFAULT]))
