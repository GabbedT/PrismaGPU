#!/usr/bin/env python3
"""Build once, run isolated tests, and retain logs and reproduction commands."""

import json
import math
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import time

HERE = Path(__file__).resolve().parent
REGISTRY = re.search(
    r"test_names\[\]\s*=\s*\{(.*?)\};",
    (HERE / "sw/triangle_gen.c").read_text(),
    re.DOTALL,
).group(1)
TESTS = re.findall(r'"([a-z_]+)"', REGISTRY)

# Defaults live in the Makefile; this runner validates its exported settings.
INTEGER_LIMITS = {
    "SEED": (0, 2**32 - 1),
    "TIMING_SEED": (0, 2**32 - 1),
    "CASES": (1, 1000000),
    "VERBOSE": (0, 2),
    "TIMEOUT": (1, 2**32 - 1),
    "WALL_TIMEOUT": (1, 86400),
    "LATENCY": (0, 1000000),
    "PAUSE": (0, 100),
    "OUTPUT_HOLD": (0, 2**32 - 1),
    "WAVE": (0, 1),
}
TOLERANCES = ("XY_TOL", "Z_TOL", "UV_TOL", "COLOR_TOL", "W_TOL")


def configuration(environ):
    keys = ["MODE", "TEST", "OUT", *INTEGER_LIMITS, *TOLERANCES]
    cfg = {key: environ[key] for key in keys}

    if cfg["MODE"] not in ("standalone", "spike"):
        raise ValueError("MODE must be standalone or spike")
    if cfg["TEST"] not in TESTS:
        raise ValueError(f"unknown TEST={cfg['TEST']}; use make list")

    for key, (low, high) in INTEGER_LIMITS.items():
        if not re.fullmatch(r"[0-9]+", cfg[key]) or not low <= int(cfg[key]) <= high:
            raise ValueError(f"{key} must be an integer in [{low}, {high}]")

    for key in TOLERANCES:
        value = float(cfg[key])
        if not math.isfinite(value) or value < 0:
            raise ValueError(f"{key} must be finite and nonnegative")

    return cfg


def reproduce(cfg, name, timing_seed):
    settings = dict(cfg, TEST=name, TIMING_SEED=str(timing_seed))
    for key in ("SPIKE_DIR", "SPIKE_INCLUDE", "SPIKE_LIB", "RISCV_CC", "VERILATOR"):
        if key in os.environ:
            settings[key] = os.environ[key]

    return shlex.join(
        ["make", "-C", str(HERE), "test"]
        + [f"{key}={value}" for key, value in settings.items()]
    )


def invocation(cfg, name, timing_seed, wave, output):
    arguments = [
        str(HERE / "build" / cfg["MODE"] / "obj/Vtb_top"),
        cfg["MODE"],
        name,
        cfg["SEED"],
        str(timing_seed),
    ]
    settings = (
        "CASES",
        "VERBOSE",
        "TIMEOUT",
        "LATENCY",
        "PAUSE",
        "OUTPUT_HOLD",
        *TOLERANCES,
    )
    arguments += [cfg[key] for key in settings]
    firmware = HERE / "build" / cfg["MODE"] / "firmware.elf"
    arguments += [str(wave), str(firmware), str(output)]
    return arguments


def execute(command, timeout):
    try:
        process = subprocess.run(
            command,
            cwd=HERE,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=timeout,
        )
        return process.returncode, process.stdout

    except subprocess.TimeoutExpired as error:
        output = error.stdout or b""
        if isinstance(output, bytes):
            output = output.decode(errors="replace")
        return 124, output + f"\nFAIL phase=wall_timeout limit={timeout}s\n"

    except OSError as error:
        return 127, f"FAIL phase=launch {error}\n"


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "test"
    if action == "list":
        print("\n".join(TESTS))
        return 0
    if action not in ("test", "regression"):
        raise ValueError(f"unknown action: {action}")

    cfg = configuration(os.environ)
    run_dir = Path(cfg["OUT"]).resolve() / f"{time.time_ns()}-{cfg['MODE']}"
    run_dir.mkdir(parents=True)
    print(f"[runner] build mode={cfg['MODE']} artifacts={run_dir}", flush=True)

    with (run_dir / "build.log").open("w") as log:
        build = subprocess.run(
            ["make", "--no-print-directory", "build", f"MODE={cfg['MODE']}"],
            cwd=HERE,
            stdout=log,
            stderr=subprocess.STDOUT,
        )

    if build.returncode:
        print((run_dir / "build.log").read_text()[-12000:])
        print(f"FAIL phase=build exit={build.returncode}; no tests executed")
        print("Reproduce: " + reproduce(cfg, cfg["TEST"], cfg["TIMING_SEED"]))
        return 1

    selected = TESTS if action == "regression" else [cfg["TEST"]]
    seeds = [int(cfg["TIMING_SEED"])]
    if action == "regression":
        seeds.append((seeds[0] + 1) % 2**32)

    results = []
    for name in selected:
        reference = None
        for timing in seeds:
            stem = f"{name}-g{cfg['SEED']}-t{timing}"
            wave = run_dir / (stem + ".fst") if cfg["WAVE"] == "1" else "-"
            output_file = run_dir / (stem + ".bin")
            command = invocation(cfg, name, timing, wave, output_file)
            replay = reproduce(cfg, name, timing)

            print(f"[runner] RUN {name} seed={cfg['SEED']} timing_seed={timing}", flush=True)
            code, output = execute(command, int(cfg["WALL_TIMEOUT"]))

            if code == 0:
                data = output_file.read_bytes()
                if reference is None:
                    reference = data
                elif data != reference:
                    code = 1
                    output += "FAIL phase=timing_invariance field=output_bits tolerance=0\n"
                    output += "Reference: " + reproduce(cfg, name, seeds[0]) + "\n"

            (run_dir / (stem + ".log")).write_text(output)
            print(output, end="" if output.endswith("\n") else "\n", flush=True)

            results.append({
                "test": name,
                "timing_seed": timing,
                "exit_code": code,
                "log": stem + ".log",
                "reproduce": replay,
            })
            (run_dir / "results.json").write_text(
                json.dumps(dict(config=cfg, results=results), indent=2) + "\n"
            )

            print(f"[runner] {'FAIL' if code else 'PASS'} {name} timing_seed={timing}")
            if code:
                print("Reproduce: " + replay)

    failed = [result for result in results if result["exit_code"]]
    print(
        f"[runner] SUMMARY passed={len(results) - len(failed)} failed={len(failed)} "
        f"total={len(results)} artifacts={run_dir}"
    )
    for result in failed:
        print(
            f"FAIL {result['test']} timing_seed={result['timing_seed']} exit={result['exit_code']}\n"
            f"  {result['reproduce']}"
        )

    return int(bool(failed))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, ValueError, OSError) as error:
        print(f"FAIL phase=configuration {error}; invoke through make", file=sys.stderr)
        sys.exit(2)
