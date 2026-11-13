# PrismaGPU — Spike / Verilator simulator

Runs actual RISC-V applications on Spike and the combined GE/RE RTL on
Verilator. Firmware writes GPU registers and shared GPU memory; the SV wrapper
feeds GE input, stores its optional primitive output, and services RE DDR.
The Spike MMIO bridge advances one GPU clock per access and then samples its
registered read data/access error, matching the shared bus's fixed latency.
A completed frame is read from the packed RGB444 framebuffer **after writeback**,
then displayed and saved. There is no VGA scanout or software rasterizer.

The organization follows the local ZenithSoC Verilator environment: a C++ host,
a SystemVerilog top, separate testbench performance counters, optional X11 video,
FST traces, logs, and firmware ELF files. It has no build dependency on ZenithSoC.

## Start

From the repository root:

```bash
make -C tb/verilator run APP=features VIDEO=1
make -C tb/verilator run APP=model VIDEO=1 FRAMES=0
make -C tb/verilator run APP=game VIDEO=1 FRAMES=0
```

`VIDEO=1` opens a window. Without X11 headers or a usable display, simulation
continues headless and still saves every completed frame. `out/<app>/latest.png`
is atomically replaced at each completion. The window title and console show
GPU render FPS and host FPS, plus the game's score and lives.

**Prism Run:** arrows or A/D steer; Space restarts after game over; Q/Escape or
closing the window exits. Green markers show remaining lives. Avoid the orange
boxes. `AUTOPILOT=1` enables deterministic automatic steering for replay and
headless capture. The game sends its floor, ship, rotating boxes and life markers
through GE projection/clipping and RE depth testing. Simulation is slower than
hardware; movement advances one game step per rendered frame.

```bash
make -C tb/verilator run APP=game FRAMES=90 AUTOPILOT=1
make -C tb/verilator video APP=game
```

The last command creates `out/game/video.apng`, an animated PNG playable in a
browser, with no video-encoder dependency. Playback uses 30 FPS, independently
of measured hardware/simulator FPS. For another rate:

```bash
python3 tb/verilator/script/video.py tb/verilator/out/game --fps 15
```

Only frame numbers recorded in `frames.csv` are included, so files from an older,
longer run cannot leak into a new animation. Use a different `OUT` for each run
you want to preserve. Reusing an output directory replaces its logs and snapshots.

## Dependencies and build

- Verilator 5, Make, a C++17 compiler, and Python 3.9+.
- `riscv64-unknown-elf-gcc`, with RV64 floating-point support and newlib.
- Spike headers and `libriscv`/`libfesvr`, built from the same checkout.
- zlib headers/library. X11 development headers are optional.

Defaults match the local installation:

```bash
make -C tb/verilator info
make -C tb/verilator build APP=game \
    SPIKE_INC="$HOME/riscv-isa-sim" SPIKE_LIB="$HOME/riscv-isa-sim/build"
```

For an installed Spike prefix, pass its `include` and `lib` directories instead.
`RISCV_CC`, `VERILATOR`, and `JOBS` are also overridable. The firmware ISA is
`rv64imafdc_zicsr`, ABI `lp64d`, with a minimal startup, linker script and newlib
syscalls in `app/common`. Spike is used as an instruction-set simulator, not a
cycle-accurate CPU or a lockstep checker against a hardware CPU.

## Applications

`app/features/` presents these scenes in order, **ten seconds of display time
per scene**, starting at its first completed frame:

1. A rotating cube with a real RGBA4444 texture on its faces.
2. An inclined checkerboard plane with perspective-correct UV interpolation.
3. A Gouraud triangle moving from inside the viewport to completely outside it.
4. Two intersecting depth planes: the visible triangle changes across the overlap.
5. The same geometry with true framebuffer alpha blending, alpha 8/15.

The fifth scene disables depth testing/writes and renders the two transparent
layers in a fixed order. The destination read/modify/write runs in RTL. It is
standard order-dependent source-over blending, not order-independent transparency.
Texture alpha continues to mix texture and vertex RGB before destination blending.

Default `FRAMES=0` uses wall time: slow simulation produces fewer poses while
the completed image remains visible. A final in-flight render can extend a scene
past its budget. `DURATION_MS` changes the display budget and `SCENE=1..5` selects
one scene (`0` runs all five). For deterministic capture, `FRAMES=N` renders
**N frames per selected scene**, samples the complete animation, and disables
wall-clock pacing. Thus `FRAMES=4 SCENE=0` produces 20 frames. Live pacing is
capped at 30 updates/s. `make video APP=features` gives each captured scene its
`DURATION_MS` playback budget (ten seconds by default), including short previews.
To do this directly: `python3 script/video.py out/features --scene-ms 10000`.

`app/model/` contains an original procedural low-poly **Mario** mesh: red cap,
visor, moustache, nose, overalls, gloves, buttons and boots. It rotates in 3D
and waves its arms. Solid faces use projection, clipping and depth testing.
The default capture is 120 frames; `FRAMES=0` runs continuously.

`app/game/` contains Prism Run. Its opaque objects are submitted near to far;
CPU backface culling removes invisible box faces. The common upload code packs
whole fields into 32-bit words and the driver reduces redundant status polling.
These optimizations preserve the course and gameplay; comparisons are recorded
in `PERFORMANCE.md`.

`app/benchmark/` is a separate workload suite. `TRIANGLES` defaults to **1024**
and can be increased to 4096. Benchmarks submit exactly that many input triangles.

| `APP` | Workload and intended measurement |
|---|---|
| `benchmark/micro` | Thousands of few-pixel triangles; geometry/setup throughput |
| `benchmark/fill` | Many tiled, overlapping Gouraud triangles; fill and color bandwidth |
| `benchmark/depth` | Repeated surfaces, alternating front-to-back and back-to-front frames; early Z and overdraw |
| `benchmark/clip` | Thin triangles crossing XY and near clip planes; clipping/discard/amplification with little fill |
| `benchmark/textured` | Hundreds of perspective-sampled checkerboard triangles; texture path throughput |
| `benchmark/scene` | A 3D city with many buildings; mixed setup, depth, clipping and framebuffer traffic |
| `benchmark/buffered` | The identical city through stored GE primitives and a DRAW command list |

```bash
make -C tb/verilator run APP=features SCENE=2 VIDEO=1
make -C tb/verilator run APP=features FRAMES=4
make -C tb/verilator run APP=model FRAMES=120
make -C tb/verilator run APP=benchmark/micro TRIANGLES=4096
make -C tb/verilator run APP=benchmark/scene TRIANGLES=2048
make -C tb/verilator run APP=benchmark/buffered TRIANGLES=2048
make -C tb/verilator bench TRIANGLES=1024 FRAMES=2
```

`bench` runs all seven workloads plus a slower-memory fill comparison, checks
identical city images across primitive sources and identical fill images across
memory timings, and writes `out/benchmark_suite/report.md` and `report.json`.
The report includes cycles/frame, render and full-frame FPS, input Mtriangles/s,
output Mpixels/s, GPU bus bytes/frame, depth rejects, overlapping wait percentages
and actual simulator FPS. Depth's two drawing orders have separate rows.

## Runtime options

| Make variable | Default | Meaning |
|---|---|---|
| `APP` | `features` | Firmware directory under `app/` |
| `FIRMWARE` | `build/app/<APP>.elf` | Alternate RISC-V ELF |
| `OUT` | `out/<APP>` | Capture and statistics directory |
| `FRAMES` | `0` features, `120` model, `3` others | Features: frames per scene; others: total frame limit; `0` uses scene time or runs continuously |
| `TRIANGLES` | `1024` | Benchmark input triangles, 0–4096; game builds its own scene |
| `SCENE` | `0` | Features: all scenes, or one scene 1–5 |
| `DURATION_MS` | `10000` | Features: display duration per scene when `FRAMES=0` |
| `SEED` | `1` | Firmware geometry/animation seed |
| `TIMING_SEED` | `2` | Deterministic DDR jitter seed |
| `LATENCY` | `3` | Base memory response latency; RE adds 0–7 cycles of jitter |
| `GAP` | `1` | Gap between requests; also delays GE input word feeding |
| `WIDTH` | `320` | `320` or `640`, with 4:3 viewport |
| `VIDEO` | `0` | Live X11 viewer |
| `SCALE` | `2` | Integer viewer scale, clamped to 1–4 |
| `AUTOPILOT` | `1` headless, `0` with video | Automatic game controls |
| `WAVE` | `0` | Record `gpu.fst`; shared RAM contents are excluded |
| `TRACE` | `0` | Log GPU register reads and writes |
| `GPU_HZ` | `100000000` | Frequency assumption used for render FPS |
| `CPU_QUANTUM` | `64` | Spike instructions between background GPU clocks |
| `MAX_CYCLES` | `1000000000` | GPU clock watchdog; `0` disables |
| `MAX_INSTRUCTIONS` | `1000000000` | Spike instruction watchdog; `0` disables |

The executable also accepts the corresponding `+firmware=...`, `+out=...`,
`+frames=...`, `+latency=...`, etc. arguments. Boolean flags are `+live`, `+wave`
and `+trace`. `make run` captures complete stdout/stderr in `console.log`,
including RTL assertion/error diagnostics. A failed firmware or watchdog returns
a nonzero process status. Q/Escape/window-close is an explicit normal exit and
is distinguished in `summary.json`.

## Timing and memory model

CPU RAM occupies `0x10000000..0x10ffffff`. The GPU register device is at
`0x40000000`: GE at offsets `0x000..0x0ff`, RE at `0x100..0x1ff`. Aligned 32-bit
MMIO accesses drive the actual top-level `reg_*` ports. Rejected accesses fail
the simulation.

GPU RAM is one 8 MiB SV byte array, mapped to Spike at `0x50000000`. GPU DDR
addresses are offsets within it, **without** the Spike base. The application
layout is:

| Offset | Use |
|---|---|
| `0x00001000` | Raster command list |
| `0x00002000` | Texture upload buffer |
| `0x00010000` | Input vertex records, 64 bytes each |
| `0x00100000..0x002fffff` | Processed primitive allocation |
| `0x00400000` | Packed RGB444 framebuffer |
| `0x00500000` | Unsigned 16-bit depth buffer |

`gpu_memory.sv` implements byte strobes, independent read/write channels, one
outstanding operation per channel, delayed responses, bounds/alignment error
responses, and request-stability assertions. GE's memory agent is driven by
its START/STOP/reset and configured ranges. It respects FIFO capacity, handles
synchronous output reads, checks output allocation, and supplies end-of-stream
only after the configured input has been fed. The top waits for remaining GE
work before the raster end indication can complete the frame.

The GE feeder/store and RE channels have separate modeled service capacity;
this is **not** a unified DDR-controller arbitration or DRAM-bank timing model.
Counters separate GE traffic from RE DDR traffic. Host memory accesses share
the same storage; firmware must respect buffer ownership and wait before reuse.
Clear and upload in the supplied driver happen before rendering starts.

Each GPU register/RAM/host-service access advances one GPU clock. After each
`CPU_QUANTUM` Spike instructions, one additional background GPU clock advances.
This permits GPU progress during CPU computation, but CPU throughput and
MMIO bus timing are scheduling assumptions. The RTL itself runs at clock edges;
reported FPS is not a prediction of ZenithSoC CPU performance or measured FPGA
timing. FST timestamps use a fixed 10 ns cycle; `GPU_HZ` changes reported rates,
not RTL timing or waveform units.

## Counters, FPS and logs

`sv/perf_counter.sv` holds 64-bit cumulative counters and snapshots for each
frame. They are testbench-only and do not consume FPGA resources. The wrapper
taps handshakes and stage state; counters do not depend on firmware enabling
the GPU's own register counters.

- Cycles: global, GPU/GE/RE busy, setup and raster occupancy; separate setup computation and setup waiting for raster acceptance.
- Geometry: words read/stored, input/matrix/clip/perspective/viewport vertices,
  output triangles, clipping and culling discards.
- Raster: accepted/retired/discarded triangles, committed pixels, Z rejects.
- Backpressure: GE waiting for RE or packer, full input FIFO, blocked pixels,
  read/write request waits, cycles with pending read/write responses.
- Traffic: RE DDR read/write beats and enabled write bytes, separate GE bytes.
- Destination blending: accepted destination reads, busy cycles, committed framebuffer pixels.
- Texture uploads: accepted texture RAM beats.
- Control and errors: MMIO reads/writes, memory/setup/GE errors, completed frames.

A frame interval starts when firmware writes `HOST+0x108` and ends at the first
RE DONE transition after it is armed. This includes GE and primitive storage in
buffered mode. Initial clear/upload is excluded from the per-frame interval but
included in total counts and host elapsed time. Completion asserts only after
pipeline and DDR writeback drain. Gaps are not frame boundaries. Preparation
command lists can run before arming without producing unwanted captures.

`model_FPS = GPU_HZ / frame_cycles` is the **GPU render rate for this memory and
CPU scheduling model**. `host_FPS` is actual completed frames per wall-clock
second, including firmware work and capture overhead. Each completed frame logs
both; while a frame is running, `[LIVE]` reports the latest rates and current
cycle/busy state, and `[STATE]` shows the active pipeline/memory states.

`frames.csv` also records `phase` (feature/workload identifier), `full_cycles`
(GPU clocks since the previous capture, including firmware clear/upload), and
`cpu_instructions` (completed Spike batches since that capture). Initial full-frame
timing includes startup; batch accounting can move a few CPU instructions between
adjacent rows. Totals in `summary.json` include final checks and exit. Analyze any run:

```bash
python3 tb/verilator/script/performance.py tb/verilator/out/game
```

Artifacts in `OUT`:

- `frame_000001.png`, ... and `latest.png`: completed RGB888 images decoded from
  the RTL's packed RGB444 framebuffer.
- `frames.csv`: per-frame counters, dimensions, RGB CRC32, and the two FPS rates.
- `summary.json`: cumulative counters, seeds, instruction count, and exit status.
- `run.log`: structured host/application/performance logging.
- `console.log`: complete terminal output when using `make run`.
- `gpu.fst`: optional waveform; `video.apng`: optional animation.

Stall categories overlap. The largest-wait report identifies a useful candidate
for investigation; it is not an exclusive cycle breakdown or proof of causation.
`ddr_*_pending_cycles / ddr_*_beats` gives average in-flight duration only for a
fully drained interval. Write-byte counts include enabled bus bytes, not pixel
bits, and DDR beat counts are separate from GE traffic.

The host-service device at `0x60000000` exposes configuration words at offsets
0/4/8/12/16 (frames, triangles, seed, autopilot, width), console byte output at
`0x100`, exit status at `0x104`, frame arm at `0x108`, completed-frame count at
`0x10c`, feature scene/duration options at `0x18/0x1c`, keys at `0x110`, a 64-bit cycle count at `0x118`, game score/lives writes
at `0x120/0x124`, monotonic milliseconds/read-or-wait-until at `0x128` (64-bit),
scene/workload ID write at `0x130`, and 46 read-only 64-bit last-frame counters at `0x200+8*index`.
Counter index/name mapping is defined in `perf_counter.sv`.

## Checks

```bash
make -C tb/verilator lint
make -C tb/verilator test
```

The checks run real Spike firmware and verify PNG checksums/format, frame
retirement, matching direct/buffered images, absence/presence of primitive
writes, deterministic replay, invariance under slower memory, feature textures, continuous viewport exit, independently expected depth colors,
exact alpha-blended overlap RGB, dense geometry, early Z rejection, empty frames,
both viewport sizes, Mario/game animation, APNG structure, and watchdog status. Results go under
`out/checks/`; each case preserves `process.log` and replay seeds.

The moving 3D scene exposed a GE/RE boundary mismatch: accepted reciprocal-LUT
overshoot could leave an XY coordinate just outside the strict setup viewport.
The GE viewport now snaps only that already-accepted numerical fringe to the
clip boundary before screen conversion and area calculation. Truly out-of-range
input is still rejected. Dedicated viewport tests and the GE integration
regression cover the correction.
