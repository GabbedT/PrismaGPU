Full GPU simulation
===================

``tb/verilator`` runs RISC-V applications on Spike against the combined
``prismaGPU`` RTL. Its SystemVerilog wrapper provides shared GPU RAM, a GE
memory feeder/store, delayed RE DDR channels, and testbench performance counters.
It does not require ZenithSoC or a simulated hardware CPU.

From the repository root::

    make -C tb/verilator run APP=features VIDEO=1
    make -C tb/verilator run APP=model VIDEO=1 FRAMES=0
    make -C tb/verilator run APP=game VIDEO=1 FRAMES=0

The live viewer displays the framebuffer after completed rendering and DDR
writeback. It shows GPU render FPS, host FPS, score and lives. Headless runs
save the same complete frames as PNG. In the game, use arrows/A,D to steer,
Space to restart after game over, and Q/Escape to close. Automatic steering
is available with ``AUTOPILOT=1``.

``app/features`` demonstrates a textured rotating cube, perspective checkerboard,
viewport clipping, intersecting Z planes and framebuffer alpha blending. Default
playback displays each scene for ten seconds; ``SCENE=1..5`` selects one scene.
``FRAMES=N`` instead captures N deterministic frames per scene. ``app/model``
contains a rotating, waving low-poly Mario mesh. ``app/benchmark`` contains dense
microtriangle, fill, early-Z, clipping, texture and 3D-city workloads, including
an identical stored-primitive city for comparison. Run the complete suite with
``make -C tb/verilator bench TRIANGLES=1024 FRAMES=2``. Each run writes frame images, per-frame CSV
counters, full-frame clocks including firmware/clear/upload, a cumulative JSON report, and logs under ``tb/verilator/out/<app>``.
Use ``WAVE=1`` for FST traces and ``TRACE=1`` for GPU MMIO logs.

``sv/perf_counter.sv`` counts accepted transfers, stage occupancy, memory
traffic, depth rejection, destination blending, texture uploads, errors, and backpressure (46 counters). Per-frame measurement
starts after host clear/upload and includes both engines and final memory
drain. GPU render FPS uses the configured ``GPU_HZ`` divided by those cycles;
host FPS uses actual elapsed wall time. Spike scheduling and external memory
service are configurable simulation assumptions, not a cycle-accurate CPU
or physical DRAM controller.

For a reproducible animation and validation::

    make -C tb/verilator run APP=game FRAMES=90 AUTOPILOT=1
    make -C tb/verilator video APP=game
    make -C tb/verilator test

``video`` creates ``video.apng`` from the completed PNG frames, without an
external encoder. Its playback rate is independent of measured FPS.

See ``tb/verilator/README.md`` for dependencies, Spike paths, runtime options,
address maps, counter definitions, timing assumptions and custom firmware.
