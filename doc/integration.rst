GE and raster integration
=========================

``hw/prismaGPU.sv`` instantiates the geometry engine and raster engine on one
clock and reset. ``hw/_prismaGPU.f`` includes the wrapper. The shared register
bus uses seven-bit **word** addresses: bit 6 selects RE, and bits 5:0 select a
register within that engine. GE occupies byte offsets 0x000--0x0FF; RE occupies
0x100--0x1FF. Byte strobes and access errors retain the individual banks'
semantics. The top-level register ports use the ``reg_*`` prefix, including
``reg_write_i``, ``reg_read_i``, and their address/data/error signals.
``interrupt_o`` is the OR of the two engines' interrupts.

The wrapper preserves the existing GE input/output FIFO and buffer-address
ports for an external memory feeder. It does not implement vertex DMA or
copy packed GE output into primitive DDR memory. The RE's independent DDR
read and write channels remain exposed. All addresses on those channels are
byte addresses; see :doc:`re/memory_unit`.

Primitive selection
-------------------

The two source modes share setup and the entire pixel/memory pipeline::

    GE direct triangle ---------+
                                +-- source mux --> setup --> raster/pixels --> DDR
    RE primitive memory --------+

In command mode, ``RE_CTRL.passthrough=0`` and commands select how many stored
primitives to draw. GE can independently produce packed output with
``GE_CTRL.raster_forward=0``. The external memory integration must store that
output before a command consumes it.

In passthrough mode, set ``GE_CTRL.raster_forward=1`` and
``RE_CTRL.passthrough=1`` (RE control bit 4). The raster controller accepts
triangles directly without fetching a command or primitive record. It uses
one additional ``STREAM_RUN`` state and reuses initialization, pause, error,
reset, and final drain states. There is no additional FIFO.

The data mux carries the unchanged 512-bit ``proc_triangle_t``: signed screen
X/Y retain eight fractional bits, Z retains its unsigned sixteen fractional
bits, and signed doubled area retains sixteen fractional bits. No arithmetic,
rounding, or format conversion occurs at this connection.

Backpressure
------------

The transfer condition is ``raster_valid && !raster_stall``. RE's stall includes
setup availability and the controller's permission to accept a triangle.
It is asserted in command mode, before START, while paused, and during errors
or reset. GE selects either this stall or packer backpressure according to
``raster_forward``. A valid triangle stays unchanged until accepted, unless
GE is explicitly disabled or reset. Pipeline counters count acceptance, not
cycles spent holding valid.

An inactive RE can therefore stall GE all the way to its input FIFO. The
external feeder must still respect ``input_word_count_o`` and the configured
FIFO capacity. Writes while full are not retried by the wrapper.

Starting and ending a stream
----------------------------

1. Configure the GE matrix and viewport, and RE viewport, framebuffer range,
   shading, and optional depth state. The two viewports must agree.
2. With both paths idle, select the two direct-mode bits. For example,
   ``GE_CTRL=0x303`` enables GE, counters, raster forwarding, and pulses START.
   Write ``RE_CTRL=0x113`` at wrapper byte offset 0x100 to enable RE, counters,
   passthrough, and pulse START. RE can be started before GE input is supplied.
3. Feed complete four-word input triangles. RE processes surviving GE output
   triangles whenever setup is available. Clipping may produce several output
   triangles, and culling may produce none.
4. Assert ``stream_end_i`` with or after the last accepted input word, and hold
   it until ``done_o``. Submit no more words for that stream. A gap in input is
   not an end marker. The wrapper waits for the GE FIFO, registered input
   word, partial input triangle, and geometry pipeline to drain before passing
   the end indication to RE. Incomplete four-word records cannot complete.
5. RE drains setup and pixels, flushes the framebuffer, and waits for memory
   completion before asserting DONE and generating its normal DONE interrupt.
   Deassert ``stream_end_i`` before starting the next stream.

``done_o`` is the raster controller's session completion (stream or command
list). It remains asserted until the next START or reset, following RE status.
``busy_o`` covers queued GE input, GE processing, and RE execution/writeback;
like GE's direct-path ``idle_o``, it excludes old packed GE output awaiting
external storage. ``ge_done_i`` remains the original external memory-job
completion input for GE status/interrupts; it is not raster completion.

STOP (``RE_CTRL=0x115`` with counters enabled) immediately prevents additional
triangle acceptance, drains already accepted work, flushes, and reports PAUSED.
GE retains queued work under stall. START resumes the stream. Clearing RE enable
has the same pause effect. Software may update rendering configuration while
paused after work has drained; it must preserve the source bit. A write that
changes the source while RE is busy or paused is rejected in full. Soft reset
ends the paused session and permits a later source change. GE rejects a change
to ``raster_forward`` while input or pipeline work remains; it does not discard
previously packed output on a mode change.

Software must preserve persistent mode bits in START/STOP/reset writes.
On an RE fault, GE stays stalled; recovery from a partially rendered stream
requires resetting both engines and resubmitting the intended input. RE soft
reset drains already accepted DDR transactions and discards local rendering
work. Neither engine reset clears framebuffer or depth memory.

Configuration and scope
-----------------------

Passthrough START validates the framebuffer range and any enabled depth range,
plus the existing texture/perspective configuration rule. Command and primitive
ranges are unused and need not be valid. BUSY stays asserted even during an
input gap, preventing configuration changes during a stream. CMD_EXHAUSTED is
zero in passthrough mode; DONE and the triangle/pixel counters remain useful.

No raster command program is needed for untextured rendering. Depth memory
can be initialized by the host. Texture loading and CLEAR_Z remain available
through command mode; a completed preparation list can precede a passthrough
session. Texture RAM is retained when changing source modes. There are no new
automatic clear, texture-load, or per-triangle state-change mechanisms.

Verification
------------

Run ``make -C tb/gpu test`` for integrated tests and ``make -C tb/gpu lint``
for elaboration/lint with the repository's existing arithmetic width waivers.
The integration test uses delayed DDR responses, checks independent pixel-center
coverage, and exercises held writes, source protection, gaps, empty streams,
pause/resume, clipping/discard, depth rejection, reset with an outstanding DDR
write, and command-mode rendering of packed GE output.
