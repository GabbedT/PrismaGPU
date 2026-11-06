Register map
============

``hw/pkg/re_registers_pkg.sv`` defines the Raster Engine's register addresses
and packed field types. ``hw/raster_engine/raster_engine_registers.sv``
implements the register bank, command pulses and interrupt capture. It supplies
``raster_config_t config_o`` directly, including the one-bit viewport mode.
The integrated ``raster_engine.sv`` connects this bank to the command processor
and pixel pipeline; see :doc:`command_processor`.

Registers are 32 bits wide. Byte offsets are relative to the system-assigned
RE base; the six-bit internal word address is the byte offset divided by four.
Unlisted addresses are invalid. Unused bits in valid registers read as zero
and ignore writes. Packed types contain only the low used portion, including
padding between fields where needed; register reads zero-extend them.

The interface matches the GE register bank: writes take effect on the rising
clock edge, with four byte strobes preserving unselected bytes. Read data is
combinational; ``read_i`` qualifies the access-error output. Writes to RO or
unlisted addresses report ``write_error_o`` and have no effect. Unlisted reads
return zero with ``read_error_o``. Error outputs are qualified by their requests.

While ``busy_i`` is high, writes to buffer addresses and rendering configuration
also report an access error and leave the previous values intact. Control and
interrupt writes remain available. This protection applies even if enable is
zero. The controller must keep busy asserted for the whole execution, including
stalls and final writeback, and prevent configuration changes on the edge that
accepts a triangle. Configuration can be changed while paused once busy is low.
Bus access errors do not themselves generate rendering error interrupts.

.. list-table:: Registers
   :header-rows: 1

   * - Byte offset
     - Name
     - Access
   * - 0x00
     - ``RE_CTRL``
     - RW / pulse
   * - 0x04
     - ``RE_STATUS``
     - RO
   * - 0x08
     - ``RE_CMD_BASE``
     - RW
   * - 0x0C
     - ``RE_CMD_END``
     - RW
   * - 0x10
     - ``RE_PRIM_BASE``
     - RW
   * - 0x14
     - ``RE_PRIM_END``
     - RW
   * - 0x18
     - ``RE_IRQ_EN``
     - RW
   * - 0x1C
     - ``RE_IRQ_PEND``
     - RW1C
   * - 0x20
     - ``RE_ZBUF_BASE``
     - RW
   * - 0x24
     - ``RE_ZBUF_END``
     - RW
   * - 0x28
     - ``RE_DRAW_CFG``
     - RW
   * - 0x2C
     - ``RE_Z_CFG``
     - RW
   * - 0x30
     - ``RE_TEX_CFG``
     - RW
   * - 0x34
     - ``RE_VP_CFG``
     - RW
   * - 0x38
     - ``RE_BLEND_CFG``
     - RW
   * - 0x3C
     - ``RE_SCISSOR_X``
     - RW
   * - 0x40
     - ``RE_SCISSOR_Y``
     - RW
   * - 0x44
     - ``RE_CMD_PTR``
     - RO
   * - 0x48
     - ``RE_PRIM_PTR``
     - RO
   * - 0x4C
     - ``RE_FRMBUF_BEGIN``
     - RW
   * - 0x50
     - ``RE_FRMBUF_END``
     - RW
   * - 0x80
     - ``RE_TRI_INPUT``
     - RO
   * - 0x84
     - ``RE_TRI_DONE``
     - RO
   * - 0x88
     - ``RE_TRI_DISCARDED``
     - RO
   * - 0x8C
     - ``RE_STALL``
     - RO
   * - 0x90
     - ``RE_PIXEL_OUTPUT``
     - RO
   * - 0x94
     - ``RE_PIXEL_Z_REJECT``
     - RO
   * - 0x98
     - ``RE_CYCLES``
     - RO

Control, status and interrupts
------------------------------

``re_control_t`` maps enable to bit 0, START to bit 1, STOP to bit 2,
SOFT_RESET to bit 3, passthrough to bit 4, and counter enable to bit 8. Command bits are write-one
pulses and read as zero. The bank forwards each selected command bit independently
for one cycle, as in the GE. A write to byte 0 also updates enable, so software
must include the persistent enable and passthrough values in START/STOP/reset writes.
A write changing passthrough while busy or paused is rejected in full. Byte 1 updates
counter enable; bytes 2 and 3 have no effect.

In passthrough mode, START arms direct triangle acceptance without a command
list. STOP drains accepted triangles before pausing; START resumes the stream.
An explicit end-of-stream indication causes final draining and DONE. See
:doc:`../integration` for the wrapper and programming sequence.

In command mode, the external controller must implement STOP by finishing the current command
before pausing, and START by resuming at the next command or starting a new list
at ``RE_CMD_BASE``. It must prioritize reset and STOP over START when written
together. Clearing enable should prevent new work while allowing existing work
to drain. The bank itself does not schedule or cancel pipeline work.

Hardware reset clears all bank-owned state; it is synchronous by default,
or asynchronous with ``ASYNC`` defined, matching the GE. Soft reset clears
the latched NOTIFY ID, pending interrupts and their edge history on the edge
that consumes ``soft_reset_o``. It preserves configuration, persistent control
and IRQ_EN.
The external controller must consume the reset pulse to reset its execution,
status, pointers and counters, and drain or reset external memory transactions
before restarting. Memory contents are not cleared by the register bank.

``re_status_t`` maps BUSY, DONE, STALL, PAUSED, CMD_EXHAUSTED and ERROR to
bits 0 through 5. Bits 31:6 contain NOTIFY_ID, the unsigned 26-bit ID of the
last completed NOTIFY command. The bank captures ``notify_id_i`` when the
controller pulses ``notify_valid_i`` at NOTIFY completion, together with
PAUSED or DONE entry. Capture is independent of interrupt masking. Hardware
and soft reset clear the ID, with reset taking priority over capture. IRQ
acknowledgement, START, STOP, errors and natural list completion preserve it.
Zero is a valid ID; use the status/IRQ flags to detect completion events.
See :doc:`commands` for the payload encoding.

DONE denotes completion of the whole list or passthrough stream, including
accepted output pixels and completed depth writes, rather than the current
pipeline's per-triangle completion. CMD_EXHAUSTED can assert before the
remaining work drains. The integrated controller also waits for framebuffer write responses. All status fields except ERROR and NOTIFY_ID are
live external inputs; DONE is neither stretched nor latched by the bank.
ERROR is the OR of pending error events, independently of their interrupt masks.

``re_irq_t`` defines a separate layout shared by IRQ_EN and IRQ_PEND:
bit 0 DONE, bit 1 PAUSED, bit 2 command error, bit 3 configuration error,
bit 4 address error and bit 5 arithmetic error. Address errors cover
alignment, buffer bounds, address overflow and DDR access errors. Empty and degenerate
triangles are normal discards. The bank detects rising edges of done, paused
and the four separate error inputs. Multiple errors can latch on the same edge.
Pending events latch even while masked; writing one in byte 0 clears a bit,
with a simultaneous new event taking priority. Writing zero preserves it.
IRQ_EN also uses only byte 0; the interrupt output is asserted whenever any
enabled event is pending.

A source held high does not relatch after W1C until sampled low and high again.
Consecutive errors without an intervening low sample therefore form one event.
A source held high across soft reset may latch again after the reset clears
edge history. There are no separate error or last-result registers.

Rendering configuration
-----------------------

``re_draw_config_t`` uses bits 0 through 4 for Gouraud shading, texture
enable, perspective correction, Z interpolation and scissor enable.
``re_z_config_t`` uses bit 0 for test enable, bit 1 for write enable and
bits 4:2 for ``re_z_compare_t``: NEVER, LESS, EQUAL, LEQUAL, GREATER,
NOTEQUAL, GEQUAL and ALWAYS have values 0 through 7. Disabling testing
also suppresses depth writes. ``re_texture_config_t`` reuses the existing
``texture_size_t`` in bits 1:0 for sizes 8, 16, 32 and 64.

``RE_VP_CFG[0]`` selects one of two fixed viewport modes using
``re_viewport_config_t`` and ``re_viewport_size_t``. Zero selects 640x480;
one selects 320x240. Upper bits read as zero and ignore writes. Only byte-zero
writes change the mode. Hardware reset selects 640x480; soft reset preserves it.
The former height-register address, 0x38, now holds ``RE_BLEND_CFG``:
bit 4 enables framebuffer destination blending and bits 3:0 select constant
source alpha (0..15). Bits 31:5 are ignored. Hardware reset disables blending
and clears alpha; soft reset preserves it. Busy write protection and byte
strobes follow other configuration registers. Opaque draws bypass the stage.
See :doc:`pixel_blender` for rounding, ordering and depth behavior.
The bank passes ``viewport_size`` into ``raster_config_t``. Consumers derive
constant dimensions and row strides locally; width, height and pitch fields
are absent from the internal configuration.

.. list-table:: Fixed surface sizes
   :header-rows: 1

   * - Mode
     - Resolution
     - Z pitch (bytes)
     - Z allocation (bytes)
     - RGB444 allocation (bytes)
   * - 0
     - 640x480
     - 1280
     - 614400
     - 460800
   * - 1
     - 320x240
     - 640
     - 153600
     - 115200

``re_scissor_x_t`` places inclusive XMIN in bits 9:0 and XMAX in bits 25:16;
``re_scissor_y_t`` places inclusive YMIN in bits 8:0 and YMAX in bits 24:16.

The busy write protection keeps rendering configuration stable through the
triangle's processing, including stalls and depth writeback. Texture sampling
requires perspective correction. The bank stores the encoded fields without
validating rendering combinations: upper bits are ignored, and invalid
combinations remain for the pipeline/controller to detect. These fields supply
the existing ``raster_config_t`` interface described in :doc:`pixel_raster_pipeline`.

Buffers and counters
--------------------

Buffer addresses and execution pointers are unsigned 32-bit byte values. All buffer
ranges are half-open: [BASE, END). The primitive buffer contains the GE's
64-byte records, with a 16-byte-aligned base and a size divisible by 64.
Commands occupy one 32-bit word; command BASE/END must be 4-byte aligned.
Their encoding and execution contract are defined in :doc:`commands`.
CMD_PTR identifies the next command to execute; PRIM_PTR identifies the next
primitive to acquire.

Depth storage uses unsigned Q0.16 samples in 16-bit slots. ZBUF_BASE must be
16-byte aligned. There is no pitch register or internal pitch field. The pipeline uses
1280 or 640 bytes per row according to ``RE_VP_CFG``. The allocation must contain at
least ``pitch * height`` bytes. The bank passes all 32 address bits through
unchanged. Alignment, base/end ordering, allocation size and overflow checks
belong to the external memory controller; they are not performed during writes.
Address calculations must check overflow before narrowing to 32 bits.

The framebuffer uses compact RGB444 pixels, matching ZenithSoC VGA: R[11:8],
G[7:4], B[3:0], lowest stream bits first. RE_FRMBUF_BEGIN is 16-byte aligned;
RE_FRMBUF_END is exclusive. Rows have no padding, and their physical width equals
the width selected by RE_VP_CFG. Allocate ``align_up(ceil(12*width*height/8),16)`` readable/writable
bytes. The writer preserves untouched pixels, including partial bytes.

Counters are unsigned 32-bit cumulative values, wrapping modulo 2^32.
Like execution pointers, they are live read-only inputs, with no internal copy
or atomic snapshot. Their owner must freeze increments when counter enable is
zero and clear them on hardware and soft reset. TRI_INPUT counts accepted triangles, TRI_DONE counts
completed triangles including discards, and TRI_DISCARDED counts setup
discards. STALL counts cycles waiting for memory or output backpressure;
PIXEL_OUTPUT counts accepted output pixels, PIXEL_Z_REJECT counts depth
failures and CYCLES counts busy cycles.

Verification
------------

Run from the repository root:

.. code-block:: console

   make -C tb/re/registers lint test

The directed test runs with synchronous and asynchronous reset. It checks the
entire register address window, all byte-strobe combinations for configuration,
output field mapping, both fixed modes, command
pulses, busy protection, RO inputs, interrupt masking and edge capture,
simultaneous W1C/events, and soft-reset preservation. Build artifacts are under
``out/re_registers/``.
