"""Summarize exported Debug GridArtworkTiming logs; never mixes cache scenarios.

Run each device capture with CINEVA_GRID_TRACE=1 and CINEVA_ARTWORK_SCENARIO
set to cold-network, warm-disk, warm-memory, or motion. Export Console logs,
then run: python Tests/summarize_grid_trace.py capture.txt
This reports observed samples only, not a synthetic speedup or Instruments data.
"""
import collections
import json
import math
import re
import statistics
import sys
from pathlib import Path


def summarize(text):
    groups = collections.defaultdict(lambda: collections.defaultdict(list))
    for line in text.splitlines():
        fields = dict(re.findall(r"(scenario|stage|ms|resident|intervalMs|missingCells)=([^\s]+)", line))
        if "stage" in fields and "scenario" in fields:
            groups[fields["scenario"]][fields["stage"]].append(fields)
    result = {}
    for scenario, stages in groups.items():
        rows = {}
        for stage, samples in stages.items():
            times = sorted(float(x["ms"]) for x in samples if "ms" in x)
            rows[stage] = {"samples": len(samples)}
            if times:
                rows[stage].update(median_ms=statistics.median(times),
                                   p95_ms=times[max(0, math.ceil(len(times) * .95) - 1)], max_ms=times[-1])
        frames = stages.get("grid-frame", [])
        result[scenario] = {
            "stages": rows,
            "network_requests": len(stages.get("network-request", [])),
            "deduplicated_consumers": len(stages.get("deduplicated", [])),
            "peak_observed_resident_bytes": max((int(x.get("resident", 0)) for v in stages.values() for x in v), default=0),
            "frames_over_25ms": sum(float(x.get("intervalMs", 0)) > 25 for x in frames),
            "frames_with_missing_cells": sum(int(x.get("missingCells", 0)) > 0 for x in frames),
        }
    return result


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("Usage: python Tests/summarize_grid_trace.py exported-console-log.txt")
    print(json.dumps(summarize(Path(sys.argv[1]).read_text(encoding="utf-8-sig")), ensure_ascii=False, indent=2))
