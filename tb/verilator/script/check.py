#!/usr/bin/env python3
"""Run real Spike firmware against RTL, checking pixels, counters, and replay."""
import csv
import json
from pathlib import Path
import struct
import subprocess
import zlib
from video import animate, chunks

ROOT = Path(__file__).resolve().parents[1]
BINARY = ROOT/"build/obj/Vprisma_tb_top"


def pixels(path):
    parts = list(chunks(path))
    header = next(data for tag, data in parts if tag == b"IHDR")
    width, height, depth, kind, *_ = struct.unpack(">IIBBBBB", header)
    assert (depth, kind) == (8, 2)
    raw = zlib.decompress(b"".join(data for tag, data in parts if tag == b"IDAT"))
    stride = width*3+1
    assert len(raw) == stride*height
    assert all(raw[y*stride] == 0 for y in range(height))
    return width, height, b"".join(raw[y*stride+1:(y+1)*stride] for y in range(height))


def run(name, app, frames=2, count=8, extra=(), fail=False, expected_frames=None):
    out = ROOT/"out/checks"/name
    out.mkdir(parents=True, exist_ok=True)
    command = [str(BINARY), f"+firmware={ROOT/'build/app'/f'{app}.elf'}", f"+out={out}",
               f"+frames={frames}", f"+triangles={count}", "+seed=11", "+timing_seed=7",
               "+max_cycles=20000000", *extra]
    with (out/"process.log").open("w") as log:
        process = subprocess.run(command, stdout=log, stderr=subprocess.STDOUT, timeout=300, cwd=ROOT)
    assert (process.returncode != 0) == fail, f"{name}: see {out/'process.log'}"
    summary = json.loads((out/"summary.json").read_text())
    if fail:
        assert summary["result"] != 0
        print(f"PASS {name}: failure reported", flush=True)
        return [], out
    if expected_frames is None:
        expected_frames=frames
    assert summary["result"] == 0 and summary["frames"] == expected_frames
    rows = list(csv.DictReader((out/"frames.csv").open()))
    assert len(rows) == expected_frames
    for row in rows:
        width, height, rgb = pixels(out/f"frame_{int(row['frame']):06d}.png")
        assert (width, height) == (int(row["width"]), int(row["height"]))
        assert zlib.crc32(rgb) == int(row["crc32"])
        assert int(row["ge_output_triangles"]) == int(row["re_input_triangles"])
        assert int(row["re_input_triangles"]) == int(row["re_done_triangles"])
        if app.startswith("benchmark/"):
            assert int(row["ge_input_words"]) == 4*count
        assert int(row["framebuffer_write_pixels"]) == int(row["output_pixels"])
        assert int(row["full_cycles"]) >= int(row["cycles"])
        assert int(row["memory_errors"]) == int(row["setup_errors"]) == int(row["ge_errors"]) == 0
        assert int(row["frames"]) == 1 and int(row["cycles"]) > 0
    assert (out/"latest.png").read_bytes() == (out/f"frame_{expected_frames:06d}.png").read_bytes()
    print(f"PASS {name}: {expected_frames} frames", flush=True)
    return rows, out


def main():
    features, feature_out = run("features", "features", frames=4, expected_frames=20)
    phases = {i: [r for r in features if int(r["phase"]) == i] for i in range(1,6)}
    for phase in (1,2,4,5):
        assert all(int(r["output_pixels"]) > 1000 for r in phases[phase])
    assert len({r["crc32"] for r in phases[1]}) > 1
    clipping = [int(r["output_pixels"]) for r in phases[3]]
    assert clipping[0] > 1000 and clipping[-1] == 0
    assert all(a >= b for a,b in zip(clipping,clipping[1:]))
    for row in phases[5]:
        assert int(row["blend_read_requests"]) == int(row["output_pixels"])
        width,height,rgb = pixels(feature_out/f"frame_{int(row['frame']):06d}.png")
        middle = ((height//2)*width+width//2)*3
        assert rgb[middle:middle+3] == bytes((85,119,153))
    width,height,rgb = pixels(feature_out/"frame_000013.png")
    for x,color in ((width*3//8,(255,34,34)),(width*5//8,(34,204,255))):
        offset=(height//2*width+x)*3
        assert rgb[offset:offset+3] == bytes(color), (x,rgb[offset:offset+3])
    for number in (1,5):
        _,_,rgb = pixels(feature_out/f"frame_{number:06d}.png")
        colors={rgb[i:i+3] for i in range(0,len(rgb),3)}
        assert bytes((255,255,204)) in colors and bytes((17,68,136)) in colors
    feature_video=animate(feature_out,scene_ms=10000)
    feature_delays=[struct.unpack(">IIIIIHHBB",data)[5:7] for tag,data in chunks(feature_video) if tag==b"fcTL"]
    assert len(feature_delays)==20 and sum(a/b for a,b in feature_delays)==50
    direct, direct_out = run("direct", "benchmark/scene", frames=1, count=96)
    buffered, _ = run("buffered", "benchmark/buffered", frames=1, count=96)
    assert direct[0]["crc32"] == buffered[0]["crc32"]
    assert int(direct[0]["ge_write_bytes"]) == 0
    assert int(buffered[0]["ge_write_bytes"]) == int(buffered[0]["ge_output_triangles"])*64
    slow, _ = run("slow_memory", "benchmark/scene", frames=1, count=96,
                  extra=("+latency=25", "+gap=8", "+timing_seed=19"))
    assert direct[0]["crc32"] == slow[0]["crc32"]
    replay, _ = run("replay", "benchmark/scene", frames=1, count=96)
    assert all(direct[0][k] == replay[0][k] for k in direct[0] if k != "host_fps")
    for app,count in (("micro",1024),("fill",512),("clip",512),("textured",256)):
        rows,_=run(app,"benchmark/"+app,frames=1,count=count)
        assert int(rows[0]["output_pixels"]) > 0
        if app == "clip": assert int(rows[0]["clip_discarded_triangles"]) > 0
    depth,_=run("depth","benchmark/depth",frames=2,count=384)
    assert int(depth[0]["z_rejected_pixels"]) > 0 and int(depth[1]["z_rejected_pixels"]) == 0
    run("empty_direct", "benchmark/scene", count=0)
    run("empty_buffered", "benchmark/buffered", count=0)
    run("vga", "benchmark/micro", frames=1, count=32, extra=("+width=640",))
    model,_=run("model","model",frames=4)
    assert all(int(r["output_pixels"]) > 5000 for r in model)
    assert len({r["crc32"] for r in model}) > 1
    game, game_out = run("game", "game", frames=4, extra=("+autopilot=1",))
    assert all(int(r["output_pixels"]) > 1000 for r in game)
    assert all(int(r["ge_input_words"]) < 188*4 for r in game)
    assert len({r["crc32"] for r in game}) > 1
    video = animate(game_out)
    parts = list(chunks(video))
    assert next(data for tag, data in parts if tag == b"acTL") == struct.pack(">II", 4, 0)
    assert len([tag for tag, _ in parts if tag == b"fcTL"]) == 4
    run("cycle_limit", "benchmark/micro", extra=("+max_cycles=100",), fail=True)
    print(f"PASS all checks; features: {feature_out}; comparison: {direct_out}; animation: {video}")


if __name__ == "__main__":
    main()
