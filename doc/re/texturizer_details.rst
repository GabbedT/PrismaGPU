Texture sampling
================

``texturizer`` reconstructs perspective-correct U/V, samples one RGBA4444
texel, and forwards the fragment's RGB attributes and framebuffer X/Y.
It accepts one pixel per advancing clock. ``texture_coordinate`` contains
the arithmetic; the matching RGB, X/Y and texture-size registers are in
``texturizer``, outside that instance. ``texel_memory`` holds a fixed
64x64 texture (8192 bytes) and exposes a generic 128-bit loading port.

Fragment interface
------------------

``pixel_valid_i`` marks an input fragment. ``pixel_x_i`` is 10 bits and
``pixel_y_i`` is 9 bits. ``color_i`` has three 36-bit lanes, ordered R, G, B
from lane zero, preserving the interpolator's signed F12 values verbatim.
``u_over_w_i``, ``v_over_w_i`` and ``inv_w_i`` are signed 44-bit F16 values,
corresponding to interpolator ``attr_o[1]``, ``attr_o[2]`` and ``attr_o[3]``.
The caller supplies valid perspective attributes for textured pixels.

``texture_en_i`` and ``texture_size_i`` are sampled with each fragment;
they may change on consecutive accepted pixels. ``pixel_valid_o`` marks
every output fragment, including bypassed fragments and invalid texture
coordinates. ``color_o``, ``pixel_x_o`` and ``pixel_y_o`` retain the input
bits. This stage does not quantize RGB or blend the sampled texel with it.
The downstream :doc:`pixel_blender` performs texel-alpha mixing and emits
the packed RGB444 pixel used by ZenithSoC VGA.

When ``texture_en_i=0``, the fragment follows the same latency and ordering,
without a texture read; ``texture_valid_o=0``. With texturing enabled,
``texture_valid_o=1`` means ``texel_o`` is valid for that output fragment.
A nonpositive ``inv_w_i`` suppresses the texture read and texture validity,
but still forwards the RGB/X/Y fragment. ``texel_o`` is ignored whenever
``texture_valid_o=0``. Alpha occupies the low nibble of the texel and is
forwarded without alpha testing.

``stall_i=1`` holds all arithmetic, payload, address and read-result
registers. ``stall_o = stall_i`` propagates this hold upstream.
Accept an input only on ``rst_n_i && pixel_valid_i && !stall_o``; consume an
output only on ``rst_n_i && pixel_valid_o && !stall_o``. Valid outputs remain
asserted during a hold. Reset is synchronous, active low, clears all in-flight
validity even during a stall, and does not clear texture RAM contents.

Latency is 10 advancing rising edges, counting the input capture edge:
an input captured at edge N appears just after edge N+9 when there are
no stalls. The pipeline accepts consecutive pixels and preserves bubbles.
Constants in ``texturizer_pkg`` keep arithmetic and payload delays aligned.

.. list-table::
   :header-rows: 1

   * - Registered stages
     - Operation
   * - 1--2
     - Leading-one detection and denominator normalization
   * - 3
     - Register the shared reciprocal LUT result
   * - 4--5
     - Parallel U/V partial products and balanced sum stages
   * - 6--7
     - Scale, round and saturate U/V
   * - 8
     - Clamp coordinates and register texture address
   * - 9--10
     - Synchronous RAM word read, then registered texel selection

Coordinate arithmetic
---------------------

For positive raw F16 denominator ``d = inv_w_i``, let ``L`` be its leading
one position (0 through 42). Normalize it exactly to the unsigned 44-bit
integer ``D = d << (43-L)``. Bits ``D[42:33]`` select one of the 1024
entries in the existing ``hw/common/reciprocal_lut.sv``. Its unsigned
18-bit Q1.17 result ``R`` approximates the reciprocal of the normalized
mantissa. The LUT is instantiated once and its registered result is shared
by U/V. No iterative divider, interpolation or refinement step is used.

For either signed raw F16 numerator ``a``:

.. code-block:: text

   magnitude = abs(a)                        # unsigned 44 bits
   product   = magnitude * R                 # unsigned 62 bits
   rounded   = round_even(product / 2^(L+1))
   result    = saturate_signed44(sign(a) * rounded)

The two multipliers each use two registered unsigned 22x18 partial
products. The next stage combines them into the complete 62-bit
product, preserving all product bits. Scaling and rounding occupy two
further stages. Rounding is nearest, with ties to even; saturation protects
the signed 44-bit result from wrapping. Magnitude conversion also handles
the most negative signed input.

``u_o`` and ``v_o`` are signed F16. The table uses interval midpoints, with
the same Q1.17 samples as the geometry engine; even a power-of-two
denominator uses the approximate table entry. Its relative error is below
0.0005 before the final F16 quantization. Sampling uses those approximate,
rounded coordinates, so values near a texel boundary can select an
adjacent texel compared with exact division. The coordinate
module preserves each valid token, flags nonpositive denominators with
``invalid_o``, and returns zero U/V for those tokens.

Sampling and memory layout
--------------------------

U/V are normalized coordinates. Sampling chooses
``clamp(floor(coordinate * size), 0, size-1)`` on each axis. Thus 0 selects
the first texel, 1 selects the last, negative values clamp to the first,
and values above 1 clamp to the last. There is no wrap, bilinear filtering,
mipmap selection or half-texel offset.

.. list-table::
   :header-rows: 1

   * - ``texture_size_i``
     - Dimensions
     - Texels / 128-bit writes needed
   * - 00
     - 8x8
     - 64 / 8
   * - 01
     - 16x16
     - 256 / 32
   * - 10
     - 32x32
     - 1024 / 128
   * - 11
     - 64x64
     - 4096 / 512

``texture_size_i`` has type ``texturizer_pkg::texture_size_t``, with named
values ``TEXTURE_SIZE_8``, ``TEXTURE_SIZE_16``, ``TEXTURE_SIZE_32`` and
``TEXTURE_SIZE_64`` in the encoding order above.

All sizes use a fixed physical row stride of 64 texels. Smaller textures
occupy the upper-left square of the allocation; their rows are not tightly
packed in RAM. The texel address is ``{v[5:0], u[5:0]}``, or ``64*v + u``.
The RAM comprises 512 words of 128 bits, followed by a registered eight-way
texel selector. The format of each 16-bit texel is:

.. code-block:: text

   [15:12] R     [11:8] G     [7:4] B     [3:0] A

On every rising edge with ``write_en_i``, the full
``write_data_i[127:0]`` is stored at ``write_address_i[8:0]``. The address
counts 128-bit words, not bytes. Eight adjacent texels are packed with the
lowest U in the least significant 16 bits:

.. code-block:: text

   write_address = 8 * row + (first_u / 8)    # first_u is a multiple of 8
   write_data[16*lane +: 16] = texel(row, first_u + lane)

For example, an 8x8 texture uses word addresses 0, 8, 16, ..., 56. A 16x16
texture uses addresses 0 and 1 for its first row, 8 and 9 for its second,
and so on. All eight lanes are written; there is no write mask or command
decoder. A command processor can directly drive this loading interface.

Writes run independently of fragment stalls. A simultaneous read and
write of the same word returns the old word to that read; a later read
sees the new word. The read port has two advancing edges of latency and
holds its output under stall. Reset does not clear RAM; writes are
independent of reset, so the loader must deassert
``write_en_i`` when writes should stop. Load every texel that can be sampled
before use. Drain the pixel pipeline before replacing a texture when a draw must use one consistent
image, since loading is not atomic across the whole allocation.

Integration and verification
----------------------------

The raster source list includes all three modules and the latency/size
package. The :doc:`pixel_raster_pipeline` wrapper connects it after depth
testing and before pixel blending. When connecting
``z_tester``, pass only surviving ``pixel_valid_o`` fragments, carry their
attributes alongside the depth comparison, and connect the downstream
hold to the shared fragment path. The upstream interpolator has no stall
port, so its producer must stop advancing accepted pixels during a hold.

Run the directed and seeded randomized checks with:

.. code-block:: console

   make -C tb/re/texturizer lint
   make -C tb/re/texturizer test

The tests cover an independently calculated LUT/reference model,
continuous throughput, payload alignment, size and enable changes,
normalized coordinate boundaries, saturation, invalid denominators,
all memory lanes and rows, loading, read/write collisions, stalls and
reset with fragments in flight.
