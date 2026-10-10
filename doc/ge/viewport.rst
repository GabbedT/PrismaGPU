Viewport transform
==================

The viewport maps normalized x and y into screen coordinates. The origin
is at the top left: x increases to the right and y increases downward.
``GE_VP_WIDTH`` and ``GE_VP_HEIGHT`` hold unsigned integer pixel dimensions,
not Q16.16 values. There is no configurable viewport origin or depth-range
transformation.

.. math::

   x_s = \frac{1+x_{ndc}}{2} W, \qquad
   y_s = \frac{1-y_{ndc}}{2} H

.. figure:: ../img/ge_viewport.svg
   :alt: Offset and scale normalized positions into screen coordinates
   :width: 100%

   The viewport changes scale and reverses the y axis.

.. Editorial: This figure can be replaced by a schematic of the viewport stage.

Mapping to the screen
---------------------

The stage offsets normalized x and reverses normalized y, then scales each
by half the corresponding screen dimension. Coordinates are stored in signed
19-bit X and 18-bit Y, both with eight fractional bits. Conversion rounds to
nearest, with halfway cases toward the greater value. The viewport requires
positive dimensions no larger than 640×480. Before narrowing, it rejects X/Y
outside ±65792 raw F16 units and Z outside [0,65792] raw F16 units. The
unsigned Z comparison also rejects negative signed representations. Small
reciprocal-LUT overshoot and off-screen X/Y within those limits are retained.
The viewport does not clamp out-of-range coordinates; it discards the complete
triangle using the existing perspective error indication.

Ideally, normalized (0,0) maps to (W/2,H/2), (−1,+1) maps to (0,0), and
(+1,−1) maps to (W,H). The endpoint is W or H rather than W−1 or H−1;
pixel coverage and border rules belong to the later renderer. Approximate
perspective division can make actual coordinates differ slightly from these
ideal values.

The culler consumes the signed coordinates after viewport range validation.

Depth and other attributes
--------------------------

Depth z is unsigned 17-bit Q1.16, with no viewport depth rescaling. Its range
validation and rejection behavior are described above. X and Y use eight
fractional bits; Z uses sixteen.

The encoded reciprocal of w passes through unchanged. Texture coordinates
remain 32-bit u/w and v/w values, and color remains four 4-bit channels.
Position and attributes are held together when the pipeline pauses.

Assembling complete screen-space triangles
------------------------------------------

A triangle buffer after the viewport collects each group of three vertices
in its original order. It passes complete, valid triangles to the culler.
If any vertex carries a perspective-division error, the whole group is
removed. This preserves triangle boundaries and prevents invalid geometry
from reaching the output.

This assembly buffer is separate from the output packer's triangle queue:
it bridges the vertex-oriented processing stages and the triangle-oriented
culling stage.
