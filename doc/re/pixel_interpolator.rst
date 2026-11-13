Pixel interpolation
===================

``pixel_interpolator`` evaluates the planes produced by ``triangle_setup``
at the covered pixels emitted by ``pixel_rasterizer``. A row reference stays
at the bounding box's first X coordinate; a separate accumulator follows
the pixels within each span. The implementation uses the existing ``aref``
field as its initial value, without changing the setup arithmetic.

Triangle and stream interface
-----------------------------

Pulse ``start_i`` on the same rising edge that accepts the rasterizer's
descriptor: ``rasterizer.start_i && rasterizer.request_o``. This captures
``attr_i``, ``color_i``, ``attr_valid_i`` and the flat RGB color, and initializes
the row references. These inputs may change after acceptance. Gate the
interpolator's start with the rasterizer's request: an ungated start would
restart interpolation while the rasterizer is busy.

The bounding-box X origin must remain stable through interpolation. The Y
origin is captured on ``start_i`` and may change afterwards.
The rendering configuration is shared: ``gouraud_shading_i``, ``texture_i``,
``perspective_correct_i`` and ``z_interpolation_i`` remain stable until the
draw is drained. The top-level integration must retain the active bounding
box while setup processes another triangle.

A nonempty span pulses ``new_line_i`` with its first integer X/Y coordinate
and ``pixel_valid_i = 0``. Every nonempty row, including the first row after
an edge-pair transition, requires this notification; empty rows have none.
``start_i`` has priority and cancels any pending row initialization.

Row initialization uses four sampling edges: capture signed coordinate deltas,
register the Y gradient products, advance the row reference while registering
the X gradient products, then add the X offset into the pixel accumulator.
Each of the seven lanes shares one multiplier and product register between X
and Y. A multiplication never feeds the wide accumulator addition in the same
cycle. The first pixel can transfer four clocks after the row-notification
edge, preserving the preparation latency and fragment throughput.

``pixel_ready_o`` is low during reset, start, a row notification and the three
following preparation cycles. The caller must hold the first pixel's coordinates
until ready and submit a new row only after the preceding span has finished.
The integrated span walker gates both its coordinate advance and the depth
input validity with this readiness; Z, RGB, texture coordinates and screen
coordinates therefore remain aligned while row initialization is busy.

The fragment outputs are combinational views of the accumulators.
``pixel_valid_o = pixel_valid_i && pixel_ready_o``. A transfer exposes the
current value and advances the enabled accumulators by ``gx`` on the same edge.
Bubbles and downstream stalls hold the accumulators. There is no extra pixel
output register, and throughput within a span remains one fragment per clock.
Output data during invalid cycles is ignored. Reset is synchronous and active
low; send a new start before resuming pixels.

For a span beginning at ``(xs, y)``:

.. list-table::
   :header-rows: 1
   :widths: 15 35 50

   * - Clock edge
     - Input before edge
     - Work at edge / output before edge
   * - N
     - new_line, (xs, y), valid=0
     - Capture coordinate deltas; ready=0
   * - N+1
     - Hold first pixel
     - Register Y gradient products; ready=0
   * - N+2
     - Hold first pixel
     - Add Y product to row reference and register X product; ready=0
   * - N+3
     - Hold first pixel
     - Add X product to pixel accumulator; ready=0
   * - N+4
     - (xs, y), valid=1
     - First fragment; ready=1
   * - N+5
     - (xs+1, y), valid=1
     - Second fragment, attributes increased by gx

Arithmetic and formats
----------------------

For each enabled plane, setup supplies the attribute at the sample center
``(bb_x_start + 0.5, bb_y_start + 0.5)``. At triangle start::

    row_y = bb_y_start
    a_row = aref

At each new span, with first pixel coordinates ``(x_start, y)``::

    dy = y - row_y
    dx = x_start - bb_x_start
    a_row_next = a_row + gy * dy
    a_acc = a_row_next + gx * dx
    a_row = a_row_next
    row_y = y

The actual Y distance handles initial empty rows, skipped rows and the edge
pair transition. For consecutive rows this is an increment of ``gy``. Each
valid pixel transfers the current ``a_acc`` and then updates ``a_acc += gx``.
No update occurs on an ordinary bubble.

.. list-table::
   :header-rows: 1
   :widths: 35 25 40

   * - Ports / lanes
     - Format per lane
     - Meaning
   * - attr_i / attr_o [0]
     - Signed F16
     - Z
   * - attr_i / attr_o [1], [2], [3]
     - Signed F16
     - u/w, v/w, decoded 1/w
   * - color_i / color_o [0], [1], [2]
     - Signed F12
     - R, G, B in the 0..15 channel scale

``setup_attribute_t`` has signed 32-bit gradients and a signed 44-bit
reference; the row, pixel accumulator and output retain 44 bits.
``setup_color_plane_t`` has signed 24-bit gradients and a signed 36-bit
reference; color row, accumulator and output retain 36 bits. Output arrays
are packed buses: interpret each selected lane with ``$signed``.

Pixel distances are signed integers, with 11 bits for X and 10 bits for Y.
The shared multiplier sign-extends Y to 11 bits. Products keep the plane's
fractional precision and fit in the 44/36-bit
registered datapaths. Each addition retains the low 44/36 bits, preserving
the original accumulator wrap behavior; increments sign-extend the gradients. No rounding or saturation is performed. Inputs must be
successful setup planes for the supported viewport, at most 640 by 480.
The setup's reference and gradient bounds leave sufficient accumulator
headroom throughout that viewport; arbitrary full-range reference/gradient
combinations are outside this contract. There is no runtime overflow flag.

Colors remain fractional and may lie outside 0..15. Native RGB444 rounding
and clamp, depth conversion/comparison, and perspective reconstruction
``u = (u/w) / (1/w)`` belong downstream. This module does not define alpha
interpolation; alpha metadata must be retained by the surrounding pipeline.

Configuration and validity
--------------------------

``attr_valid_o`` accompanies each valid output pixel and follows the package
ordering: Z, R, G, B, u/w, v/w, 1/w. It is the captured input mask ANDed with
the shared configuration:

* Z is enabled by ``z_interpolation_i``.
* RGB planes are enabled by ``gouraud_shading_i``.
* The three texture planes require both ``texture_i`` and
  ``perspective_correct_i``, matching setup's supported perspective mode.

Disabled lanes output zero. With Gouraud shading disabled, the three color
outputs instead contain the captured flat RGB channels converted exactly to
F12. In this mode the RGB interpolation mask bits are zero; flat colors are
still usable whenever ``pixel_valid_o`` is high. With Gouraud enabled, an
invalid color plane outputs zero. Setup rejects unsupported affine-texture
configuration before rasterization.

Verification
------------

Run from the repository root::

    make -C tb/verilator test-interpolator

The directed test compares fragment values with independent signed 64-bit
plane evaluation across all configuration combinations and sparse masks.
It covers positive/negative coordinate deltas, skipped rows, changing span
origins, wide signed gradients, accumulator wrap, flat colors, bubbles at the
first pixel and within a span, and reset during each preparation stage.
Directed replacement triangles cancel each preparation stage and exercise
extreme signed gradients with negative X and positive/negative Y deltas,
checking that the shared product register cannot leak an older triangle.
The deterministic random seed is 271828.

The integration checks render textured, Gouraud, depth-tested and alpha-blended
scenes, compare direct and buffered rendering, and replay with slower memory.
