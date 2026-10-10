# Geometry Engine synthesis on Nexys A7-100T

The existing `PrismaGPU.xpr` project targets `xc7a100tcsg324-1` and synthesizes
`geometry_engine` with its default FIFO parameters. All RTL files from
`hw/geometry_engine/_geometry_engine.f` are included, with the packages first.
The project uses `source_mgmt_mode None` and preserves the manifest's manual
compilation order, as in ZenithSoC. All RTL is SystemVerilog in `xil_defaultlib`;
the existing compilation-unit imports at the end of the package files apply to
the following modules. No per-module imports are required.
`geometry_engine.xdc` specifies a 10 ns clock (100 MHz). Synthesis uses
`-mode out_of_context`, so the block's interfaces do not consume package I/O pins.

## Vivado GUI

Open `PrismaGPU.xpr`, select **Run Synthesis**, then **Open Synthesized Design**.
If the project was already open when its configuration changed, source
`configure_geometry_engine.tcl` in the Tcl Console before restarting `synth_1`:

```tcl
source [file join [get_property DIRECTORY [current_project]] configure_geometry_engine.tcl]
```

Stop at synthesis. To write the reports, run this in the Tcl Console:

```tcl
source [file join [get_property DIRECTORY [current_project]] report_geometry_engine.tcl]
```

You can also use **Reports > Report Utilization** and
**Reports > Timing > Report Timing Summary** directly in the GUI.

## Make

From `fpga/nexys_a7`:

```sh
make synth-ge
```

From the repository root, use `make -C fpga/nexys_a7 synth-ge`.

This configures the source order, resets a stale or failed synthesis run,
launches only `synth_1`, opens the synthesized design, and writes:

- `reports/utilization.rpt`: LUT, register, DSP, and memory usage.
- `reports/utilization_hierarchical.rpt`: resource usage by submodule.
- `reports/timing_summary.rpt`: setup/hold estimates and unconstrained paths.
- `reports/timing_registers.rpt`: the ten worst internal setup paths.
- `reports/check_timing.rpt`: timing constraint coverage diagnostics.

Generated run directories and reports are ignored by Git. A working Vivado
installation and license are required; no implementation or bitstream is launched.
If Vivado is not on `PATH`, specify its executable with
`make synth-ge VIVADO=/path/to/vivado`.

## Interpreting the reports

Setup WNS >= 0 indicates that the estimated constrained paths meet the 10 ns
period. Post-synthesis routing delays are estimates, so this does not establish
timing closure on the board. Confirm timing after placement and routing when the
GPU is integrated.

Only the internal clock is constrained. Missing input/output delay warnings are
expected for this isolated block; they must be resolved with interface constraints
when integrating the GPU. Reset recovery/removal constraints and clock uncertainty
also depend on the integration. Do not hide unconstrained paths with blanket false
paths. No integration-specific clock uncertainty is specified; Vivado can still
include its default device jitter model.
