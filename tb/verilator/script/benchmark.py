#!/usr/bin/env python3
"""Run substantial GPU workloads and write a reproducible performance report."""
import argparse
import csv
import json
from pathlib import Path
import subprocess
from performance import measure, table

ROOT=Path(__file__).resolve().parents[1]


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--triangles",type=int,default=1024)
    parser.add_argument("--frames",type=int,default=2)
    parser.add_argument("--width",type=int,default=320)
    parser.add_argument("--seed",type=int,default=1)
    parser.add_argument("--timing-seed",type=int,default=2)
    args=parser.parse_args()
    if not 1<=args.triangles<=4096 or args.frames<1:
        parser.error("use 1..4096 triangles and at least one frame")
    out=ROOT/"out/benchmark_suite"
    out.mkdir(parents=True,exist_ok=True)
    metrics={}
    crc={}
    for name in ("micro","fill","depth","clip","textured","scene","buffered","fill_slow"):
        app="fill" if name=="fill_slow" else name
        directory=out/name
        directory.mkdir(exist_ok=True)
        command=[str(ROOT/"build/obj/Vprisma_tb_top"),f"+firmware={ROOT/'build/app/benchmark'/app}.elf",
                 f"+out={directory}",f"+triangles={args.triangles}",f"+frames={args.frames}",
                 f"+width={args.width}",f"+seed={args.seed}",f"+timing_seed={args.timing_seed}"]
        if name=="fill_slow": command += ["+latency=20","+gap=5"]
        print(f"RUN {name}: {args.triangles} triangles x {args.frames} frames",flush=True)
        with (directory/"process.log").open("w") as log:
            subprocess.run(command,stdout=log,stderr=subprocess.STDOUT,check=True,cwd=ROOT,timeout=1800)
        rows=list(csv.DictReader((directory/"frames.csv").open()))
        assert len(rows)==args.frames
        assert all(int(r["memory_errors"])==int(r["setup_errors"])==int(r["ge_errors"])==0 for r in rows)
        assert all(int(r["re_done_triangles"])==int(r["ge_output_triangles"]) for r in rows)
        crc[name]=[r["crc32"] for r in rows]
        if name=="depth":
            for phase,label in ((104,"depth_front"),(105,"depth_back")):
                selected=[r for r in rows if int(r["phase"])==phase]
                if selected: metrics[label]=measure(directory,selected)
        else: metrics[name]=measure(directory,rows)
        print(table({k:v for k,v in metrics.items() if k.startswith(name)}),flush=True)
    assert crc["scene"]==crc["buffered"],"primitive source changes rendered pixels"
    assert crc["fill"]==crc["fill_slow"],"memory timing changes rendered pixels"
    report=("# PrismaGPU measured benchmark suite\n\n"
            f"320/640 viewport: {args.width} x {args.width*3//4}; input={args.triangles}; "
            f"frames={args.frames}; seed={args.seed}; timing_seed={args.timing_seed}.\n\n"
            "100 MHz assumption, DDR base latency 3 + seeded 0..7 jitter, gap 1; "
            "fill_slow uses latency 20, gap 5. Spike quantum 64.\n\n"+table(metrics)+
            "\nRender FPS includes GE/RE and primitive storage; full-frame also includes firmware "
            "construction, clears and upload under the functional Spike scheduling model. "
            "Neither is measured FPGA timing. Host FPS is wall-clock simulator throughput. "
            "Bus bytes count full 16-byte RE transfers plus GE traffic; interfaces have independent capacity.\n\n"
            "Stall/occupancy percentages overlap and must not be summed. See report.json for all values.\n")
    (out/"report.md").write_text(report)
    (out/"report.json").write_text(json.dumps({"settings":vars(args),"measurements":metrics},indent=2)+"\n")
    print(report)
    print(f"Saved {out/'report.md'}")


if __name__ == "__main__":
    main()
