# PrismaGPU area and timing evaluation — Nexys A7-100T

This directory builds **PrismaGPU alone** for `xc7a100tcsg324-1`. The default
includes GE, RE, their direct triangle connection, register banks, memories,
the two-entry GE raster queue, and the triangle multiplier IP. It does not
build ZenithSoC, a DDR controller, clock generator, board I/O, software, or a
bitstream.

The source of truth is the Tcl flow and `hw/_prismaGPU.f`, not a checked-in
Vivado project. Nested `-F` manifests retain compilation order and shared files
are included once. Packages and their compilation-unit imports remain ahead of
consumers, with automatic source management disabled.

## Commands

From the repository root (Vivado and its license must be available):

```sh
make -C fpga/nexys_a7 project       # Create a GUI project, without synthesis
make -C fpga/nexys_a7 synth         # Full GPU synthesis and estimated timing
make -C fpga/nexys_a7 route         # Full GPU synthesis, place, phys_opt, route
make -C fpga/nexys_a7 synth-ge      # Geometry-only diagnosis
make -C fpga/nexys_a7 synth-ts      # Triangle-setup-only diagnosis
make -C fpga/nexys_a7 route BLOCK=ge PERIOD=8.000
make -C fpga/nexys_a7 check         # Manifest checks; Tcl only, no Vivado license
```

`BLOCK` accepts `gpu` (default), `ge`, or `triangle_setup`. `VIVADO` may be an
absolute executable path. The other defaults are:

| Variable | Default | Meaning |
| --- | --- | --- |
| `PART` | `xc7a100tcsg324-1` | Nexys A7-100T device |
| `PERIOD` | `10.000` | Clock period in ns (100 MHz) |
| `IO_DELAY` | `2.000` | Maximum synchronous input/output delay in ns; minimum is zero |
| `UNCERTAINTY` | `0.200` | Additional setup clock uncertainty in ns |
| `MULTIPLIER_STAGES` | `3` | Multiplier Generator pipeline stages, 1–30 |
| `JOBS` | `2` | Vivado threads and synthesis jobs, 1–32 |

Each configuration has an isolated directory under `build/`. Every command
creates a fresh project and removes that configuration's old reports/checkpoints,
so stale routed results cannot be confused with a new synthesis-only run. Do
not launch the same configuration concurrently or regenerate an open GUI project.
`make clean` removes evaluation directories, preserving `build/legacy/`.

Open `build/<configuration>/project/evaluation.xpr` in the GUI. Batch evaluation
is the supported report flow. To inspect the placed/routed design, open
`build/<configuration>/routed.dcp`; routing runs directly in Tcl after opening
`synth_1`, so it does not populate the GUI's `impl_1` run.

## Evaluation boundary

`rtl/prisma_gpu_eval.sv` is a wiring-only wrapper around `hw/prismaGPU.sv`. It
flattens both DDR interfaces into ordinary ports for Vivado's out-of-context
(OOC) synthesis. It introduces no registers, tied inputs, DMA, bus adapters, or
clock/reset logic. The GPU uses its default FIFO depths (16 input words, two
triangles, 16 output words), plus two complete triangles in the GE raster
output queue. The wrapper is local to this evaluation and is not
added to the production RTL manifests.

The flow defines `_VIVADO_` and generates `triangle_multiply_ip`: signed 54×33
operands, full 87-bit product, DSP-based parallel multiplication, synchronous
clear, no clock enable. `MULTIPLIER_LATENCY` is passed through GPU → RE → pixel
pipeline → setup → math unit, matching `PipeStages` exactly. Its production RTL
default remains zero for the existing behavioral multiplier used without
`_VIVADO_`. A Vivado integration must supply a positive matching latency and the
IP. The wrapper's registered result makes the multiplier response latency
`PipeStages + 1`; ready/valid backpressure and numeric formats are unchanged.

## Timing assumptions and ZenithSoC context

The 100 MHz default matches `sys_clk_o` in the local ZenithSoC clock configuration
(`fpga/nexys_a7/build.tcl` and `hw/common/clock_source.sv`). The GPU is evaluated
as logic within that synchronous subsystem, not as a board-level peripheral.
No ZenithSoC sources, constraints, floorplan, or IP are read by this build.

The 2 ns boundary budget and 0.2 ns setup uncertainty are **evaluation
assumptions**, not timing requirements extracted from ZenithSoC. All data,
control, and reset ports are timed against `gpu_clk`; reset deassertion is
assumed synchronous to that clock. Minimum I/O delays are zero. There are no
blanket false paths. Replace these budgets with actual neighboring logic,
clock skew/jitter, and reset constraints during integration. Clock-network and
boundary routing in the isolated block do not model the final SoC placement.
`HD.CLK_SRC=BUFGCTRL_X0Y0` supplies a representative existing clock-buffer
location for OOC clock delay/skew estimation. It adds no clock-generation logic;
replace this assumption with the actual SoC clock source during integration.

No partition-pin locations (`HD.PARTPIN_LOCS`) are assigned. Vivado therefore
reports `Route 35-198` for OOC boundary ports: their boundary wires are not
physically routed. Use `timing_registers.rpt` for routed internal timing;
input/output reports check the chosen budgets but cannot establish physical
interface timing. That requires the actual subsystem placement and connections.

Integration still needs a register-bus adapter and external GE memory feeder.
GPU register addresses are seven-bit word addresses (GE byte offsets
0x000–0x0FF, RE 0x100–0x1FF). The shared MMIO bus returns read data/errors and
write errors after the request's rising edge, with fixed one-clock latency.
The bus adapter must sample that registered response; consecutive requests
are supported. DDR addresses are 32-bit byte addresses with 128-bit
data and byte enables; ZenithSoC's `dev2ddr_interface` has a 27-bit address and
describes `write_valid` as controller acceptance. PrismaGPU requires write
completion to guarantee subsequent read visibility. The eventual adapter must
validate address mapping and ordering/completion semantics; merely truncating
addresses or connecting similarly named signals is not an integration proof.
See `doc/integration.rst` for the GPU's stream and command modes.

## Results and interpretation

Each build records `configuration.txt`, `sources.sha256`, Vivado logs, and the
multiplier IP properties. `synth` writes `synthesized.dcp` and
`reports/synthesis/`; `route` additionally writes `routed.dcp` and
`reports/routed/`. Report files include:

- `utilization.rpt` and `utilization_hierarchical.rpt`: LUT/FF/DSP/BRAM totals
  and the GE/RE contribution. The whole GPU must fit alongside the other SoC
  blocks; the device's total capacity is not the GPU's integration budget.
- `timing_summary.rpt`: setup/hold slack, failing endpoints, and unconstrained
  paths. Synthesis timing is an estimate; routed timing is the isolated result.
- `timing_registers.rpt` and `timing_registers_hold.rpt`: internal setup and
  hold paths, separated from boundary paths in `timing_inputs.rpt` and
  `timing_outputs.rpt`.
- `check_timing.rpt`, `clocks.rpt`, `drc.rpt`, and routed `route_status.rpt`:
  constraint coverage, clock assumptions, DRCs, and routing completion.

Check both setup and hold, DRCs, routing completion, and unconstrained paths.
Unused/constant interface fields can be optimized away; investigate other missing
paths. The flow rejects unresolved black boxes instead of reporting incomplete
area. Negative slack is retained as an evaluation result, not treated as a Tcl
failure. Passing OOC timing does not establish timing closure or available area
inside ZenithSoC, and a single target period is not an Fmax measurement.

## Cleanup and retained experiment

The previous saved `PrismaGPU.xpr` and local generated caches, logs, runs, and
reports were moved to ignored `build/legacy/`. The duplicated GE/setup scripts
are replaced by the common flow. The existing multiplier exploration remains at
`experiments/triangle_math_unit.tcl`, including its `ip`, `sim`, and `route` modes:

```sh
# Run in an output directory so Vivado's journal/log also stay out of the sources.
mkdir -p out/triangle_math_unit
cd out/triangle_math_unit
vivado -mode batch -source ../../fpga/nexys_a7/experiments/triangle_math_unit.tcl \
    -tclargs 3 Use_Mults sim
```

That experiment retains its internal-only 10 ns timing constraint and separate
`out/triangle_math_unit/vivado/` outputs. Use the common flow above for full GPU
area/timing comparisons with boundary budgets.
