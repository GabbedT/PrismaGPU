Pixel raster pipeline
=====================

``hw/raster_engine/raster_engine_pixel_pipeline.sv`` connects triangle setup,
rasterization, interpolation, depth testing, texture sampling and pixel
blending. It accepts the geometry engine's ``proc_triangle_t`` and emits
framebuffer X/Y with ZenithSoC-compatible RGB444. The module follows the
geometry pipeline's stage sections, explicit instance wiring, external
payload registers and separate validity/reset control.

The sequence is:

.. code-block:: text

   proc_triangle_t + configuration
       -> triangle_setup
       -> pixel_rasterizer (span mode)
       -> pending span + two-entry descriptor queue
       -> span walker / pixel_interpolator
       -> z_tester + matching payload register
       -> texturizer
       -> pixel_blender
       -> RGB444 + X/Y + pixel_valid

This wrapper ends at the pixel stream. Its DDR port accesses the depth
buffer; a framebuffer writer consumes the RGB output separately. The test
bench implements that writer and exports images from its actual stored
pixel values.

Triangle and completion protocol
--------------------------------

A triangle transfers on ``rst_n_i && valid_i && !stall_o``. Hold its payload
until that edge. Rendering configuration enters through the packed
``raster_config_t config_i`` port. The external register bank owns these
settings; the pipeline does not duplicate them in a configuration register.
Hold ``config_i`` stable until every accepted triangle has completed and
``busy_o`` clears, including stalls and depth write responses. The first
``done_o`` of a batch is not permission to change configuration or texture
contents. Triangle payload, including vertex zero's flat Z, is captured
internally.

``raster_config_t`` is declared in ``hw/pkg/raster_config_pkg.sv``. Its fields
are ``gouraud_shading``, ``texture_en``, ``perspective_correct``,
``z_interpolation``, ``viewport_size`` (one-bit ``re_viewport_size_t``),
``scissor_enable``, inclusive ``scissor_xmin/xmax`` (10 bits),
``scissor_ymin/ymax`` (9 bits), ``texture_size`` (``texture_size_t``),
``z_test_enable``, ``z_write_enable``, ``z_compare`` (3 bits),
``z_buffer_address`` (32 bits). Mode zero selects 640x480; mode one selects
320x240. Width, height and depth pitch are derived locally from this mode.

The source list includes packages before RTL. Like the geometry engine,
imports are at compilation-unit scope in the package sources; module files
use types and constants directly without local imports or package qualifiers.

The wrapper can hold three triangles at different stages: one in setup,
one using the rasterizer/interpolator context, and one with pixels still in
the texturizer/blender. Setup's OUTPUT state holds the next descriptor until
the active context becomes free. There is no second rasterizer or additional
primitive FIFO. The wrapper saves the active bounding box and flat Z;
rasterizer and interpolator already capture edges and attribute planes.

``stall_o`` describes input readiness, independently of ``busy_o`` and the
pixel output's ``stall_i``. Setup may accept a triangle while older pixels
are stalled. It backpressures the source once its descriptor storage is
occupied. Reset, CLEAR_Z and pending error reporting also block acceptance.
``busy_o`` stays asserted while any setup, raster context, pixel tail or
clear operation remains active.

The control FSM has three states:

* IDLE can transfer a completed setup descriptor into the active context.
* RASTER generates fragments and waits for the final Z write response.
* RETIRE waits for any older pixel tail to complete, records this triangle's
  remaining pixel count and status, and releases the context.

The next triangle can rasterize while its predecessor's final pixels travel
through the texturizer and blender. A six-bit tail counter records those
pixels; ordered pixel transfers decrement it. Depth rejects only decrement
the global fragment count, never the older triangle's tail count. All depth
results and writes finish before a context is released, so the next
triangle cannot prefetch stale Z values. Setup overlap does not require
pixel tags or duplicated depth banks.

``done_o`` reports one completion per accepted triangle, in input order,
including empty or discarded triangles. It waits for that triangle's pixels
to be accepted and for its depth writes to receive DDR responses. It is not
held by ``stall_i``; consecutive completions may assert it on consecutive
clocks. It does not imply that the whole pipeline is idle or that external
framebuffer writes have completed.

``status_o`` retains ``SETUP_OK``, ``SETUP_EMPTY``, ``SETUP_DEGENERATE``,
``SETUP_MATH_ERROR`` or ``SETUP_INVALID_CONFIG`` until the next completion.
Sample it with ``done_o``. ``discard_o`` identifies a non-OK setup result;
``error_o`` identifies the two error statuses. ``math_status_o`` preserves
that triangle's setup arithmetic status. An erroneous descriptor waits for
older pixels to complete before reporting its error; younger triangles are
blocked until the completion event is handled. The command processor then
aborts the pipeline and requires software reset.
A geometrically valid triangle whose samples all fail depth comparison
still completes with ``SETUP_OK``. So does a valid subpixel triangle with
no covered samples after span generation. If all edges have no active sample
rows, setup returns ``SETUP_EMPTY`` instead. Enabled interpolation planes
whose gradients exceed the documented signed widths return
``SETUP_MATH_ERROR``; disabled planes are not evaluated.

The viewport is either 640x480 or 320x240, and processed vertices must lie
within the selected bounds. Scissor limits are inclusive. Empty scissors
discard the draw. Texture sampling requires perspective correction;
``config_i.texture_en=1, config_i.perspective_correct=0`` returns ``SETUP_INVALID_CONFIG``.
The geometry engine supplies already transformed positions and encoded
positive reciprocal W values, as documented by :doc:`../ge/overview`.

Span scheduling and backpressure
--------------------------------

``pixel_rasterizer`` adds ``stall_i``, ``span_x_end_o``, ``done_o`` and the
``SPAN_ONLY`` parameter. The default parameter value preserves its pixel
stream behavior. In span mode, ``new_line_o`` carries inclusive X bounds
and Y for each nonempty row; its transfer is gated by ``!stall_i``. Empty
rows are skipped and ``done_o`` follows the final span. A stall holds its
FSM and payload, and reset takes priority over the stall.

The wrapper retains one pending span until either another nonempty span
or end-of-triangle establishes whether it is last. Two additional queued
descriptors feed the Z controller's first/lookahead interfaces. This
handles trailing empty rows without guessing the last span from the
bounding-box Y limit. A full queue stops span generation without stopping
depth-memory service or draining pixels.

With depth enabled, the controller fills its front bank and prefetches the
next span into its back bank. The wrapper retains the corresponding Y
coordinates and starts interpolation exactly once on the bank's new-line
notification. The X counter and interpolator advance only when the depth
stage accepts a fragment. This preserves attributes across variable DDR
latency, bank swaps and output stalls, without a fragment FIFO.

With depth testing disabled, queued spans feed the pixel walker directly,
and no depth DDR transaction is issued. A one-cycle bypass register has
the same payload timing as the depth result stage.

``stall_i`` holds texturizer and blender registers. The depth tester may
accept one fragment into an empty result register during that hold; the
external X/Y/color/UV register captures on exactly the same acceptance.
Otherwise the walker and interpolator stop until the result can advance.
Consume RGB on ``rst_n_i && pixel_valid_o && !stall_i``. A valid output
remains stable during backpressure.

Inside a ready span, throughput is one fragment per advancing clock.
After walker acceptance, the depth/bypass register, texturizer and blender
take 1 + 10 + 4 advancing edges, including the acceptance edge. Startup,
row transitions, setup and memory service add variable latency. Setup of
the next triangle overlaps the current triangle's rasterization. Z writeback
still forms a boundary between the two raster contexts.

Depth and texture memory
------------------------

The integrated depth path uses 16-bit unsigned Q0.16 storage. Interpolated
signed F16 raw values saturate to ``[0,65535]``; 1.0 maps to ``16'hffff``.
When ``config_i.z_interpolation=0``, depth testing uses vertex zero's captured Z,
with the same saturation. ``config_i.z_compare`` follows :doc:`z_test` and
``config_i.z_write_enable`` independently controls writes after a passing test.

``config_i.z_buffer_address`` is the byte address of row zero and must be
16-byte aligned when depth testing is enabled. Invalid alignment rejects
the draw. The fixed row stride is 1280 bytes for VGA and 640 for QVGA.
A registered span address adds ``(y << 10) + (y << 8)`` for VGA or
``(y << 9) + (y << 7)`` for QVGA, with Y extended before shifting. The caller provides
enough address space for the framebuffer-sized depth allocation and
initializes depth contents before drawing.

The 128-bit DDR protocol, byte-enable polarity and read/write completion
requirements are unchanged from :doc:`z_test`. There is one outstanding
transaction. Commands remain stable until accepted; both reads and writes
require a response, no earlier than the following cycle. Depth-disabled
draws require no DDR service. Depth writes are committed before texture
sampling; the blender does not discard transparent texels.

The texture loading port is passed directly to :doc:`texturizer`. It
writes eight RGBA4444 texels per 128-bit word, independently of pixel
stalls and reset. Keep its enable low when no write is intended. Texture
size comes from ``config_i.texture_size``, and smaller textures retain the fixed
64-texel physical row stride. Drain the draw before replacing a texture
when all its pixels must see one image.

Reset synchronously aborts in-flight control and pixel validity, including
under a stall. It does not clear texture/depth RAM or undo framebuffer and
depth writes already committed. Reset or drain the external DDR adapter
with the wrapper so old responses cannot enter a new transaction.

End-to-end regression and framebuffer images
--------------------------------------------

Run from the repository root:

.. code-block:: console

   make -C tb/re/pixel_raster_pipeline lint test
   make -C tb/re/pixel_raster_pipeline test SEED=271828 TIMING_SEED=161803

The Python reference uses integer/rational arithmetic from the input
triangles, independently of RTL signals and outputs. It models documented
rounding at setup boundaries, classifies coverage against quantized edges,
evaluates planes directly at each sample, compares depth in a separate
array, and computes texture addresses and alpha mixing. Its reciprocal
model is additionally checked against exact rational division.

The SystemVerilog bench models DDR backpressure and delayed responses,
stores committed RGB pixels in a framebuffer, and writes temporary binary
PPM and depth-memory snapshots. Verification compares every output coordinate and
RGB value, every snapshot pixel, every depth byte and untouched row/base
padding against the independent reference. PNGs are converted only from
the verified RTL framebuffer files. The same scenes run without stalls
and with randomized timing, including long output stalls.

Coverage includes all 128 shared flag combinations, all eight depth
comparisons, write/test bypasses, every texture size, fractional alpha,
perspective distortion, UV clamp, flat/Gouraud colors, six vertex orders,
flat-top/bottom and thin triangles, subpixel/empty/degenerate triangles,
invalid configuration and depth addresses, both fixed viewport modes,
external configuration changes between draws, queue backpressure and resets
during setup, a DDR transaction and a live tail. Directed cases also exercise
an exclusive bottom edge exactly on a sample row, and near-collinear geometry
that overflows Gouraud gradients but is valid with flat shading.

All thirteen exported scenes are rasterized natively at **640x480**, including
the texture-size grid and configuration matrix. Input vertices and scissors
are scaled before rasterization; framebuffer images are never enlarged or
resampled. Directed QVGA cases include tiny triangles, out-of-range
coordinates and the final pixel, without image exports. RGB444 retains 16 levels per color channel.

The dedicated ``13_texture_mapping.png`` scene loads a 64x64 RGBA4444
brick image containing a cyan P, a yellow arrow and colored corner markers.
It shows the same image on an axis-aligned panel and a perspective panel,
each made from two triangles. Vertex colors are constant black and alpha
is 15 throughout, making the texture RAM the sole source of visible detail.
Earlier texture exports cover all four sizes and fractional alpha
(``02_texture_sizes_alpha.png``), perspective sampling
(``03_perspective_checker.png``), and UV clamp with scissor
(``04_clamp_and_scissor.png``).

Two additional views render **Prisma**, an original 8,996-triangle robot mesh
in ``tb/re/pixel_raster_pipeline/character_model.py``. The fixture creates
ellipsoids, jointed limbs, fingers, a floor slab and a 64x64 RGBA4444 atlas
for its face and chest display. CPU-side camera projection and vertex
lighting produce ``proc_triangle_t`` inputs; hardware performs the raster,
Gouraud interpolation, perspective texture lookup, alpha blend and Z test.
Triangles are shuffled with a fixed seed so visibility depends on the depth
buffer. This tests the raster pipeline, not the geometry engine's transform.

Artifacts are under ``out/pixel_raster_pipeline/``. ``report.json`` records
geometry and timing seeds plus coverage counts. Each ``timing_*`` directory
contains only the thirteen PNG framebuffer images, including
``11_prisma_robot.png`` and ``12_prisma_robot_side.png``. Pixel traces,
stimuli, PPMs and depth dumps are temporary and removed after the run.
The runner also removes the older gallery, HTML and raw snapshot exports.
PNG export uses only Python's standard library. Use ``TIMINGS=0`` or
``TIMINGS=1`` to select a single timing profile.

Simulation and lint establish functional behavior; FPGA resource mapping
and timing closure require a separate synthesis/implementation run.

Command processor integration
-----------------------------

The integrated :doc:`command_processor` consumes this wrapper's pixels and
writes the packed framebuffer. Per-triangle done_o still denotes pixel
acceptance plus completed depth writes; the processor separately drains the
framebuffer writer after the entire DRAW completes, before committing the
command. It does not flush between triangles in the same DRAW. ``z_rejected_o`` exposes the accepted depth-discard event for the
performance counter.

``clear_valid_i``, ``clear_ready_o``, ``clear_depth_i`` and ``clear_done_o``
provide an exclusive CLEAR_Z path to the depth block. A clear blocks new
triangles and keeps busy_o asserted through completion. Configuration must
remain stable. The processor resets the wrapper on abort while retaining
outstanding DDR ownership in its memory unit.

Streaming regression
--------------------

Run ``make -C tb/re/pixel_raster_pipeline overlap`` to exercise consecutive
triangle delivery with immediate and delayed DDR responses and output
backpressure. The test uses the same independent rational reference for
ordered pixels, completion statuses and final depth memory. Both viewport
modes cover different bounding boxes, flat and interpolated Z, Gouraud and
textured colors, overlapping depths, empty inputs and a trailing invalid
triangle. Coverage requires simultaneous setup/raster work, raster start
with an older pixel tail, a held setup descriptor and three outstanding
triangles.

The command-processor integration test additionally checks that two
single-row triangles sharing a framebuffer beat produce one final write,
STOP finishes the entire DRAW, reset cancels multiple accepted inputs, and
an error from a later triangle preserves the preceding triangles' pixels.
