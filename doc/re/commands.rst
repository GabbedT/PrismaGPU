Raster Engine commands
======================

``hw/pkg/re_commands_pkg.sv`` defines the command format. The command
processor is implemented in ``hw/raster_engine/command_processor/`` and
integrated by ``raster_engine.sv``; see :doc:`command_processor`.

Each command occupies one 32-bit word, with opcode in bits 31:28 and payload
in bits 27:0. Commands execute in increasing address order over the half-open
range [RE_CMD_BASE, RE_CMD_END). Both boundaries are 4-byte aligned. On normal
completion, RE_CMD_PTR advances by four bytes. An unknown opcode or nonzero
unused payload bits raises a command error and stops execution.

All commands use ``re_command_t``. Its packed ``payload`` union provides
``address_upper`` for LOAD_TEXTURE, ``primitive_count`` for DRAW and
``clear_z.depth`` with ``clear_z.unused`` for CLEAR_Z, and ``notify.id`` with
``notify.unused`` for NOTIFY. The ``raw`` member accesses all 28 payload bits.
All union members
occupy 28 bits, keeping the complete command exactly 32 bits wide.

.. list-table:: Command encoding
   :header-rows: 1
   :widths: 15 25 60

   * - Opcode
     - Command
     - Payload [27:0]
   * - 0x1
     - LOAD_TEXTURE
     - Source byte address [31:4]
   * - 0x2
     - DRAW
     - Unsigned primitive count
   * - 0x3
     - NOTIFY
     - Bits 25:0: unsigned ID; bits 27:26: zero
   * - 0x4
     - CLEAR_Z
     - Bits 15:0: unsigned Q0.16 depth; bits 27:16: zero

LOAD_TEXTURE
------------

The source must be 16-byte aligned. Its full 32-bit byte address is
reconstructed as ``{payload, 4'b0000}``; no additional command word is needed.
Software must check alignment before encoding the address, rather than
silently truncating its low bits.

RE_TEX_CFG selects N = 8, 16, 32 or 64. The source contains N*N RGBA4444 texels
in consecutive rows, occupying 2*N*N bytes. The loader maps compact source
rows to the texture RAM's fixed stride of 64 texels; eight consecutive texels
form each 128-bit transfer, with the first texel in bits 15:0.

The controller checks source-address overflow, waits for previous rendering
to complete before overwriting texture RAM, and finishes the entire load
before executing the next command.

DRAW
----

The count ranges from zero to 2**28 - 1; zero performs no work. A new list
initializes RE_PRIM_PTR from RE_PRIM_BASE. DRAW consumes count consecutive
64-byte records, advancing RE_PRIM_PTR as records are acquired. Discarded
triangles still count as consumed primitives.

Before issuing work, the controller checks the entire requested range against
RE_PRIM_END, including address overflow. All primitives complete before the
next command executes, including output pixel acceptance and depth write
responses.

NOTIFY
------

NOTIFY carries a software-selected ID from zero to 2**26 - 1; bits 27:26 must
be zero. The controller waits for previous work to finish, then latches the ID
into RE_STATUS[31:6] and halts command execution. If more
commands remain, the controller asserts PAUSED, clears BUSY and generates the
existing PAUSED interrupt event. Software may update rendering configuration
while paused. START resumes at the command following NOTIFY, preserving
RE_PRIM_PTR. Acknowledging the interrupt alone does not resume execution.

At the end of the list, NOTIFY instead reports DONE and generates the DONE
event. Reaching RE_CMD_END without NOTIFY also completes the list after all
work drains. Events latch in RE_IRQ_PEND even when masked; RE_IRQ_EN controls
the interrupt line. The integrated processor waits for framebuffer writer completion before
reporting either event.

The controller pulses ``notify_valid_i`` with ``notify_id_i`` on entry into
PAUSED or DONE. The bank captures the ID before the controller exposes these
live status flags; its edge detector captures the IRQ on the following clock.
Both polling and interrupt handling therefore observe the completed ID. Capture is independent of IRQ_EN. The ID remains
unchanged by interrupt acknowledgement, START, STOP, errors and natural list
completion without NOTIFY. Only a subsequent completed NOTIFY or hardware/soft
reset changes it; resets take priority over a simultaneous capture and clear it
to zero. Zero is also a valid ID, so the ID alone does not indicate a new event.

CLEAR_Z
-------

CLEAR_Z fills the active viewport's depth samples with the supplied unsigned
Q0.16 value. For the usual LESS/LEQUAL depth comparisons, ``0xffff`` is the
largest representable value. This is 65535/65536, not an exact 1.0.

The controller writes 640x480 or 320x240 16-bit samples according to RE_VP_CFG,
starting at RE_ZBUF_BASE and using 1280 or 640 bytes per
row. There is no row padding; memory outside the viewport is preserved. Scissor,
depth comparison and depth write enable do not affect this command.

Before writing, validate 16-byte base alignment and the allocation of
614400 bytes (VGA) or 153600 bytes (QVGA) within
[RE_ZBUF_BASE, RE_ZBUF_END), detecting overflow before narrowing addresses.
The command waits for previous rendering and completes only after all clear
write responses arrive. Invalid alignment, bounds or overflow generate an
address error. Errors stop execution.

For example, ``0x4000ffff`` clears the viewport depth samples to the maximum
value, ``0x20000078`` draws 120 primitives and ``0x3000002a`` notifies the CPU
with ID 42. Firmware extracts the last completed ID with ``RE_STATUS >> 6``.
