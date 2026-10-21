#!/usr/bin/env python3
"""Analyze boxcar3d --tel rollout telemetry.

Usage: tools/tel_analyze.py <tel_dir> [--window 3.0]

Reads summary.tsv + car_g*_c*.csv. Groups cars by terminal outcome and
prints, per channel: whole-run stats and the mean in a pre-terminal window
(last `window` seconds before fail_time; for completed cars, the last
`window` seconds of the run). Then ranks the frozen PID's sensor inputs by
how strongly their window values separate each failure mode from
completions (|mean diff| / pooled std).

Stdlib only.
"""
import csv
import glob
import math
import os
import sys

WIN = 3.0
EPS = 1e-9


def finite(xs):
    return [x for x in xs if x == x and math.isfinite(x)]


def mean(xs):
    return sum(xs) / len(xs) if xs else float("nan")


def std(xs):
    if len(xs) < 2:
        return float("nan")
    m = mean(xs)
    return math.sqrt(sum((x - m) ** 2 for x in xs) / (len(xs) - 1))


def load_car(path):
    with open(path) as f:
        rd = csv.reader(f)
        header = next(rd)
        rows = [[float(x) for x in row] for row in rd if row]
    return header, rows


def channel_cols(header):
    return {name: i for i, name in enumerate(header)}


def main():
    if len(sys.argv) < 2:
        print(__doc__)
        return 1
    d = sys.argv[1]
    if "--window" in sys.argv:
        global WIN
        WIN = float(sys.argv[sys.argv.index("--window") + 1])

    sp = os.path.join(d, "summary.tsv")
    if not os.path.exists(sp):
        print(f"no {sp}")
        return 1
    with open(sp) as f:
        summ = list(csv.DictReader(f, delimiter="\t"))

    # car key -> per-channel whole & window value lists, grouped by outcome
    groups = {}  # outcome -> {channel -> [values]}
    window_groups = {}

    for row in summ:
        key = f"car_g{row['gen']}_c{row['car']}"
        path = os.path.join(d, key + ".csv")
        if not os.path.exists(path):
            continue
        header, rows = load_car(path)
        if not rows:
            continue
        cols = channel_cols(header)
        t = [r[cols["t"]] for r in rows]
        end = float(row["fail_time"])
        t0 = end - WIN
        wrows = [r for r, tt in zip(rows, t) if tt >= t0]
        if not wrows:
            wrows = rows[-1:] if rows else []

        g = groups.setdefault(row["result"], {})
        wg = window_groups.setdefault(row["result"], {})
        for name, i in cols.items():
            if name == "t":
                continue
            g.setdefault(name, []).extend(finite([r[i] for r in rows]))
            wg.setdefault(name, []).extend(finite([r[i] for r in wrows]))

    channels = [c for c in channel_cols(load_car(
        sorted(glob.glob(os.path.join(d, "car_g*_c*.csv")))[0])[0]) if c != "t"]

    print(f"cars: {len(summ)}   window: last {WIN:.1f}s   groups: "
          + ", ".join(f"{k}={v}" for k, v in sorted(
            ((o, len(window_groups[o])) for o in groups))) + "\n")

    for outcome in sorted(groups):
        print(f"== {outcome} (n={len(window_groups[outcome])}) — window means "
              f"[whole-run mean] ==")
        for c in channels:
            w = window_groups[outcome].get(c, [])
            whole = groups[outcome].get(c, [])
            wm, ws = mean(w), std(w)
            hm = mean(whole)
            print(f"  {c:>12}: {wm:9.3f} ±{ws:7.3f}   [{hm:9.3f}]")
        print()

    # Discrimination: each failure mode vs completed (window values)
    done = window_groups.get("completed")
    if done:
        print("== channel separation (|Δmean| / pooled std, window) ==")
        for outcome in sorted(groups):
            if outcome == "completed":
                continue
            scores = []
            for c in channels:
                a = window_groups[outcome].get(c, [])
                b = done.get(c, [])
                if len(a) < 2 or len(b) < 2:
                    continue
                pooled = math.hypot(std(a), std(b)) + EPS
                scores.append((abs(mean(a) - mean(b)) / pooled, c,
                               mean(a) - mean(b)))
            scores.sort(reverse=True)
            print(f"  vs {outcome}:")
            for s, c, delta in scores[:5]:
                print(f"    {s:8.2f}  {c:>12}  (Δ={delta:+.3f})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
