# Geometry Engine Verilator Testbench

This directory contains a cycle-driven testbench for the PrismaGPU Geometry Engine (GE) RTL. It can run the same C test program in either **standalone** mode or as **RISC-V firmware under Spike**. Both modes use the same input generator, software reference model, RTL, memory agent, and result checks.

## Quick start

Requirements for standalone mode:

- Verilator with FST tracing support
- GNU Make
- Python 3.9 or later
- A C11 compiler and a C++17 compiler

Run commands from this directory, or use `make -C tb/ge/verilator ...` from the repository root:

```sh
make list
make test TEST=clip_left
make test TEST=random SEED=42 TIMING_SEED=17 CASES=1000
make test TEST=clip_left VERBOSE=2 WAVE=1
make regression CASES=10000 VERBOSE=0 WALL_TIMEOUT=3600
make coverage CASES=1000 VERBOSE=0
```

`make test` builds the selected mode once, runs one test category, and saves its logs
and reports under `out/`. `make regression` runs all 29 categories with two timing
seeds: `TIMING_SEED` and the next 32-bit value, wrapping at `2^32`. It keeps the same
geometry `SEED` for both runs and compares their output fingerprints after ignoring
unused padding. It continues after failures and returns nonzero on any failure.

`make coverage` runs the directed categories with both timing seeds, then distributes
the total `CASES` random budget across `SEEDS` geometry streams (default 16). Geometry
seeds start at `SEED` and increment modulo `2^32`. Each stream is replayed with both
timing seeds to check timing invariance. The total random workload is `2 * CASES`,
not `2 * SEEDS * CASES`; directed cases add a fixed workload. More seeds alone do
not establish complete coverage: the reports expose hit and missing bins.

Other targets:

- `make build` compiles the selected simulator (and the Spike firmware in Spike mode) without running tests.
- `make waveform TEST=...` is shorthand for `make test TEST=... WAVE=1`.
- `make coverage` runs directed coverage goals and a campaign over multiple geometry seeds with RTL instrumentation.
- `make spike TEST=...` is shorthand for `make test MODE=spike TEST=...`.
- `make clean` removes `build/` and `out/`, including saved logs and waveforms.

## Architecture

### Data path

The test program creates a triangle, encodes its vertices into the GPU input layout, configures the GE registers, and starts processing. A timed memory agent then moves 128-bit words between the GPU memory model and the GE's built-in FIFOs. The output is decoded and checked against a software golden model.

```text
Input triangles
      │
      ▼
GPU memory ── timed agent ──► input FIFO ──► unpacker
                                               │
                                               ▼
                                            matrix
                                               │
                                               ▼
                                    clip + triangle assembly
                                               │
                                               ▼
                                      perspective divide
                                               │
                                               ▼
                                       viewport transform
                                               │
                                               ▼
                                      face culling
                                               │
                                               ▼
GPU memory ◄── timed agent ◄── output FIFO ◄── packer
```

The pipeline transforms each vertex by the configured matrix, clips triangles against the six view-frustum planes, assembles the resulting triangles, performs perspective division, maps vertices to the viewport, applies front-face/culling settings, and packs surviving triangles. Clipping may produce multiple output triangles or discard an input triangle. The GE's input and output FIFOs are part of the RTL; the testbench does not replace them.

Backpressure propagates from the output side toward the input. If the output FIFO or packer's triangle buffer fills, pipeline stages stall and the unpacker pauses consumption. The memory agent has its own deterministic pseudo-random timing state: it can add a random delay of up to `LATENCY` cycles and skip transfers according to `PAUSE`. Output reads can also be held off with `OUTPUT_HOLD`. The agent handles the GE's synchronous output-FIFO read response and waits for pending writes and the whole pipeline to drain before raising `done_i`.

### Simulator and software layers

```text
Makefile ──► run.py ──► Verilator executable
                           │
                C test program and golden model
                           │
       standalone: native C calls ──┐
       Spike: RISC-V firmware ──────┴──► device interface
                                           │
                         testbench wrapper, timed agent, RTL
                                           │
                          shared 64 KiB GPU memory model
```

In standalone mode the test program runs natively in the simulator process. In Spike mode the same test code is compiled into a RISC-V firmware image and runs under Spike; firmware accesses to the testbench's memory-mapped device bridge are translated into GE register, GPU-memory, and control operations. No proxy kernel is needed.

Only device operations, reset, and timed-agent activity advance the RTL clock. Triangle generation and golden-model computation run between device transactions without consuming simulated GE cycles. The software memory port and timed agent share one 64 KiB GPU memory array. Transfer timing belongs to the C++ wrapper and agent; the memory array itself is a simple storage model.

### Source map

| File | Purpose |
|---|---|
| [Makefile](Makefile), [run.py](run.py) | Build settings, test selection, regression runs, timeouts, logs, and reproduction commands. |
| [coverage_report.py](coverage_report.py) | Functional-bin aggregation and RTL coverage summaries. |
| [sw/test.c](sw/test.c) | Shared C test flow: generate and transfer inputs, configure MMIO, start the GE, wait for completion, and check results. |
| [sw/triangle_gen.c](sw/triangle_gen.c) | Test registry, directed cases, and reproducible random-case generation. |
| [sw/golden_model.c](sw/golden_model.c) | Input/output codecs and independent floating-point and quantized reference models. |
| [sw/ge_test.h](sw/ge_test.h) | Shared formats, test configuration, address definitions, and C/C++ interface. |
| [sw/firmware.c](sw/firmware.c), [sw/start.S](sw/start.S), [sw/link.ld](sw/link.ld) | Spike-only firmware bridge, startup code, and linker layout. |
| [testbench.cpp](testbench.cpp) | Clock/reset control, timed memory agent, optional Spike bridge, stage monitors, watchdogs, and FST tracing. |
| [sv/tb_top.sv](sv/tb_top.sv), [sv/memory.sv](sv/memory.sv) | GE instance, protocol assertions, passive pipeline monitors, and the shared 64 KiB memory model. |

## Configuration

Pass settings as Make variables, for example `make test TEST=random SEED=5 CASES=500`. The Makefile exports these settings to `run.py`, which validates the mode, test name, numeric ranges, and tolerances before launching the simulator.

| Variable | Default | Meaning |
|---|---:|---|
| `MODE` | `standalone` | Execution mode: `standalone` or `spike`. |
| `TEST` | `identity` | Test category. Run `make list` to see the registry. |
| `SEED` | `1` | 32-bit geometry/generator seed. Zero is valid. |
| `SEEDS` | `16` | Number of geometry streams for `make coverage`, capped at `CASES`. Ignored by `test` and `regression`. |
| `TIMING_SEED` | `2` | Independent 32-bit seed for memory-agent delays and pauses. Zero is valid. |
| `CASES` | `100` | Random triangles per stream for `test`/`regression`; total random budget across all geometry seeds for `coverage`. Directed categories use fixed case counts. |
| `VERBOSE` | `1` | `0` prints results, `1` prints test phases, `2` also prints configuration, data, MMIO, and word transfers. |
| `TIMEOUT` | `200000` | Maximum simulated cycles for processing and reset waits. |
| `WALL_TIMEOUT` | `auto` | Maximum wall-clock seconds per simulator process. `auto` uses `max(300, ceil(CASES/20))`, e.g. 5,000 seconds for 100,000 cases. An explicit integer overrides it. |
| `LATENCY` | `3` | Maximum added agent delay in cycles; each delay is chosen from 0 through this value. |
| `PAUSE` | `25` | Percentage chance per active cycle that the agent skips a transfer opportunity. Range: 0–100. |
| `OUTPUT_HOLD` | `0` | Earliest cycle after start at which the agent may read output. `backpressure` enforces at least 1,000 cycles. |
| `XY_TOL` | `0.25` | Absolute output tolerance for X/Y, in pixels. |
| `Z_TOL` | `0.001` | Absolute output tolerance for Z. |
| `UV_TOL` | `0.001` | Absolute output tolerance for U/V. |
| `W_TOL` | `0.001` | Absolute tolerance for reciprocal W. |
| `COLOR_TOL` | `3` | Absolute tolerance for 4-bit RGBA channel values (range 0–15). |
| `WAVE` | `0` | Set to `1` to write an FST waveform for each run. |
| `COVERAGE` | `0` | Set to `1` to instrument RTL line/branch paths and signal toggles and generate merged reports. |
| `OUT` | `out` | Parent directory for per-invocation logs, reports, and optional waveforms. |
| `JOBS` | `2` | Parallel jobs used by Verilator during compilation. |
| `VERILATOR` | `verilator` | Verilator executable name or path. |
| `VERILATOR_COVERAGE` | `verilator_coverage` | Coverage analyzer from the same Verilator installation. |
| `RISCV_CC` | `riscv64-unknown-elf-gcc` | Bare-metal RISC-V compiler used in Spike mode. |
| `SPIKE_DIR` | `/usr/local` | Spike installation prefix, or source tree when using a local build. |
| `SPIKE_INCLUDE` | `$(SPIKE_DIR)/include` | Include directory for Spike and `libfesvr` headers. |
| `SPIKE_LIB` | `$(SPIKE_DIR)/lib` | Directory containing `libriscv` and `libfesvr`. |

The timing seed changes agent scheduling, not the generated geometry. In regression,
each category runs with two timing seeds. The byte count and SHA-256 digest of the
canonicalized output must match. Each binary capture is deleted immediately after
processing that simulation; fingerprints are saved in `results.json`. This checks
that external memory timing does not change the result.

### Spike setup

Spike mode additionally requires `libriscv`, `libfesvr`, their headers, and a bare-metal RV64 LP64D toolchain. The firmware is compiled for `rv64imafdc_zicsr`. Set `SPIKE_DIR`, or override `SPIKE_INCLUDE` and `SPIKE_LIB` when the headers and built libraries are in separate locations.

```sh
# Installed Spike with headers in include/ and libraries in lib/.
make test MODE=spike TEST=clip_left SPIKE_DIR=/path/to/spike-install

# Example using a local Spike source tree and build directory.
make regression MODE=spike CASES=1000 VERBOSE=0 \
    SPIKE_DIR=/home/user/riscv-isa-sim \
    SPIKE_INCLUDE=/home/user/riscv-isa-sim \
    SPIKE_LIB=/home/user/riscv-isa-sim/build
```

The testbench bridge maps firmware RAM to `0x10000000`, GE registers to `0x40000000`, GPU memory to `0x50000000`, and test control/logging to `0x60000000`. GE register offsets are defined by the RTL register map. Spike's C++ API can vary between revisions, so a local source version may require bridge adjustments. A firmware watchdog stops execution after one billion instructions.

## Test categories

| Test | Stimulus and specific check |
|---|---|
| `identity`, `inside`, `ccw` | Base triangle inside the frustum, identity matrix, and unclipped path. |
| `cw` | Base triangle with the first two vertices reversed. |
| `zero_area`, `collinear` | Aligned vertices and rejection of a degenerate triangle. |
| `viewport` | 801×603 viewport to exercise odd dimensions and rounding. |
| `clip_left`, `clip_right`, `clip_top`, `clip_bottom`, `clip_far`, `clip_near` | Six plane-specific cases, with one or two vertices outside and varying vertex indices. |
| `multi_plane`, `outside` | Clipping against multiple planes and rejection of a triangle entirely outside. |
| `on_plane`, `near_plane` | A vertex exactly on a plane, then offsets from −2 to +2 Q16.16 LSBs around all six planes. |
| `coincident`, `near_zero` | Two coincident vertices, then vertices separated by one LSB to create a near-zero area. |
| `matrix` | Scaling, translation, and a transformed W value of 2. |
| `culling` | All 18 combinations of three culling modes, two front-face conventions, and CW/CCW/zero-area input winding. |
| `plane_states` | All 27 inside/outside/on-plane classifications of three vertices for each of the six planes (162 directed inputs). |
| `output_counts` | Eight directed multi-plane cases producing exactly 0 through 7 output triangles, including maximum triangle expansion. |
| `random` | Random XYZ/UV, varying viewport, and randomized matrix, W, and culling settings. |
| `winding` | Reversed-order pair; compares against the golden model and checks geometric equivalence after vertex reordering. |
| `attributes` | Pair with UV and colors halved; compares against the golden model and checks geometry remains unchanged. |
| `consecutive` | Eight processing runs without reset, including cumulative-counter checks. |
| `backpressure` | Twelve triangles in one buffer; requires a full input FIFO, packer stall, and correct outputs. |
| `reset` | Reset during each of seven monitored stages; checks state/counters clear and processing can restart after reconfiguration. |

**Known `backpressure` limitation:** output reads are held for at least 1,000 fixed cycles rather than until a particular stall has been observed. With very slow input transfers, the test can fail during `phase=coverage` even when output values are correct. For `LATENCY=24 PAUSE=65`, timing seeds 23 and 24 pass with `OUTPUT_HOLD=10000`:

```sh
make test TEST=backpressure SEED=20261006 TIMING_SEED=23 \
    LATENCY=24 PAUSE=65 OUTPUT_HOLD=10000
```

## Reference model and checks

The reference starts from the packed input bytes, decodes them, then models matrix transformation, clipping against left/right/top/bottom/far/near planes, triangle assembly, perspective division, viewport mapping with inverted Y, and culling. It preserves the vertex order expected from the clipper. Expected values are computed independently of the RTL outputs.

The floating-point model checks numeric values, while the quantized fixed-point model determines the exact output count. Boundary categories (`on_plane` through `near_zero`) and cases where the floating-point and fixed-point models disagree also use fixed-point output values. Tolerances account for the reciprocal lookup table and color interpolation; they are intended for this generator's input domain, not as universal GE error bounds.

Input and output records each occupy **80 bytes**: three 208-bit input vertices or three 183-bit output vertices followed by a signed 51-bit doubled screen area, with no padding between vertices. Output bits 599:549 hold the area, with 16 fractional bits; bits 639:600 are zero padding. Input tail padding is deliberately nonzero. Every output area is checked exactly against the determinant of its decoded Q16.8 vertices, and output padding must be zero. Timing fingerprints include the area. Input position/UV values use Q16.16. Output XY uses Q16.8, Z retains 16 fractional bits, UV uses Q16.16, and reciprocal W has a Q1.24 mantissa and signed exponent representation.

Each processing run checks counts, IRQ, buffer bounds, sentinels, and input integrity. SystemVerilog assertions check FIFO protocols, data stability during stalls, and counters. Seven passive monitors observe unpack, matrix, clipping/assembly, perspective, viewport, culling, and packing. Numeric comparisons apply to the final output; intermediate stage data is available for diagnosis.

## Logs and debugging

Each invocation creates a unique directory beneath `OUT`, containing `build.log`,
per-test logs, `results.json`, coverage reports, and optional `.fst` waveforms.
Per-test `.bin` and `.dat` files are temporary and are removed after each simulation,
including failed simulations. The final summary always reports functional and RTL
coverage totals, pass/fail counts, and commands for replaying failures. Build failures
also print a summary, with unavailable RTL coverage indicated explicitly.

Simulator output is streamed to the terminal and its per-test log while it runs.
The runner prints a `PROGRESS` update at each new verified checkpoint and at least
every 10 seconds while waiting, even with `VERBOSE=0`. For `random`, it shows the
latest verified count out of `CASES`, percentage, elapsed time, and estimated time
remaining once a nonzero checkpoint is available. Checkpoints arrive every 1,000
cases; the estimate is approximate. Each geometry stream runs `random` twice, once
per timing seed. A quiet interval between checkpoints does not indicate a deadlock.

Numeric failures report the phase, geometry seed, timing seed, triangle, vertex, field, expected value, actual value, and tolerance. Replay the printed command with `VERBOSE=2 WAVE=1` to capture detailed transfers and an FST trace. Open the waveform with an FST-compatible viewer such as GTKWave. STATUS polling remains quiet in debug mode.

## Coverage

Every test/regression writes `coverage.md` and `coverage.json` in its invocation
directory. Triangle coverage counts **verified input triangles**: a bin is credited
after the RTL output, counters, IRQ, guards, and input integrity checks pass.
Interrupted reset attempts are excluded. Batch duplicates and the two regression
timing seeds count separately; the report states these totals explicitly.

The functional report includes:

- Passing categories out of the 29 registered tests (execution status, separate from coverage completeness).
- For each of the six clipping planes, all 27 combinations of inside/outside/on-plane
  for the three transformed, quantized vertices before clipping. Index
  `a + 3*b + 9*c` uses inside=0, outside=1, on-plane=2.
- Output triangle counts from 0 through 7, and all six front-face/culling settings.
- All 18 combinations of input winding and front-face/culling settings.
- Decoded input XY winding (CW, CCW, zero area), identity/transformed matrix, and
  even/odd viewport dimensions.
- Observed input/output stall cycles.

`coverage.json` gives the hit count and missing bins for each group; `coverage.md`
shows hit/total percentages. Unhit bins are reported without failing the test:
these goals do not imply that the current stimulus can reach every combination.
`complete` describes successful execution; `functional_goals_met` separately states
whether every defined triangle bin was hit. Neither implies 100% RTL coverage.
Reports also list geometry seeds and distinct verified random cases by `(seed,
case index)`, counting timing replays once. Cumulative triangle counts include
timing replays.
The legacy `[coverage]` masks still describe generated cases, including a case
that later fails; `[triangle_coverage]` counters describe verified cases only.

Enable RTL code coverage for one test or the full regression:

```sh
make test TEST=clip_left COVERAGE=1
make coverage CASES=1000 VERBOSE=0
# Set geometry diversity without multiplying the total random budget:
make coverage CASES=100000 SEEDS=64 VERBOSE=0
# A single-geometry-seed regression with instrumentation:
make regression COVERAGE=1 CASES=1000 VERBOSE=0
```

Instrumented executables use `build/<mode>-coverage/`, independently of ordinary
builds. `--coverage-line` measures Verilator line/block points, including branch
paths; `--coverage-toggle` measures signal bit transitions. Verilator's `v_line`,
`v_branch`, and `v_toggle` groups are reported separately when present. This measures
the elaborated Geometry Engine RTL, not the host C/C++ software. The simulation wrapper and GPU memory model are
excluded from instrumentation, and summary totals include only sources in `hw/`.
Initial startup reset counters are cleared; later test resets are covered.

Each simulation writes a temporary `<test>-g<seed>-t<timing>.dat`. Immediately after
it finishes, the runner merges available points into a single `coverage.dat` and
deletes that simulation's `.dat` and `.bin`. The previous aggregate is replaced only
when the merge succeeds. At the end, `VERILATOR_COVERAGE` creates the exports:

- `coverage.dat`: merged instrumentation counts across this invocation.
- `coverage.info`: LCOV export, usable with external LCOV viewers.
- `annotated/`: annotated RTL sources with uncovered points marked.
- `coverage.log`: analyzer commands and diagnostics.
- `coverage.md` / `coverage.json`: total and per-source line/branch and toggle
  point coverage, alongside triangle coverage.

Triangle and RTL coverage are checkpointed at startup, every 1,000 verified cases,
and on normal completion. RTL checkpoints use atomic replacement, so a hard timeout
or assertion abort preserves the last completed checkpoint. Incomplete simulations
contribute their last available counters and mark the report incomplete; subsequent
activity may be absent. Missing counters and analyzer errors return nonzero, while
coverage totals are still printed. An export failure also preserves the totals
computed from the merged data.

Report aggregation checks can be run independently of RTL compilation:

```sh
python3 -m unittest discover -s checks -v
```
