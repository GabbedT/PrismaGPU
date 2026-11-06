Pixel blending
==============

``pixel_blender`` combines the texturizer's RGBA4444 texel with the
fragment's interpolated RGB, using texel alpha, and produces a packed
RGB444 pixel compatible with ZenithSoC VGA. Framebuffer X/Y and pixel
validity travel through the same four-stage pipeline. Throughput is one
pixel per advancing clock, including when texture validity changes on
consecutive pixels.

Interface and VGA layout
------------------------

Connect the corresponding ``texturizer`` outputs directly to
``pixel_valid_i``, ``pixel_x_i``, ``pixel_y_i``, ``color_i``, ``texel_i`` and
``texture_valid_i``. X is 10 bits and Y is 9 bits. Color lanes 0, 1 and 2
are R, G and B, each interpreted as signed 36-bit F12 in the channel scale
0..15. The texel carries R at bits 15:12, G at 11:8, B at 7:4 and alpha
at 3:0.

``pixel_o`` has type ``pixel_blender_pkg::pixel_t``:

.. code-block:: systemverilog

   typedef struct packed {
       logic [3:0] red;      // [11:8]
       logic [3:0] green;    // [7:4]
       logic [3:0] blue;     // [3:0]
   } pixel_t;

This matches ``vga_pkg::pixel_t`` in ZenithSoC's
``hw/utils/pkg/vga_pkg.sv`` and the lower twelve bits consumed by
``hw/io/vga/vga_pixel_sequencer.sv``. For example, pure red is ``12'hf00``
and pure blue is ``12'h00f``. The package is local to PrismaGPU, so building
the raster engine does not require the ZenithSoC sources. Use qualified
type names when both packages are present.

The VGA framebuffer stores a contiguous stream of 12-bit pixels, with
the first pixel in the least significant bits of the stream. This stage
outputs one such pixel together with its framebuffer coordinates.
Packing into 128-bit memory beats, including pixels crossing a beat
boundary, belongs to the subsequent framebuffer writer.

Blend arithmetic
----------------

For each RGB channel, let ``C`` be the signed raw F12 input, ``T`` the
unsigned four-bit texel channel and ``A`` its unsigned four-bit alpha:

.. code-block:: text

   base      = clamp(C, 0, 15 * 4096)
   numerator = (15 - A) * base + A * T * 4096
   output    = round_even(numerator / (15 * 4096))

Alpha is normalized by 15. Alpha 0 preserves the base color after RGB444
conversion; alpha 15 selects the texture RGB exactly. Intermediate alpha
values mix the texture over the interpolated color. This operation uses
straight texture RGB, without premultiplication. The background for this
mix is the interpolated fragment color; there is no framebuffer read or
destination-pixel alpha blending inside this module. The integrated top adds
the separate destination stage described below.

When ``texture_valid_i=0``, all texel bits are ignored and the effective
alpha is zero. This also handles the texturizer's disabled-texturing and
invalid-coordinate paths. A transparent texel still produces a valid
pixel; only ``pixel_valid_i`` determines fragment validity. Vertex alpha
is not an input to this stage.

Clamping happens before blending. All twelve base-color fractional bits
are retained through the products and sum, with one final rounding to
nearest, ties to even. For instance, base 0.5 rounds to 0 and base 1.5
rounds to 2 on the bypass path. The complementary weights guarantee an
output in 0..15 and an unsigned 20-bit numerator no larger than 921600.

Normalization is exact and requires no divider or reciprocal LUT. For
the integer part of the numerator, write ``n = 16*h + l``. Division by 15
becomes ``h + floor((h+l)/15)``; since ``n <= 225``, ``h+l <= 28``, and a
single conditional subtraction suffices. The remainder and the original
twelve fractional bits determine final rounding.

Pipeline, stall and reset
-------------------------

.. list-table::
   :header-rows: 1

   * - Stage
     - Operation
   * - 1
     - Clamp signed F12 base color and capture texel RGB and alpha weights
   * - 2
     - Register unsigned 16x4 base and 4x4 texture products per channel
   * - 3
     - Add the products at F12 precision
   * - 4
     - Normalize, round and register packed RGB444

``PIXEL_BLENDER_LATENCY`` is four in ``pixel_blender_pkg``. Counting the
capture edge, an input sampled at edge N appears just after edge N+3
without stalls. The texturizer-to-blender chain takes fourteen advancing
edges, including the texturizer input capture edge.

``stall_o = stall_i`` propagates the downstream hold upstream. Connect
``pixel_blender.stall_o`` to ``texturizer.stall_i`` and stop the entire
fragment producer while held. Accept an input on
``rst_n_i && !stall_i && pixel_valid_i`` and consume an output on
``rst_n_i && !stall_i && pixel_valid_o``. All pipeline data and validity
hold while stalled; a valid output may remain asserted for multiple held
cycles and must be consumed only once the pipeline advances.

Reset is synchronous, active low, and clears all in-flight validity even
during a stall. Data registers are not reset and are meaningful only with
pixel validity. Reset must reach both stages together to flush the chain.
The upstream pixel interpolator has no stall input, so integration must
also stop its producer from advancing during a downstream hold.

Verification
------------

Run from the repository root:

.. code-block:: console

   make -C tb/re/pixel_blender lint test

``pixel_blender_tb`` compares results against independent signed 64-bit
arithmetic with ordinary division and remainder. It checks every in-range
F12 base value on bypass, all integer base/texture/alpha combinations,
fractional values around output rounding boundaries, signed extremes,
channel packing, bubbles, stalls and reset at each pipeline occupancy.

``texturizer_blender_tb`` loads texture RAM and connects the two actual
stages. It checks every texel at each supported size, per-pixel
configuration changes, disabled texturing, nonpositive perspective
denominators, edge clamping, randomized stalls and reset in flight.
Texture coordinates in this integration test use texel centers or clamp
edges so the expected addresses are independent of reciprocal LUT
implementation details. The default random seed is 161803; override it
with ``SEED=...``.

Framebuffer destination blending
--------------------------------

``framebuffer_blender.sv`` follows the existing texture/vertex blender in the
integrated raster engine. ``RE_BLEND_CFG[4]`` enables it and bits 3:0 select
constant source alpha. For each RGB444 channel::

    output = (source * alpha + destination * (15 - alpha) + 7) / 15

Division is unsigned integer division, producing round-to-nearest; denominator
15 cannot produce an exact half-integer. Alpha 0 preserves the destination,
alpha 15 selects the source. Texture alpha and vertex alpha are independent:
texture mixing remains upstream and vertex alpha is not used for this constant
blend. Hardware reset disables destination blending; soft reset preserves
configuration and cancels any pending pixel along with the pipeline.

With blending disabled, valid/ready, RGB and coordinates pass directly through,
without additional registers or latency. With blending enabled the controller captures source products and alpha,
requests the destination, and registers its products on response acceptance.
Separate SUM and QUANTIZE states then register the weighted sum and normalized
RGB before WRITE holds the result until framebuffer acceptance. Source and
destination products are unsigned 4x4-to-8 bits; complementary weights bound
their sum to 225, which also fits eight bits.
The output becomes valid two clock edges after destination response acceptance,
two cycles later than the original combined arithmetic. Opaque bypass still has
no added cycles. Exact division by 15 uses nibble folding: for N=16H+L,
N=15H+(H+L). One correction gives quotient/remainder, and remainder >= 8 rounds
up. The RTL uses no divide operator or multiply-to-quantize combinational chain.
There is no fragment FIFO or speculative read. The memory service flushes
preceding writes before a destination read, preserving overlapping-pixel order.
All source, request, response and output stalls are respected. Pipeline and
command completion include the blend stage and final framebuffer writeback.

This simple serial path is deliberately slower than opaque rendering; counters
report destination requests and busy clocks. It implements order-dependent
source-over compositing. Firmware is responsible for ordering transparent draws
and selecting depth behavior; alpha does not suppress depth writes automatically.
The intersecting transparency feature disables depth testing/writes and uses a
fixed draw order so both layers contribute to the overlap.

``framebuffer_blender_tb`` independently checks all 4096 source/destination/alpha
combinations per RGB channel, opaque bypass, request/response/output stalls,
captured alpha and coordinates, exact arithmetic latency, and abort in every
busy state. Its integer-division reference is independent of the RTL folding.
The Spike feature checks exact RGB444 overlap against an independent constant
and verifies one framebuffer destination read for every blended fragment.
