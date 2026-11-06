#!/usr/bin/env python3
"""Assemble completed PNG frames into an APNG animation without extra packages."""
import argparse
import csv
from collections import Counter
from fractions import Fraction
from pathlib import Path
import struct
import zlib


def chunks(path):
    data = Path(path).read_bytes()
    if data[:8] != b"\x89PNG\r\n\x1a\n":
        raise ValueError(f"Not PNG: {path}")
    offset = 8
    while offset < len(data):
        size, = struct.unpack_from(">I", data, offset)
        tag = data[offset+4:offset+8]
        payload = data[offset+8:offset+8+size]
        crc, = struct.unpack_from(">I", data, offset+8+size)
        if zlib.crc32(tag+payload) != crc:
            raise ValueError(f"PNG CRC failure: {path}")
        yield tag, payload
        offset += size+12


def chunk(tag, payload):
    return struct.pack(">I", len(payload))+tag+payload+struct.pack(">I", zlib.crc32(tag+payload))


def animate(directory, fps=30, scene_ms=None):
    directory = Path(directory)
    rows = list(csv.DictReader((directory/"frames.csv").open()))
    if not rows:
        raise ValueError("No completed frames")
    if not 1 <= fps <= 65535:
        raise ValueError("FPS must be 1..65535")
    phases = Counter(row.get("phase") for row in rows)
    if scene_ms is not None:
        if not 1 <= scene_ms <= 600000 or not all(i in {"1","2","3","4","5"} for i in phases):
            raise ValueError("Scene timing requires feature phases 1..5 and a duration of 1..600000 ms")
    result = bytearray(b"\x89PNG\r\n\x1a\n")
    sequence = 0
    header = None
    for index, row in enumerate(rows):
        parts = list(chunks(directory/f"frame_{int(row['frame']):06d}.png"))
        ihdr = next(payload for tag, payload in parts if tag == b"IHDR")
        width, height = struct.unpack(">II", ihdr[:8])
        if header is None:
            header = ihdr
            result += chunk(b"IHDR", header)
            result += chunk(b"acTL", struct.pack(">II", len(rows), 0))
        elif header != ihdr:
            raise ValueError("Animation frames must have the same format and dimensions")
        delay = Fraction(scene_ms,1000*phases[row["phase"]]) if scene_ms is not None else Fraction(1,fps)
        delay = delay.limit_denominator(65535)
        result += chunk(b"fcTL", struct.pack(">IIIIIHHBB", sequence, width, height, 0, 0,
                                            delay.numerator, delay.denominator, 0, 0))
        sequence += 1
        compressed = b"".join(payload for tag, payload in parts if tag == b"IDAT")
        if index == 0:
            result += chunk(b"IDAT", compressed)
        else:
            result += chunk(b"fdAT", struct.pack(">I", sequence)+compressed)
            sequence += 1
    result += chunk(b"IEND", b"")
    target = directory/"video.apng"
    target.write_bytes(result)
    return target


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--fps", type=int, default=30, help="Playback FPS; unrelated to measured hardware FPS")
    parser.add_argument("--scene-ms", type=int, help="Allocate this playback duration to EACH feature scene")
    args = parser.parse_args()
    print(animate(args.directory, args.fps, args.scene_ms))
