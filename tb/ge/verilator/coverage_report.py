"""Aggregate verified triangle bins and Verilator RTL coverage artifacts."""

import json
from pathlib import Path
import re


PLANES = ("left", "right", "top", "bottom", "far", "near")
STATES = ("inside", "outside", "on_plane")
COVERAGE_PREFIXES = ("[triangle_coverage] ", "[triangle_coverage_cross] ")
BIN_LABELS = {
    "verified_triangles": ["verified"],
    "output_triangles": [str(i) for i in range(8)],
    "culling": [f"front_{front}/cull_{mode}" for front in range(2)
                for mode in ("none", "front", "back")],
    "input_winding": ["cw", "ccw", "zero_area"],
    "matrix": ["identity", "transformed"],
    "viewport_parity": ["both_even", "at_least_one_odd"],
}
for plane in PLANES:
    BIN_LABELS[f"plane_{plane}"] = [
        "/".join(STATES[(index // weight) % 3] for weight in (1, 3, 9))
        for index in range(27)
    ]
BIN_LABELS["culling_winding"] = [
    f"{winding}/{setting}" for winding in BIN_LABELS["input_winding"]
    for setting in BIN_LABELS["culling"]
]


def triangle_counts(output):
    counts = None
    snapshot = {}
    for line in output.splitlines():
        if not line.startswith(COVERAGE_PREFIXES):
            continue
        try:
            record = json.loads(line.split(" ", 1)[1])
        except json.JSONDecodeError:
            # A timeout can interrupt printing the next checkpoint.
            if counts is not None and not line.rstrip().endswith("}"):
                break
            raise
        group, values = record["group"], record["counts"]
        if group not in BIN_LABELS or len(values) != len(BIN_LABELS[group]):
            raise ValueError(f"invalid triangle coverage group: {group}")
        if group == "verified_triangles":
            snapshot = {}
        if group in snapshot or any(type(value) is not int or value < 0 for value in values):
            raise ValueError(f"invalid triangle coverage counters: {group}")
        snapshot[group] = values
        if set(snapshot) == set(BIN_LABELS):
            counts = snapshot.copy()
    if counts is None:
        raise ValueError("missing triangle coverage counters")
    return counts


def bin_summary(labels, counts):
    return {
        "hit": sum(count > 0 for count in counts),
        "total": len(labels),
        "bins": dict(zip(labels, counts)),
        "missing": [label for label, count in zip(labels, counts) if not count],
    }


def rtl_summary(data_file, rtl_root):
    """Count instrumentation points, keeping line/branch and toggle separate.

    Verilator's .dat format uses control-A between fields and control-B between
    keys and values. Aggregate data has already merged matching instances.
    """
    files = {}
    for line in data_file.read_text().splitlines():
        match = re.fullmatch(r"C '(.*)' ([0-9]+)", line)
        if not match:
            continue
        fields = dict(part.split("\x02", 1) for part in match[1].split("\x01")
                      if "\x02" in part)
        source = Path(fields["f"]).resolve()
        if not source.is_relative_to(rtl_root):
            continue
        kind = fields.get("t", "")
        # The type can be explicit or encoded as the page prefix.
        kind = kind or fields.get("page", "").split("/", 1)[0]
        name = str(source.relative_to(rtl_root.parent))
        points = files.setdefault(name, {}).setdefault(kind, {"hit": 0, "total": 0})
        points["total"] += 1
        points["hit"] += int(match[2]) >= int(fields.get("s", 1))

    totals = {}
    for kinds in files.values():
        for kind, points in kinds.items():
            total = totals.setdefault(kind, {"hit": 0, "total": 0})
            for key in ("hit", "total"):
                total[key] += points[key]
    if not totals:
        raise ValueError("no hardware RTL coverage points found")
    return {"totals": totals, "files": files}


def rate(points):
    hit, total = points["hit"], points["total"]
    return f"{hit}/{total} ({100 * hit / total:.1f}%)" if total else "0/0"


def write_reports(run_dir, results, tests, rtl=None, errors=()):
    totals = {group: [0] * len(labels) for group, labels in BIN_LABELS.items()}
    measured = 0
    stalls = {"input_stalls": 0, "output_stalls": 0}
    for result in results:
        counters = result.get("triangle_coverage")
        if counters:
            measured += 1
            for group, values in counters.items():
                totals[group] = [a + b for a, b in zip(totals[group], values)]
        for key in stalls:
            stalls[key] += result.get("stalls", {}).get(key, 0)

    categories = bin_summary(tests, [sum(r["test"] == test and r["exit_code"] == 0
                                       for r in results) for test in tests])
    functional = {group: bin_summary(BIN_LABELS[group], counts)
                  for group, counts in totals.items()}
    random_verified = {}
    for result in results:
        if result["test"] == "random" and "seed" in result:
            seed = result["seed"]
            counts = (result.get("triangle_coverage") or {}).get("verified_triangles", [0])
            random_verified[seed] = max(random_verified.get(seed, 0), counts[0])
    report = {
        "complete": measured == len(results) and not errors
                    and all(r["exit_code"] == 0 for r in results),
        "measured_runs": measured,
        "total_runs": len(results),
        "categories": categories,
        "triangles": functional,
        "functional_goals_met": all(points["hit"] == points["total"]
                                    for group, points in functional.items()
                                    if group != "verified_triangles"),
        "random_geometry_seeds": sorted(random_verified),
        "unique_random_verified": sum(random_verified.values()),
        "stalls": stalls,
        "rtl": rtl,
        "errors": list(errors),
    }
    (run_dir / "coverage.json").write_text(json.dumps(report, indent=2) + "\n")
    text = ["# Geometry Engine coverage", "",
            f"Execution: {'complete' if report['complete'] else 'incomplete / failed runs'}.",
            f"Functional coverage goals met: {report['functional_goals_met']}.",
            f"Random geometry seeds: {report['random_geometry_seeds']}.",
            f"Unique verified random inputs: {report['unique_random_verified']}.",
            f"Measured runs: {measured}/{len(results)}. "
            f"Verified input triangles: {totals['verified_triangles'][0]}.", "",
            "Counts include both timing-seed runs and batch duplicates. Only triangles",
            "whose RTL comparisons and integrity checks passed are credited. Reset",
            "attempts interrupted before completion are excluded. Failed or killed",
            "processes contribute their last complete checkpoint; later activity",
            "may be absent from these totals.", "",
            "## Triangle cases", "", "| Group | Bins hit |", "|---|---:|",
            f"| Passing test categories | {rate(categories)} |"]
    for group, points in functional.items():
        if group != "verified_triangles":
            text.append(f"| {group} | {rate(points)} |")
    text += ["", "Plane bins classify the three transformed Q16.16 vertices before",
             "clipping: inside, outside, or on-plane (index = a + 3*b + 9*c).",
             "Input winding uses decoded XY before matrix/viewport transforms.",
             "These are coverage goals, not an assertion that every bin is reachable",
             "with the current generator. `coverage.json` lists every count and missing bin.", "",
             f"Observed stall cycles: input={stalls['input_stalls']}, "
             f"output={stalls['output_stalls']}.", "", "## RTL code coverage", ""]
    if rtl is None:
        text += ["RTL coverage unavailable. Enable it with `COVERAGE=1` or `make coverage`."]
    else:
        text += ["Only sources under `hw/` contribute to these totals. Initial startup",
                 "reset is excluded; later test resets and failing simulations contribute.",
                 "Line coverage counts Verilator instrumentation points, including branch",
                 "paths; toggle coverage counts bit transitions. This is RTL coverage,",
                 "not host C/C++ coverage.", "", "| Type | Points hit |", "|---|---:|"]
        for kind, points in sorted(rtl["totals"].items()):
            text.append(f"| {kind} | {rate(points)} |")
        kinds = sorted(rtl["totals"])
        text += ["", "| RTL source | " + " | ".join(kinds) + " |",
                 "|---|" + "---:|" * len(kinds)]
        for source, points in sorted(rtl["files"].items()):
            text.append(f"| {source} | " + " | ".join(
                rate(points.get(kind, {"hit": 0, "total": 0})) for kind in kinds) + " |")
        text += ["", "Artifacts: `coverage.dat` (merged), `coverage.info` (LCOV),",
                 "and `annotated/` (sources with uncovered points marked)."]
    if errors:
        text += ["", "Errors:", ""] + [f"- {error}" for error in errors]
    (run_dir / "coverage.md").write_text("\n".join(text) + "\n")
    return report
