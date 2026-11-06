#!/usr/bin/env python3
"""Summarize measured RTL counters; rates assume the recorded GPU clock."""
import argparse
import csv
import json
from pathlib import Path


def measure(directory, rows=None):
    directory=Path(directory)
    summary=json.loads((directory/"summary.json").read_text())
    if rows is None:
        rows=list(csv.DictReader((directory/"frames.csv").open()))
    assert summary["result"] == 0 and rows
    hz=summary.get("gpu_hz",100_000_000)
    totals={key:sum(int(r[key]) for r in rows) for key in rows[0]
            if key not in ("model_fps","host_fps")}
    cycles=totals["cycles"]
    full=totals.get("full_cycles",summary["counters"]["cycles"])
    frames=len(rows)
    waits={name:100*totals[name]/cycles for name in (
        "ge_raster_stall_cycles","pixel_backpressure_cycles","setup_busy_cycles",
        "ddr_read_pending_cycles","ddr_write_pending_cycles")}
    for name in ("setup_compute_cycles","setup_wait_raster_cycles"):
        if name in totals: waits[name]=100*totals[name]/cycles
    bus_bytes=16*(totals["ddr_read_beats"]+totals["ddr_write_beats"])+totals["ge_read_bytes"]+totals["ge_write_bytes"]
    return {"frames":frames,"cycles_per_frame":cycles/frames,"render_fps":hz*frames/cycles,
            "full_frame_fps":hz*frames/full,"host_fps":frames/sum(1/float(r["host_fps"]) for r in rows),
            "input_triangles_per_frame":totals["ge_input_words"]/(4*frames),
            "generated_triangles_per_frame":totals["ge_output_triangles"]/frames,
            "input_mtriangles_s":totals["ge_input_words"]*.25*hz/cycles/1e6,
            "mpixels_s":totals["output_pixels"]*hz/cycles/1e6,
            "z_rejects_per_frame":totals["z_rejected_pixels"]/frames,
            "bus_bytes_per_frame":bus_bytes/frames,"wait_percent":waits,
            "instructions_per_frame":totals["cpu_instructions"]/frames if "cpu_instructions" in totals else summary["instructions"]/summary["frames"],
            "gpu_hz":hz,"source":str(directory)}


def table(measurements):
    lines=["| Workload | Input tri/frame | Cycles/frame | Render FPS | Full-frame FPS | Mtri/s | Mpixel/s | GPU bus KiB/frame | Host FPS |",
           "|---|---:|---:|---:|---:|---:|---:|---:|---:|"]
    for name,m in measurements.items():
        lines.append(f"| {name} | {m['input_triangles_per_frame']:.0f} | {m['cycles_per_frame']:.0f} | "
                     f"{m['render_fps']:.1f} | {m['full_frame_fps']:.1f} | {m['input_mtriangles_s']:.3f} | "
                     f"{m['mpixels_s']:.2f} | {m['bus_bytes_per_frame']/1024:.1f} | {m['host_fps']:.2f} |")
    return "\n".join(lines)+"\n"


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directories",nargs="+",type=Path)
    args=parser.parse_args()
    print(table({d.name:measure(d) for d in args.directories}))
    print("Render excludes clear/upload; full-frame includes them and Spike scheduling. "
          "Host FPS is simulator speed, not hardware. GPU bus bytes sum the independent GE/RE interfaces.")


if __name__ == "__main__":
    main()
