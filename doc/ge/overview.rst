The GE and its pipeline
=======================

The Geometry Engine turns a stream of triangles into primitives expressed
in screen coordinates. Each input triangle consists of three vertices,
with a homogeneous position, texture coordinates, and a color. The engine
applies a 4 × 4 matrix, clips geometry to the visible volume, performs
perspective division, maps positions into the viewport, and removes triangles
that should not be drawn. It either serializes the remaining triangles into
128-bit words or forwards complete processed triangles directly to the raster
engine, bypassing the output memory path.

The matrix can represent a combined transformation, such as model, view,
and projection, provided software supplies the coefficients already combined.
Clipping can turn one input triangle into several output triangles. A
matrix-forward mode also allows software to read the result of the matrix
alone through registers, without sending those vertices through the rest
of the pipeline.

The GE prepares geometry for a later renderer. Rasterization, depth testing,
texture sampling, and shading belong to the stages that consume its output.
Input triangles carry all three vertices explicitly; there is no indexed
vertex format.

.. figure:: ../img/ge_pipeline.svg
   :alt: Input, matrix, clipping, perspective division, viewport, culling, and memory or direct raster output
   :width: 100%

   The geometry pipeline, its buffers, and the two output destinations.

.. Editorial: This figure can be replaced by a schematic of the pipeline stage.

How the stages work together
----------------------------

The unpacker reconstructs vertices from input words. The matrix transforms
one vertex at a time, and a triangle buffer gathers three transformed
vertices. Clipping needs the whole triangle, so this buffer retains it
until the visible polygon has been processed.

An entirely visible triangle passes through clipping unchanged. A partially
visible triangle is cut against the six boundaries of the viewing volume;
the resulting polygon is split into triangles. Perspective division and
the viewport then process the resulting stream of vertices. A second
triangle buffer assembles groups of three before culling. If a vertex has
a division error, this buffer removes the whole group so that incomplete
triangles cannot reach the output.

The culler evaluates orientation in screen coordinates. Surviving triangles
enter the packer, which produces four output words (64 bytes) per triangle,
or go directly to the raster engine when ``GE_CTRL.raster_forward=1``.

Buffers let adjacent stages work at different rates. When a downstream
stage cannot accept more data, it holds up the stages that feed it. This
is called backpressure. Pending data stays in place until processing can
resume. There is no fixed latency for every triangle: clipping work and
the number of output triangles vary with the geometry, and a slow output
consumer can hold up the pipeline.

Memory and data transfers
-------------------------

The GE has a 32-bit register interface and separate input and output streams
of 128-bit words. An external memory unit supplies input words, removes
output words, and reports transfer completion. Buffer addresses are configured
through the GE registers for that unit to use. Address traversal, range
checking, and the convention for inclusive or exclusive end addresses belong
to the system's memory integration.

Direct raster mode adds a valid signal and a 512-bit processed triangle
output. It avoids packing and DDR writes for newly processed triangles.
There is no ready input: the raster engine must accept every valid transfer.
The packer's backpressure is ignored in this mode. Input memory transfers
remain the same. See :doc:`packer` for details.

The standard configuration buffers 16 input words and 16 output words.
The input producer must respect the available capacity; an excess write
can be lost. Output reads return one queued word after a clock edge.
FIFO means first in, first out: words leave in the order they arrived.
Reported word counts describe the queued words, not every piece of data
already being assembled or processed elsewhere in the engine.

Numeric formats
---------------

Input x/y/z/w use S(25,16), with range [-256,256); u/v use S(27,16),
with range [-1024,1024). RGBA uses four unsigned 4-bit
channels. Each input vertex is 170 bits. Three vertices occupy 510 bits in a
512-bit (four-word, 64-byte) record with two high padding bits.

The matrix multiplies each signed 25-bit F16 input by a signed 32-bit F16
coefficient, forms 57-bit products and 59-bit four-term sums, then emits a
signed 32-bit F16 result. The wider result range supports transformed values
outside the packed input range without extra input quantization. Matrix and
viewport registers remain 32-bit and accept unrestricted writes. Software must
validate values before packing: hardware cannot detect overflow after a value
has already been narrowed into the wire fields.

.. list-table:: Data carried through the engine
   :header-rows: 1
   :widths: 30 15 55

   * - Data
     - Bits
     - Contents
   * - Input XYZW
     - 100
     - Four signed 25-bit values, F16.
   * - Input UV
     - 54
     - Two signed 27-bit values, F16.
   * - Color
     - 16
     - Four unsigned 4-bit RGBA components.
   * - Input vertex
     - 170
     - XYZW, UV, and color.
   * - Input record
     - 512
     - Three vertices (510 bits) and two high padding bits.
   * - Reciprocal of w
     - 24
     - Unsigned 18-bit Q1.17 mantissa and signed 6-bit exponent.
   * - Processed vertex
     - 158
     - Color 16, UV 64, reciprocal 24, Z 17, Y 18, X 19.
   * - Processed triangle
     - 512
     - Three vertices (474 bits) and signed doubled area (38 bits).

Input and output records are each four 128-bit words (64 bytes). The input
record has two high padding bits. The output record has no padding: three
158-bit vertices are followed by the signed 38-bit doubled screen area. See
:doc:`packer` for its field layout.

Input triangle format
---------------------

The packed input and output ABI has changed: the former five-word, 80-byte
records are incompatible with the current four-word, 64-byte records. Update
both producer and consumer; do not read legacy records using this layout. An
input triangle occupies four 128-bit words, or 64 bytes. Bits 509:0 hold
the three consecutive 170-bit vertices; bits 511:510 are padding. Send bits
127:0 first, followed by 255:128, 383:256, and 511:384. Vertex A occupies
bits 169:0, B bits 339:170, and C bits 509:340. Packed values must be checked
against their signed destination ranges before narrowing; out-of-range values
must be rejected instead of wrapped. The memory interface defines how word
lanes correspond to bytes.

.. list-table:: Input vertex fields, relative to the vertex's least significant bit
   :header-rows: 1
   :widths: 25 25 50

   * - Bits
     - Field
     - Interpretation
   * - 3:0
     - a
     - Unsigned alpha.
   * - 7:4
     - b
     - Unsigned blue.
   * - 11:8
     - g
     - Unsigned green.
   * - 15:12
     - r
     - Unsigned red.
   * - 42:16
     - v
     - Signed S(27,16) texture coordinate.
   * - 69:43
     - u
     - Signed S(27,16) texture coordinate.
   * - 94:70
     - w
     - Signed S(25,16) homogeneous coordinate.
   * - 119:95
     - z
     - Signed S(25,16) coordinate.
   * - 144:120
     - y
     - Signed S(25,16) coordinate.
   * - 169:145
     - x
     - Signed S(25,16) coordinate.

From most to least significant, a vertex contains x, y, z, w, u, v, r,
g, b, and a. Input record padding is ignored. The output format is described
in :doc:`packer`.

Starting, pausing, and finishing work
-------------------------------------

Hardware reset clears all configuration, including the matrix. Before
starting, load a useful matrix, viewport dimensions, buffer addresses,
and the desired control settings. Supply input words and issue START with
``enable=1``. Configuration is live rather than captured per job; change
it when no affected data is in flight.

STOP pauses input consumption. With the GE still enabled, triangles already
inside the pipeline continue to drain. START resumes consumption. STOP
takes priority if both commands are issued together. Clearing enable stops
the geometric pipeline, but input writes and output reads remain possible.
The packer can continue serializing triangles it already accepted.

SOFT_RESET flushes pending data, clears counters, forward results, and
pending interrupts, and stops consumption. It preserves configuration,
including enable and the interrupt mask. Hardware reset clears configuration
too.

BUSY describes the geometric pipeline, including incomplete vertex groups.
It excludes the input queue and data already handed to the packer. DONE
reflects transfer completion reported by the external memory unit; it does
not stop processing by itself. End-of-job handling must therefore also
account for buffered data and the memory unit's transfer protocol. See
:doc:`registers` for the precise status and counter meanings.
