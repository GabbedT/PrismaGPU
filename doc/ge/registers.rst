Register map
============

The register map extends through byte offset 0x8C, relative to the GE base
address assigned by the system. Every register is 32 bits wide. Tables show
both byte offsets and their word equivalents, where one word is four bytes.

Writes can select individual bytes. Unselected bytes preserve their previous
values. Register accesses take effect according to the system's bus interface.

.. list-table:: Registers
   :header-rows: 1
   :widths: 15 12 28 12 33

   * - Byte offset
     - Word offset
     - Name
     - Access
     - Function
   * - 0x00
     - 0x00
     - ``GE_CTRL``
     - RW / pulse
     - Configuration and commands.
   * - 0x04
     - 0x01
     - ``GE_STATUS``
     - RO
     - Current status.
   * - 0x08
     - 0x02
     - ``GE_VTX_BASE``
     - RW
     - Vertex buffer start address.
   * - 0x0C
     - 0x03
     - ``GE_VTX_END``
     - RW
     - Vertex buffer end address.
   * - 0x10
     - 0x04
     - ``GE_PRIM_BASE``
     - RW
     - Primitive buffer start address.
   * - 0x14
     - 0x05
     - ``GE_PRIM_END``
     - RW
     - Primitive buffer end address.
   * - 0x18
     - 0x06
     - ``GE_IRQ_EN``
     - RW
     - Interrupt mask.
   * - 0x1C
     - 0x07
     - ``GE_IRQ_PEND``
     - RW1C
     - Latched events.
   * - 0x20
     - 0x08
     - ``GE_MTX_RES_0``
     - RO
     - Last forwarded matrix result: x.
   * - 0x24
     - 0x09
     - ``GE_MTX_RES_1``
     - RO
     - Last forwarded matrix result: y.
   * - 0x28
     - 0x0A
     - ``GE_MTX_RES_2``
     - RO
     - Last forwarded matrix result: z.
   * - 0x2C
     - 0x0B
     - ``GE_MTX_RES_3``
     - RO
     - Last forwarded matrix result: w.
   * - 0x30
     - 0x0C
     - ``GE_MTX_00``
     - RW
     - Q16.16 coefficient M[0][0].
   * - 0x34
     - 0x0D
     - ``GE_MTX_01``
     - RW
     - Q16.16 coefficient M[0][1].
   * - 0x38
     - 0x0E
     - ``GE_MTX_02``
     - RW
     - Q16.16 coefficient M[0][2].
   * - 0x3C
     - 0x0F
     - ``GE_MTX_03``
     - RW
     - Q16.16 coefficient M[0][3].
   * - 0x40
     - 0x10
     - ``GE_MTX_10``
     - RW
     - Q16.16 coefficient M[1][0].
   * - 0x44
     - 0x11
     - ``GE_MTX_11``
     - RW
     - Q16.16 coefficient M[1][1].
   * - 0x48
     - 0x12
     - ``GE_MTX_12``
     - RW
     - Q16.16 coefficient M[1][2].
   * - 0x4C
     - 0x13
     - ``GE_MTX_13``
     - RW
     - Q16.16 coefficient M[1][3].
   * - 0x50
     - 0x14
     - ``GE_MTX_20``
     - RW
     - Q16.16 coefficient M[2][0].
   * - 0x54
     - 0x15
     - ``GE_MTX_21``
     - RW
     - Q16.16 coefficient M[2][1].
   * - 0x58
     - 0x16
     - ``GE_MTX_22``
     - RW
     - Q16.16 coefficient M[2][2].
   * - 0x5C
     - 0x17
     - ``GE_MTX_23``
     - RW
     - Q16.16 coefficient M[2][3].
   * - 0x60
     - 0x18
     - ``GE_MTX_30``
     - RW
     - Q16.16 coefficient M[3][0].
   * - 0x64
     - 0x19
     - ``GE_MTX_31``
     - RW
     - Q16.16 coefficient M[3][1].
   * - 0x68
     - 0x1A
     - ``GE_MTX_32``
     - RW
     - Q16.16 coefficient M[3][2].
   * - 0x6C
     - 0x1B
     - ``GE_MTX_33``
     - RW
     - Q16.16 coefficient M[3][3].
   * - 0x70
     - 0x1C
     - ``GE_VP_WIDTH``
     - RW
     - Integer width in pixels.
   * - 0x74
     - 0x1D
     - ``GE_VP_HEIGHT``
     - RW
     - Integer height in pixels.
   * - 0x78
     - 0x1E
     - ``Reserved``
     - —
     - Invalid access.
   * - 0x7C
     - 0x1F
     - ``Reserved``
     - —
     - Invalid access.
   * - 0x80
     - 0x20
     - ``GE_TRI_INPUT``
     - RO
     - Triangles completed by clipping.
   * - 0x84
     - 0x21
     - ``GE_TRI_OUTPUT``
     - RO
     - Triangles accepted at pipeline output.
   * - 0x88
     - 0x22
     - ``GE_TRI_DISCARDED``
     - RO
     - Trivial rejects and culler discards.
   * - 0x8C
     - 0x23
     - ``GE_STALL``
     - RO
     - Stalled cycles while pipeline is busy.

RW means read/write, RO means read-only, and RW1C means read and clear by
writing one. Writes to RO registers and accesses to reserved addresses
report an access error. Word offsets 0x24 through 0x3F are
also invalid. A reserved-address read returns zero along with an error.
Reserved bits in valid registers read as zero and have no effect on writes.
Written values are not validated, including the undefined cull_mode encoding.

GE_CTRL: configuration and commands
-----------------------------------

.. list-table:: GE_CTRL fields
   :header-rows: 1
   :widths: 15 25 15 45

   * - Bits
     - Field
     - Access
     - Meaning
   * - 0
     - ``enable``
     - RW
     - Allow pipeline progress and input consumption if started.
   * - 1
     - ``start_processing``
     - Write 1
     - Start or resume input consumption.
   * - 2
     - ``stop_processing``
     - Write 1
     - Pause input consumption; in-flight triangles may drain.
   * - 3
     - ``soft_reset``
     - Write 1
     - Flush the datapath and stop consumption.
   * - 4
     - ``front_face``
     - RW
     - 0: CW; 1: CCW.
   * - 6:5
     - ``cull_mode``
     - RW
     - 0: NONE; 1: FRONT; 2: BACK; 3: undefined encoding.
   * - 7
     - ``matrix_forward``
     - RW
     - Send matrix results to registers instead of clipping.
   * - 8
     - ``enable_pcounters``
     - RW
     - Allow performance counter increments.
   * - 9
     - ``raster_forward``
     - RW
     - Bypass the packer and send processed triangles directly to the raster engine.
   * - 31:10
     - Reserved
     - —
     - Read as zero.

Command bits trigger an action when written as one and always read as zero.
Writing zero to a command bit issues no command. For input-consumption
control, SOFT_RESET and STOP take priority over START. ``enable`` is
independent of the consumption state: START can latch the started state
while enable is zero, but no vertices are consumed until enable is set.

A write to byte 0 updates **all** fields 7:0. A START or STOP write therefore
also updates enable, front_face, cull_mode, and matrix_forward. Include the
persistent configuration in the written value to preserve it. Byte 1 controls
bits 8 and 9; bytes 2 and 3 have no effect.

For example, after loading the matrix and viewport, ``GE_CTRL=0x00000103``
enables the GE, issues START, and enables counters, with CW, NONE, and
forward disabled, when bytes 0 and 1 are written. A later read returns
``0x00000101``. For STOP with the same settings, write ``0x00000105``; for
soft reset, write ``0x00000109``. The persistent value after either command
is still ``0x00000101``.

For direct raster output with counters enabled, write ``GE_CTRL=0x00000303``
to enable the GE and issue START. The persistent value reads as
``0x00000301``. ``raster_forward`` resets to zero on hardware reset and
is preserved by soft reset. It selects the destination after culling;
``matrix_forward`` still diverts input vertices before clipping, so enabling
both does not send newly consumed vertices to the raster engine. See
:doc:`packer` for the direct transfer contract and mode changes.

GE_STATUS: live status
----------------------

.. list-table:: GE_STATUS bits, also used by IRQ_EN and IRQ_PEND
   :header-rows: 1
   :widths: 15 25 60

   * - Bits
     - Field / event
     - Meaning
   * - 0
     - ``busy``
     - Geometric pipeline is not empty, including partial vertex groups.
   * - 1
     - ``done``
     - Transfer-completion level reported by the external memory unit.
   * - 2
     - ``stall``
     - GE is enabled and the pipeline input is blocked.
   * - 3
     - ``errors[0]``
     - Clipping error.
   * - 4
     - ``errors[1]``
     - Perspective error caused by zero w.
   * - 31:5
     - Reserved
     - Zero.

``errors[1:0]`` is a one-hot code: 00 means no error, 01 means clipping,
and 10 means perspective. If both error sources assert together, only
clipping is reported. The pipeline does not generate 11. STATUS does not
retain past errors and cannot be cleared by writing it.

BUSY excludes input FIFO words, forwarded matrix results, and triangles
or words already in the packer. DONE is not latched by the GE and does not
mean that the pipeline or output is empty. STALL is set while the GE is
enabled and its pipeline input is blocked. This includes output backpressure
and an input triangle buffer still occupied by clipping. STOP and missing
input words do not by themselves set STALL.

Memory buffer registers
-----------------------

``GE_VTX_BASE``, ``GE_VTX_END``, ``GE_PRIM_BASE``, and ``GE_PRIM_END`` hold
32-bit byte addresses. All bits 31:0 are writable with byte strobes, and
the external memory unit receives these addresses unchanged. The GE does
not check alignment, base/end ordering, triangle counts, or output-buffer exhaustion.
The external unit must define the end-address convention and transfer protocol.

Interrupt registers
-------------------

``GE_IRQ_EN[4:0]`` masks the five events listed in the STATUS table. A set
bit allows that pending event to raise an interrupt. Bits 31:5 are
reserved, and only writes to byte 0 update the mask.

``GE_IRQ_PEND[4:0]`` latches rising edges of the corresponding STATUS bits,
**even while the event is masked**. Writing one clears a pending bit;
writing zero preserves it. Byte 0 must be selected for the write. A new event on
the same cycle as a clear takes priority and leaves the bit set. The
interrupt remains asserted while any enabled event is pending.

A status bit that stays high does not generate a fresh event every cycle.
For example, consecutive perspective errors without an intervening low
status bit produce one rising edge. The BUSY event marks the transition
to an occupied pipeline, rather than completion. DONE records the external
signal's rising edge. Soft reset clears pending events and resets edge detection, while
preserving IRQ_EN. An external state such as DONE that remains
high may therefore be latched again after reset.

Matrix coefficients and forwarded results
-----------------------------------------

Each ``GE_MTX_rc`` is a fully writable signed Q16.16 word at offset
``0x30 + 4 × (4r + c)``. Registers follow matrix rows. Reset produces a
zero matrix, not an identity matrix. Partial writes update only selected
bytes. Coefficients are live settings rather than a saved configuration
for each job; changing them during processing can transform vertices with
different settings.

``GE_MTX_RES_0``, ``GE_MTX_RES_1``, ``GE_MTX_RES_2``, and ``GE_MTX_RES_3``
contain x, y, z, and w of the last valid forwarded vertex, all in Q16.16.
They are RO, so writes report an error. Values persist until another forward
update or hardware/software reset. There is no dedicated ready bit, and
reading the four words does not prevent later updates. See :doc:`matrix`.

Viewport registers
------------------

``GE_VP_WIDTH[31:0]`` and ``GE_VP_HEIGHT[31:0]`` are unsigned integer pixel
dimensions, writable by byte. They contain no fractions, origin, or scissor
limits. Hardware reset clears them; soft reset preserves them. Hardware
does not reject zero or values too large for the output coordinates.
See :doc:`viewport` for conversion and the current z format.

Performance counters
--------------------

The four counters are RO, unsigned 32-bit cumulative values. Hardware reset
and soft reset clear them. They wrap modulo 2^32. ``enable_pcounters=0``
freezes increments without clearing existing values. There is no separate
clear write or atomic snapshot.

``GE_TRI_INPUT`` counts input triangles whose clipping has completed,
including rejected ones. It does not count the arrival of input words
or vertices. It does not increment
for forwarded vertices.

``GE_TRI_OUTPUT`` increments when a processed triangle is accepted by
the selected output: the packer, or the raster engine when
``raster_forward=1``. It does not count external memory writes. It can exceed TRI_INPUT because clipping may
produce several triangles from one input.

``GE_TRI_DISCARDED`` adds trivial clip-test rejects and culler discards,
including zero-area triangles. If both occur in one cycle it increments
by two. It does not directly count polygons reduced to fewer than three
vertices by clipping, groups removed for perspective errors, or clipping
errors. There is no general identity
``TRI_INPUT = TRI_OUTPUT + TRI_DISCARDED``.

``GE_STALL`` increments when the geometric pipeline contains data and
its input cannot advance. This includes GE disable: if counters remain
enabled and data is in flight, cycles with enable=0 can count. It does not measure total job cycles,
only memory waits, or necessarily the same level as STATUS.STALL.

Disabling and reenabling counters halfway through a job does not recover
missed events. For comparable job measurements, start with a flushed datapath
and cleared counters, and keep counting enabled until completion.

Reset effects
-------------

.. list-table:: State after reset
   :header-rows: 1
   :widths: 40 30 30

   * - Element
     - Hardware reset
     - Soft reset
   * - Persistent CTRL configuration
     - Zero.
     - Preserved.
   * - Consumption state set by START
     - Stopped.
     - Stopped.
   * - Buffer addresses
     - Zero.
     - Preserved.
   * - Matrix coefficients and viewport dimensions
     - Zero.
     - Preserved.
   * - IRQ_EN
     - Zero.
     - Preserved.
   * - IRQ_PEND and event detection
     - Zero.
     - Zero.
   * - Forward results
     - Zero.
     - Zero.
   * - Counters and pending data
     - Zero / empty.
     - Zero / empty.

Reset discards pending data. Queue contents and output values from before
reset must not be treated as new results; wait for new accepted transfers.
