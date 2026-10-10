#!/usr/bin/env python3
"""Build once, run isolated tests, and retain reports and failure diagnostics."""

import json
import hashlib
import codecs
import math
import os
from pathlib import Path
import re
import shlex
import selectors
import subprocess
import sys
import time

from coverage_report import triangle_counts, rtl_summary, write_reports, rate, COVERAGE_PREFIXES

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
    "SEEDS": (1, 1000000),
    "TIMING_SEED": (0, 2**32 - 1),
    "CASES": (1, 1000000),
    "VERBOSE": (0, 2),
    "TIMEOUT": (1, 2**32 - 1),
    "WALL_TIMEOUT": (1, 86400),
    "LATENCY": (0, 1000000),
    "PAUSE": (0, 100),
    "OUTPUT_HOLD": (0, 2**32 - 1),
    "WAVE": (0, 1),
    "COVERAGE": (0, 1),
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
        if key == "WALL_TIMEOUT" and cfg[key] == "auto":
            # Large random campaigns need a process budget proportional to cases.
            cfg[key] = str(max(300, (int(cfg["CASES"]) + 19) // 20))
        if not re.fullmatch(r"[0-9]+", cfg[key]) or not low <= int(cfg[key]) <= high:
            raise ValueError(f"{key} must be an integer in [{low}, {high}]")

    for key in TOLERANCES:
        value = float(cfg[key])
        if not math.isfinite(value) or value < 0:
            raise ValueError(f"{key} must be finite and nonnegative")

    return cfg


def reproduce(cfg, name, timing_seed):
    settings = dict(cfg, TEST=name, TIMING_SEED=str(timing_seed))
    for key in ("SPIKE_DIR", "SPIKE_INCLUDE", "SPIKE_LIB", "RISCV_CC", "VERILATOR",
                "VERILATOR_COVERAGE"):
        if key in os.environ:
            settings[key] = os.environ[key]

    return shlex.join(
        ["make", "-C", str(HERE), "test"]
        + [f"{key}={value}" for key, value in settings.items()]
    )


def invocation(cfg, name, timing_seed, wave, output, coverage):
    build_name = cfg["MODE"] + ("-coverage" if cfg["COVERAGE"] == "1" else "")
    arguments = [
        str(HERE / "build" / build_name / "obj/Vtb_top"),
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
    firmware = HERE / "build" / build_name / "firmware.elf"
    arguments += [str(wave), str(firmware), str(output), str(coverage)]
    return arguments


def execute_streamed(command, timeout, on_line, on_wait):
    """Drain the pipe while running, retaining output for coverage and failures."""
    parts = []
    pending = ""
    decoder = codecs.getincrementaldecoder("utf-8")(errors="replace")
    started = time.monotonic()
    heartbeat = started + 10
    timed_out = False

    def consume(data, final=False):
        nonlocal pending
        decoded = decoder.decode(data, final=final)
        parts.append(decoded)
        pending += decoded
        while "\n" in pending:
            line, pending = pending.split("\n", 1)
            if on_line:
                on_line(line + "\n")
        if final and pending:
            if on_line:
                on_line(pending)
            pending = ""

    try:
        with subprocess.Popen(command, cwd=HERE, stdout=subprocess.PIPE,
                              stderr=subprocess.STDOUT) as process:
            try:
                with selectors.DefaultSelector() as selector:
                    selector.register(process.stdout, selectors.EVENT_READ)
                    os.set_blocking(process.stdout.fileno(), False)
                    while selector.get_map() or process.poll() is None:
                        now = time.monotonic()
                        if now - started >= timeout:
                            timed_out = True
                            process.kill()
                            break
                        if now >= heartbeat:
                            if on_wait:
                                on_wait()
                            heartbeat = now + 10
                        delay = max(0, min(started + timeout, heartbeat) - now)
                        if selector.get_map():
                            for key, _ in selector.select(delay):
                                chunk = os.read(key.fd, 65536)
                                if chunk:
                                    consume(chunk)
                                else:
                                    selector.unregister(key.fileobj)
                        else:
                            # A process may close stdout before it exits.
                            try:
                                process.wait(timeout=delay)
                            except subprocess.TimeoutExpired:
                                pass
                os.set_blocking(process.stdout.fileno(), True)
                tail, _ = process.communicate()
                consume(tail or b"", final=True)
                code = 124 if timed_out else process.returncode
            finally:
                if process.poll() is None:
                    process.kill()
                    process.wait()
        output = "".join(parts)
        if timed_out:
            output += f"\nFAIL phase=wall_timeout limit={timeout}s\n"
        return code, output
    except OSError as error:
        return 127, "".join(parts) + f"FAIL phase=launch {error}\n"


def execute(command, timeout, on_line=None, on_wait=None):
    if on_line is not None or on_wait is not None:
        return execute_streamed(command, timeout, on_line, on_wait)
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


class RunMonitor:
    """Expose the latest verified checkpoint while a simulator is running."""

    def __init__(self, cfg, name, timing, log):
        self.name = name
        self.seed = cfg["SEED"]
        self.timing = timing
        self.total = int(cfg["CASES"]) if name == "random" else None
        self.log = log
        self.started = time.monotonic()
        self.verified = 0
        self.rate = 0

    def progress(self):
        elapsed = time.monotonic() - self.started
        count = str(self.verified)
        estimate = ""
        if self.total:
            count += f"/{self.total} ({100 * self.verified / self.total:.1f}%)"
            if self.rate:
                remaining = max(0, self.total - self.verified) / self.rate
                estimate = f" rate={self.rate:.1f}/s eta~{remaining:.0f}s"
        print(f"[runner] PROGRESS {self.name} seed={self.seed} timing_seed={self.timing} "
              f"verified={count} elapsed={elapsed:.0f}s{estimate}", flush=True)

    def line(self, line):
        self.log.write(line)
        self.log.flush()
        if line.startswith(COVERAGE_PREFIXES):
            try:
                record = json.loads(line.split(" ", 1)[1])
                if record.get("group") == "verified_triangles":
                    count = record["counts"][0]
                    changed = count != self.verified
                    self.verified = count
                    elapsed = time.monotonic() - self.started
                    self.rate = count / elapsed if elapsed > 0 else 0
                    if self.total and changed:
                        self.progress()
            except (ValueError, KeyError, IndexError, TypeError):
                pass  # The complete output is validated after the process ends.
        else:
            print(line, end="", flush=True)


class CoverageAccumulator:
    """Keep one aggregate, replacing it only after a successful merge."""

    def __init__(self, run_dir, timeout):
        self.run_dir = run_dir
        self.timeout = timeout
        self.analyzer = os.environ.get("VERILATOR_COVERAGE", "verilator_coverage")
        self.data = run_dir / "coverage.dat"

    def command(self, arguments):
        command = [self.analyzer, *map(str, arguments)]
        code, output = execute(command, self.timeout)
        with (self.run_dir / "coverage.log").open("a") as log:
            log.write(shlex.join(command) + "\n" + output)
        if code:
            raise ValueError(f"RTL coverage analyzer failed (exit={code}); see coverage.log")

    def merge(self, data_file):
        temporary = self.run_dir / "coverage.tmp"
        try:
            inputs = [self.data, data_file] if self.data.is_file() else [data_file]
            self.command(["--write", temporary, *inputs])
            temporary.replace(self.data)
        finally:
            temporary.unlink(missing_ok=True)

    def finish(self, errors):
        if not self.data.is_file():
            return None
        # Compute totals even if an LCOV export or annotation command fails.
        summary = None
        try:
            summary = rtl_summary(self.data, HERE.parents[2] / "hw")
        except (ValueError, KeyError, OSError) as error:
            errors.append(f"RTL coverage summary: {error}")
        for arguments in (
            ["--write-info", self.run_dir / "coverage.info", self.data],
            ["--annotate", self.run_dir / "annotated", "--annotate-all", self.data],
        ):
            try:
                self.command(arguments)
            except (ValueError, OSError) as error:
                errors.append(str(error))
        return summary


def output_fingerprint(path):
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as data:
        for chunk in iter(lambda: data.read(1024 * 1024), b""):
            digest.update(chunk)
            size += len(chunk)
    return {"bytes": size, "sha256": digest.hexdigest()}


def run_cases(cfg, run_dir, selected, seeds, results, coverage, errors, report_config=None,
              keep_pass_logs=True):
    for name in selected:
        reference = None
        for timing in seeds:
            stem = f"{name}-g{cfg['SEED']}-t{timing}"
            log_file = run_dir / (stem + ".log")
            wave = run_dir / (stem + ".fst") if cfg["WAVE"] == "1" else "-"
            output_file = run_dir / (stem + ".bin")
            coverage_file = run_dir / (stem + ".dat") if cfg["COVERAGE"] == "1" else "-"
            command = invocation(cfg, name, timing, wave, output_file, coverage_file)
            replay = reproduce(cfg, name, timing)

            print(f"[runner] RUN {name} seed={cfg['SEED']} timing_seed={timing} "
                  f"cases={cfg['CASES'] if name == 'random' else 'directed'} "
                  f"wall_timeout={cfg['WALL_TIMEOUT']}s", flush=True)
            code, output = 1, ""
            counters = None
            fingerprint = None
            merged = False
            displayed = 0
            try:
                with log_file.open("w") as log:
                    monitor = RunMonitor(cfg, name, timing, log)
                    code, output = execute(command, int(cfg["WALL_TIMEOUT"]),
                                           on_line=monitor.line, on_wait=monitor.progress)
                # Captured process output has already been displayed live.
                displayed = len(output)
                if code == 124 or code == 127:
                    # execute() appends this diagnostic after draining stdout.
                    displayed = output.rfind("FAIL phase=")
                try:
                    counters = triangle_counts(output)
                except (ValueError, KeyError, TypeError) as error:
                    errors.append(f"{stem}: {error}")
                    code = code or 1
                    output += f"FAIL phase=triangle_coverage {error}\n"
                if cfg["COVERAGE"] == "1":
                    if not coverage_file.is_file():
                        errors.append(f"{stem}: missing RTL coverage data")
                        code = code or 1
                        output += "FAIL phase=rtl_coverage missing data\n"
                    else:
                        # Merge even a failed/timed-out run's last checkpoint.
                        coverage.merge(coverage_file)
                        merged = True
                if code == 0:
                    fingerprint = output_fingerprint(output_file)
                    if reference is None:
                        reference = fingerprint
                    elif fingerprint != reference:
                        code = 1
                        output += "FAIL phase=timing_invariance field=output_bits tolerance=0\n"
                        output += "Reference: " + reproduce(cfg, name, seeds[0]) + "\n"
            except (OSError, ValueError) as error:
                errors.append(f"{stem}: {error}")
                code = code or 1
                output += f"FAIL phase=artifacts {error}\n"
            finally:
                # Only artifacts belonging to this run are removed.
                output_file.unlink(missing_ok=True)
                if isinstance(coverage_file, Path):
                    coverage_file.unlink(missing_ok=True)
                    Path(str(coverage_file) + ".tmp").unlink(missing_ok=True)

            if code or keep_pass_logs:
                log_file.write_text(output)
            else:
                log_file.unlink(missing_ok=True)
            display = "\n".join(line for line in output[displayed:].splitlines()
                                if not line.startswith(COVERAGE_PREFIXES))
            if display:
                print(display, flush=True)

            results.append({
                "test": name,
                "seed": int(cfg["SEED"]),
                "cases_requested": int(cfg["CASES"]) if name == "random" else None,
                "timing_seed": timing,
                "exit_code": code,
                "log": log_file.name if code or keep_pass_logs else None,
                "reproduce": replay,
                "triangle_coverage": counters,
                "stalls": {key: int(value) for key, value in
                           re.findall(r"(input_stalls|output_stalls)=([0-9]+)", output)},
                "rtl_coverage_merged": merged,
                "output_fingerprint": fingerprint,
            })
            (run_dir / "results.json").write_text(
                json.dumps(dict(config=report_config or cfg, results=results), indent=2) + "\n"
            )

            print(f"[runner] {'FAIL' if code else 'PASS'} {name} timing_seed={timing}")
            if code:
                print("Reproduce: " + replay)


def print_summary(run_dir, results, report):
    print(f"[coverage] TOTAL categories={report['categories']['hit']}/{len(TESTS)} "
          f"verified_triangles={sum(report['triangles']['verified_triangles']['bins'].values())} "
          f"complete={report['complete']} report={run_dir / 'coverage.md'}", flush=True)
    bins = {"hit": 0, "total": 0}
    for group, points in report["triangles"].items():
        if group != "verified_triangles":
            print(f"[coverage] triangles {group}={rate(points)}")
            bins["hit"] += points["hit"]
            bins["total"] += points["total"]
    print(f"[coverage] TOTAL triangle_bins={rate(bins)} "
          f"functional_goals_met={report['functional_goals_met']}")
    print(f"[coverage] random_geometry_seeds={report['random_geometry_seeds']} "
          f"unique_random_verified={report['unique_random_verified']}")
    for kind in ("v_line", "v_branch", "v_toggle"):
        points = (report["rtl"] or {}).get("totals", {}).get(kind)
        print(f"[coverage] TOTAL RTL {kind}={rate(points) if points else 'unavailable'}")
    for error in report["errors"]:
        print(f"FAIL phase=coverage {error}")
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


def campaign_plan(cfg):
    """Run fixed directed stimuli once, then split a bounded random budget."""
    directed = [name for name in TESTS if name != "random"]
    yield cfg, directed
    count = min(int(cfg["SEEDS"]), int(cfg["CASES"]))
    quotient, remainder = divmod(int(cfg["CASES"]), count)
    for index in range(count):
        current = dict(cfg, SEED=str((int(cfg["SEED"]) + index) % 2**32),
                       CASES=str(quotient + (index < remainder)))
        if os.environ.get("WALL_TIMEOUT") == "auto":
            current["WALL_TIMEOUT"] = str(max(300, (int(current["CASES"]) + 19) // 20))
        yield current, ["random"]


def main():
    action = sys.argv[1] if len(sys.argv) > 1 else "test"
    if action == "list":
        print("\n".join(TESTS))
        return 0
    if action not in ("test", "regression", "coverage"):
        raise ValueError(f"unknown action: {action}")

    cfg = configuration(os.environ)
    if action == "coverage":
        cfg["COVERAGE"] = "1"
    run_dir = Path(cfg["OUT"]).resolve() / f"{time.time_ns()}-{cfg['MODE']}"
    run_dir.mkdir(parents=True)
    print(f"[runner] build mode={cfg['MODE']} wall_timeout={cfg['WALL_TIMEOUT']}s "
          f"artifacts={run_dir}", flush=True)
    results, errors = [], []
    coverage = CoverageAccumulator(run_dir, int(cfg["WALL_TIMEOUT"]))
    try:
        with (run_dir / "build.log").open("w") as log:
            build = subprocess.run(
                ["make", "--no-print-directory", "build", f"MODE={cfg['MODE']}",
                 f"COVERAGE={cfg['COVERAGE']}"],
                cwd=HERE, stdout=log, stderr=subprocess.STDOUT,
            )
        if build.returncode:
            print((run_dir / "build.log").read_text()[-12000:])
            errors.append(f"build failed (exit={build.returncode}); no tests executed")
            print("Reproduce: " + reproduce(cfg, cfg["TEST"], cfg["TIMING_SEED"]))
        else:
            seeds = [int(cfg["TIMING_SEED"])]
            if action in ("regression", "coverage"):
                seeds.append((seeds[0] + 1) % 2**32)
            if action == "coverage":
                count = min(int(cfg["SEEDS"]), int(cfg["CASES"]))
                print(f"[runner] CAMPAIGN geometry_seeds={count} "
                      f"random_budget={cfg['CASES']} timing_seeds={seeds}", flush=True)
                for current, selected in campaign_plan(cfg):
                    run_cases(current, run_dir, selected, seeds, results, coverage, errors,
                              report_config=cfg, keep_pass_logs=False)
            else:
                selected = TESTS if action == "regression" else [cfg["TEST"]]
                run_cases(cfg, run_dir, selected, seeds, results, coverage, errors,
                          keep_pass_logs=action == "test")
    except (OSError, ValueError, KeyboardInterrupt) as error:
        errors.append(f"runner interrupted: {error or type(error).__name__}")
    finally:
        rtl = coverage.finish(errors)
        report = write_reports(run_dir, results, TESTS, rtl, errors)
        print_summary(run_dir, results, report)
    return int(bool(errors or any(result["exit_code"] for result in results)))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (KeyError, ValueError, OSError) as error:
        print(f"FAIL phase=configuration {error}; invoke through make", file=sys.stderr)
        sys.exit(2)
