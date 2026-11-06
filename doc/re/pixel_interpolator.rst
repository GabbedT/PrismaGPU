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

Connect the rasterizer's ``pixel_x_o``, ``pixel_y_o``, ``pixel_valid_o`` and
``new_line_o`` to the corresponding interpolator inputs. The row protocol is:

* In ``X_LOOP_SETUP``, a nonempty span produces ``new_line_o = 1`` and
  ``pixel_valid_o = 0``. X/Y carry the integer coordinates of its first pixel.
* The next cycle produces that first pixel with ``pixel_valid_o = 1`` and
  ``new_line_o = 0``. Subsequent valid pixels advance X by one on the same row.
* Every nonempty row, including the triangle's first row and the first row
  after the TM/MB transition, has its own notification. Empty rows have none.
* Bubbles hold the interpolation accumulators. Coordinates during bubbles
  without ``new_line_i`` are ignored. A coordinate jump requires a new row
  notification; ``pixel_valid_i = 0`` alone does not advance X.

The rasterizer computes ``x_start``. During the notification cycle the
interpolator computes the attribute value at that coordinate. Notification
and pixel validity must be mutually exclusive. ``start_i`` has priority over
both; every accepted triangle requires a notification before its first pixel.

The fragment outputs are combinational views of the current accumulators,
with no additional clock of latency. ``pixel_valid_o`` follows the current
``pixel_valid_i``, gated low during reset, start or a new-row notification.
The consumer samples the current attributes at the same rising edge that
advances the accumulators. Any output register belongs outside this module;
register attributes and the rasterizer's X/Y together there. The interpolator
has no X/Y outputs.

Throughput is one fragment per clock within a span. There is no ready/stall
interface: the consumer must accept every valid output. Invalid output data
is ignored. Internal reset is synchronous and active low; output validity is
suppressed while reset is asserted. Send a new start before resuming pixels.

For a span beginning at ``(xs, y)``, the inputs and combinational outputs
before each sampling edge are:

.. list-table::
   :header-rows: 1
   :widths: 15 35 50

   * - Clock edge
     - Input before edge
     - Output before edge
   * - N
     - new_line, (xs, y), valid=0
     - valid=0; accumulators initialize at this edge
   * - N+1
     - (xs, y), valid=1
     - First fragment and its initial attributes
   * - N+2
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
Products keep the plane's fractional precision. Row/start intermediates
use 45 bits for F16 planes and 37 bits for F12 planes; increments sign-extend
the gradients. No rounding or saturation is performed. Inputs must be
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

    make -C tb/re/pixel_interpolator lint test
    make -C tb/re/pixel_rasterizer lint test

The standalone interpolator test checks every configuration combination,
sparse validity masks, flat colors, signed extreme gradients, fractional and
out-of-range references, skipped rows, changing span origins, bubbles, reset,
viewport extremes and captured descriptor inputs. Its random seed defaults
to 271828 and can be selected with ``SEED=...``.

The tests sample combinational attributes before the accumulators advance.
The rasterizer test connects both modules, checks that every nonempty span
has exactly one notification with the correct origin, and compares every
interpolated fragment against direct signed 64-bit plane evaluation. Coverage
includes both edge sides, the TM/MB transition, clipping, empty spans and
500 deterministic random triangles (seed 314159).
