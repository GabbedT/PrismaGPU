# FPGA area optimization — 2026-11-13

## Scope and baseline

Area pass on the complete geometry and raster engines. No multipliers or DSPs
were added. Execution schedules and fixed-point fractional precision were
preserved; throughput optimization is a separate pass.

The previous final utilization/routing reports were unavailable. The supplied
partial synthesis log reported 21,891 logical LUT cells before packing,
17,166 FF, 79 DSP and 14.5 equivalent 36-Kbit BRAM, excluding the multiplier IP.
These figures are **not** routed utilization and must not be compared directly
with packed Slice LUT counts.

Before editing RTL, the sources and FPGA flow were frozen under
`out/area_optimization/baseline/sources/`. Both that snapshot and the modified
sources were synthesized and routed with the same configuration:

- Vivado 2026.1, build 6511674; `xc7a100tcsg324-1`.
- Complete `prisma_gpu_eval`, out-of-context; 10 ns clock, 2 ns maximum I/O
  delay, 0.2 ns setup uncertainty; two tool threads.
- Three-stage signed 54 × 33 multiplier IP, included in the reported totals.
- Command: `make -C fpga/nexys_a7 route`, from each source tree.

The rebuilt baseline gives 17,217 FF and 85 DSP after linking the IP: exactly
the supplied partial counts plus its 51 FF and 6 DSP. Original source hashes,
the user-provided figures, simulation comparisons and measured resource counts
are retained under `out/area_optimization/`. Each Vivado run also records its
own `sources.sha256` and `configuration.txt`.

## Routed results and timing limitation

| Resource | Baseline | Modified | Change |
|---|---:|---:|---:|
| Slice LUTs | 19,007 | 18,732 | -275 (-1.45%) |
| Flip-flops | 17,260 | 15,958 | -1,302 (-7.54%) |
| DSP48 | 85 | 74 | -11 (-12.94%) |
| Equivalent 36-Kbit BRAM | 14.5 | 10.5 | -4 (-27.59%) |

**Area savings are confirmed, but this candidate has a routed setup-timing
regression. It is not timing-closed at 100 MHz.** The unchanged cycle counts in
simulation do not establish unchanged achievable clock frequency.

| Timing at 10 ns | Baseline | Modified |
|---|---:|---:|
| Internal register-to-register setup slack | -0.084 ns | -1.136 ns |
| Internal register-to-register hold slack | +0.051 ns | +0.051 ns |
| Global setup WNS | -0.089 ns | -1.438 ns |
| Global setup TNS | -0.197 ns | -590.105 ns |
| Global setup failing endpoints | 3 | 717 |
| Global hold WHS | -1.378 ns | -1.377 ns |
| Global hold THS | -1556.920 ns | -1504.453 ns |
| Global hold failing endpoints | 1,409 | 1,419 |

The modified worst internal path starts at the GE packer word count, crosses
pipeline stall/busy and register-write validation, and ends at a viewport DSP
clock enable. A near-identical path ends at matrix coefficient register enables.
Its data delay is 10.347 ns, including 8.513 ns routing (82.3%). The path includes
a stall net with fanout 1,802. The corresponding control equations were not
changed in this area pass; physical mapping/layout of the complete design did
change. This observation does not isolate the contribution of each area change.

The original baseline already has two internal setup failures in RE command
state to passthrough-control paths. Its global worst setup path is reset to busy;
the modified global worst path is reset to a GE matrix coefficient enable.
Both runs have external input-to-memory hold violations. Vivado explicitly
warns that out-of-context I/O timing is inaccurate without `HD.PARTPIN_LOCS`.
These boundary results require integration-level validation; that caveat does
**not** excuse the separate internal setup regression above. No timing exceptions
or relaxed constraints were added to hide violations.

All routable nets are routed (35,270 baseline; 33,385 modified), with zero routing
errors. `check_timing` reports no missing clocks or unconstrained internal
endpoints. DRC has warnings, including DSP pipelining and RAM control checks,
in both runs. This evaluation does not produce a board bitstream or validate
the complete SoC/DDR interface.

The next performance pass should first shorten the GE busy-to-MMIO-write-enable
dependency and its fanout while preserving register error, reset and stall
semantics. A concrete experiment is to apply `mode_write_blocked` only to the
`GE_CTRL` update inside the register bank, instead of gating the common write
input. Its condition already includes `address == GE_CTRL`, so unrelated matrix
and viewport writes should not need the busy dependency. The wrapper's write
error behavior must remain unchanged. This proposal has not been implemented or
physically measured; validate MMIO/control behavior and rerun the same physical
comparison. Do not treat the area
candidate as an accepted 100 MHz implementation until internal setup is repaired
and boundary timing is validated in the integrated design.

## Synthesis results

These totals include the multiplier IP and precede placement/physical
optimization. BRAM is expressed as RAMB36 + RAMB18/2.

| Resource | Baseline | Modified | Change |
|---|---:|---:|---:|
| Slice LUTs | 19,438 | 19,216 | -222 |
| LUT as logic | 18,405 | 18,199 | -206 |
| LUT as memory | 1,033 | 1,017 | -16 |
| Flip-flops | 17,217 | 15,956 | -1,261 |
| DSP48 | 85 | 74 | -11 |
| Equivalent 36-Kbit BRAM | 14.5 | 10.5 | -4 |

## Implemented changes

1. **Pixel interpolation:** reuse each attribute multiplier for the Y and X
   offsets in consecutive existing preparation states. Fourteen RTL multiply
   operations become seven shared operators. Vivado maps this block from 22
   to 11 DSP, with LUTs increasing from 1,020 to 1,453 and FF from 823 to 967.
   This is the main explicit LUT/FF tradeoff for recovering scarce DSPs.
2. **Clipping input storage:** remove the redundant triangle snapshot; INIT
   reads the triangle retained by the upstream buffer. The standalone clipper
   contract now explicitly requires the input to remain stable until completion,
   including stalls. The integrated upstream buffer already satisfies this.
3. **Clipping plane arithmetic:** select operands before one signed 33-bit
   add/subtract per endpoint. Reuse those distances for sign and zero tests.
   The initial all-plane trivial accept/reject test is retained. Combined with
   the preceding change, `clip_engine` falls from 2,697 to 1,926 LUT and from
   2,173 to 1,581 FF; DSP remains 2.
4. **Triangle math temporaries:** reduce temporary registers and adder operands
   from 88 to 54 signed bits, with a 55-bit guarded sum. Validated coordinate
   differences fit 19 bits, attribute differences fit 33 bits, and differences
   of their products fit 53 bits. Packed reciprocals fit 41 bits. The final
   multiplier/conversion path remains 87/88 bits. A simulation assertion checks
   every successful temporary write. The block saves 200 LUT and 171 FF, with
   the same 10 DSP including its multiplier IP.
5. **RGB transport:** clamp after interpolation and carry unsigned 16-bit F12
   values in [0, 61440] instead of signed 36-bit values through depth/texture
   processing. Fractional bits are retained. This removes 720 declared transport
   register bits; synthesis may already optimize some of them. Standalone
   texturizer/blender modules default to the original wide interface, while the
   integrated pipeline selects `CLAMPED_COLOR=1`.
6. **Z line memory:** expose one 128-bit synchronous read port and one byte-write
   port per physical bank, shared between pixel and DDR access. Concurrent
   interfaces own different banks, as required by the controller. Output-hold
   registers preserve stalled responses and bank swaps without adding latency.
   The actual inference changes from 16 RAMB18 to 4 RAMB36: half the block's BRAM
   capacity allocation. Checkpoint inspection confirms SDP, 72-bit primitive
   ports, `READ_FIRST`, and no optional BRAM output register. LUT decreases
   from 262 to 150; FF increases from 15 to 32.
7. **Framebuffer pending writes:** store a compact pixel/offset/nibble-count
   descriptor and expand data/masks in MERGE. Split writes and validation remain
   cycle-equivalent. FF decreases from 740 to 589, at a cost of 214 LUT
   (702 to 916). This is a FF-for-LUT tradeoff, not a reduction in both resources.

Hierarchy figures above are synthesis measurements of the complete design,
not isolated module estimates. Do not sum overlapping parent/child hierarchy
rows. Physical optimization may change LUT/FF totals.

## Functional validation

The original snapshot and modified complete simulators were both built and ran
the integration checks. Across 16 scenarios, 43 PNG frames are byte-identical;
all deterministic `frames.csv` fields, including simulated cycle counts, match.
Host execution speed is excluded from the comparison. The scenarios include
the expected watchdog failure, empty/direct/buffered submissions, clipping,
depth, texture and slow-memory behavior. The main seed is 11, timing seed 7;
slow memory uses timing seed 19, latency 25 and gap 8.

| Directed test | Result |
|---|---|
| Pixel interpolator | 21,781 checks; seed 271828; interruptions in every preparation state |
| Vertex interpolator | 90 intersections and 1,536 signed distance pairs |
| Clip engine | 315 triangles, 1,602 exact vertex comparisons; seed 314159 |
| Triangle math | 784 commands at each multiplier latency 0 and 3; seed 271828 |
| RGB transit | 69,633 pixels; exhaustive 16-bit input sweep; seed 161803 |
| Framebuffer access | 460 checks; all nibble offsets, split writes, stalls/abort/invalid input |
| Z line buffer | 42,628 checks across Z widths 16, 17, 24 and 32; seed 8675309 |

The default-width Z test also passes on the frozen original implementation.
Math tests include full 640×480 coordinate spans and extreme attributes that
produce intermediates wider than 48 bits. RGB tests compare wide and narrow
chains to an independent integer reference, including alpha, bypass, stalls
and reset. These are simulation results, not a formal equivalence proof.

Additional passing checks: complete Verilator lint, `make -C tb/verilator test`,
`make -C fpga/nexys_a7 check` (4 checks), `git diff --check`, and Sphinx with
`-W --keep-going -n`. New standalone targets are `test-clip-engine`,
`test-color-transit`, and `test-z-buffer-line` under `tb/verilator`.

## Report locations

The common run-directory name is
`gpu_xc7a100tcsg324-1_p10.000_io2.000_u0.200_m3`.

- Baseline: `out/area_optimization/baseline/sources/fpga/nexys_a7/build/<run>/`.
- Modified: `fpga/nexys_a7/build/<run>/`.
- Within each run: `reports/synthesis/`, `reports/routed/`,
  `synthesized.dcp`, `routed.dcp`.
- Comparison data: `out/area_optimization/resource_comparison.json` and
  `out/area_optimization/simulation_comparison.json`.
- Memory inspection: `out/area_optimization/optimized_bram_properties.txt`.
- Validation logs: `out/area_optimization/validation_logs/`.

Generated reports, checkpoints and simulation artifacts remain untracked.
