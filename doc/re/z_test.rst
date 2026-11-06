Depth test and double-buffered scanlines
========================================

The modules in ``hw/raster_engine/z_test/`` provide a standalone depth-test
stage with two scanline banks and a generic 128-bit DDR interface. Each bank
holds up to 640 depth samples. There is no fragment FIFO. The pixel pipeline
stalls when a bank is not ready or the consumer holds the comparison result.

Modules and storage
-------------------

``z_buffer_line`` contains the two memories. The selected front bank supports
one synchronous pixel read and one pixel write with independent addresses
per cycle. The other bank supports a 128-bit read or masked write. A DDR
operation must not coincide with a pixel operation on the same bank. Reads
have one clock of latency; data stays available until another read on that
interface. A masked pixel read still returns a response, with
``z_read_enabled_o=0`` and zero data. Masked DDR read bytes return zero and
have their corresponding ``ddr_read_mask_o`` bits cleared.

Both buffer-select inputs identify physical banks A=0 and B=1. The pixel
selection determines which one currently acts as the front buffer; a DDR
transaction keeps its physical bank selection until it completes.

``viewport_size_i`` selects 640x480 (zero) or 320x240 (one), using
``re_viewport_size_t``. It must remain stable until ``request_o`` indicates
that the wrapper is idle. Pixel addresses are checked against the selected
width. Both widths contain whole aligned DDR words, so a single word-range
check gates the incoming DDR mask; span masks still select individual lanes. No data RAM is
reset or cleared by reset.

``Z_WIDTH`` supports 1 through 32 unsigned bits. Storage uses the following
layout, with the lowest X in the least significant slot:

.. list-table::
   :header-rows: 1

   * - Z width
     - Storage slot
     - Samples per 128-bit word
     - Bytes per bank
   * - 1--16
     - 16 bits
     - 8
     - 1280
   * - 17--32
     - 32 bits
     - 4
     - 2560

Pixel writes zero the unused high slot bits. DDR transfers preserve all
enabled bytes, including padding. This avoids depths straddling a DDR word
and avoids division by a runtime sample size. Independent RAM lanes provide
the wide port without a wide read-modify-write operation for each pixel.
The RTL uses synchronous reads, byte write enables and ``ram_style="block"``.
Actual BRAM packing and timing must be checked in synthesis.

Depth samples must already use the chosen storage encoding. The stage does
not round, saturate or convert the interpolator's signed F16 result. In
particular, the raw F16 encoding of 1.0 is 65536 and cannot be passed directly
to a 16-bit port. Quantize/clamp upstream, or choose a width and encoding
that retains the endpoint. The DDR depth buffer must be initialized by its
owner before rendering, or initialized with the exclusive clear service below.

Span descriptors and double buffering
-------------------------------------

``z_buffer_controller`` accepts the first descriptor on
``start_i && request_o``. It contains:

* ``line_address_i``: byte address of X=0 of that row, aligned to 16 bytes;
* ``x_start_i`` and ``x_end_i``: inclusive bounds, with
  ``0 <= x_start_i <= x_end_i < 640``;
* ``last_line_i``: whether this is the final nonempty span of the triangle.

The lookahead interface accepts another descriptor on
``next_valid_i && next_ready_o``. Hold its fields and validity until this
handshake. Descriptors are captured; their source may then advance. Empty
spans must be skipped by the producer. Successive descriptors within a
triangle must describe distinct rows whose allocated 128-bit words do not
overlap. Both fixed modes have naturally aligned rows without padding.

Supplying row addresses avoids a runtime Y-by-pitch multiplier. A span
producer can maintain the address by adding the row pitch when advancing Y.
The integrated pipeline derives the row stride from the video mode and
16-bit depth slots. Standalone scanline descriptors still carry explicit
row addresses; CLEAR_Z always uses compact fixed-mode storage.

.. list-table::
   :header-rows: 1

   * - Phase
     - Bank A
     - Bank B
   * - Startup
     - Fill span 0
     - Free
   * - Render span 0
     - Pixel reads and writes
     - Fill span 1
   * - Render span 1
     - Evict span 0, then fill span 2
     - Pixel reads and writes
   * - Render span 2
     - Pixel reads and writes
     - Evict span 1, then fill span 3

``new_line_o`` pulses for one cycle after a filled bank becomes active.
``active_x_start_o`` and ``active_x_end_o`` already describe the new span.
Pixel acceptance is disabled during this pulse, allowing the interpolator
to initialize its accumulators. Pixel X is a row-relative screen coordinate,
not an offset from the start of the span.

The final pixel is identified by X equal to the active inclusive end. The
wrapper waits for that pixel's comparison to be consumed and any depth
write to commit before releasing the bank. The other bank can then become
active even while the previous bank is being written back. If its fill is
unfinished, the pixel path stalls until it is ready.

Each bank has one dirty bit. A clean span needs no eviction. A dirty span
writes its enabled bytes, including depths that did not change. The first
and last burst masks protect pixels outside the span; the memory further
clips writes to the viewport width. After an eviction response the bank is
free to accept the next lookahead descriptor. No associative tags or cache
replacement policy are used.

``done_o`` pulses only after the last span is consumed and all pending
evictions have completed. ``request_o`` then permits the next triangle.
This is a visibility barrier: prefetch from another triangle cannot read
depths before the preceding triangle's writes have completed.

Generic DDR protocol
--------------------

A command transfers on ``ddr_request_o && ddr_ready_i``. The command, byte
address, write data and mask remain stable under backpressure.

* Every command addresses one aligned 16-byte word.
* ``ddr_write_o=0`` requests a read; ``1`` requests a write.
* A mask bit of one enables the corresponding byte, unlike a native MIG
  write mask. An adapter must invert masks if its downstream interface
  uses one to suppress a byte.
* The controller has one outstanding transaction. Every accepted command
  receives ``ddr_response_valid_i``, including writes. The earliest
  response is the cycle following acceptance; same-cycle responses are
  not supported. There is no response-ready signal.
* On a read response, ``ddr_read_data_i`` supplies the word. A memory
  implementation may ignore the read mask and return all sixteen bytes;
  the line buffer applies the mask on filling.
* A write response must guarantee that a subsequent read observes the
  write. A native DDR adapter must provide this completion/ordering
  contract; acceptance of write data alone is not this response.

The buffer-side ``buffer_ddr_address_o`` and the memory's ``ddr_address_i``
are instead relative pixel indices, aligned to eight slots for 16-bit
storage or four slots for 32-bit storage. The controller converts these
to external byte addresses with a constant shift and addition.

The interface deliberately trades transaction throughput for a small FSM.
There are bubbles between 128-bit commands and no queue of outstanding
reads. Double buffering hides the memory service time only when processing
the other span takes long enough. DDR throughput and span-size measurements
should guide any later increase in outstanding transactions.

Pixel protocol and depth comparison
-----------------------------------

``depth_tester`` holds one pixel register aligned with the synchronous BRAM
read. It can accept one pixel per cycle inside a span when the consumer is
ready. It supports these unsigned comparisons:

.. list-table::
   :header-rows: 1

   * - ``compare_i``
     - Test
   * - 0
     - Never
   * - 1
     - Less
   * - 2
     - Equal
   * - 3
     - Less or equal
   * - 4
     - Greater
   * - 5
     - Not equal
   * - 6
     - Greater or equal
   * - 7
     - Always

Test configuration is captured with each accepted pixel. Disabling the
test passes enabled pixels and suppresses depth writes. ``write_enable_i``
can independently suppress updates while retaining the comparison.
Viewport-disabled pixels are discarded, including when the depth test is
disabled. A forwarding register resolves consecutive reads and writes to
the same pixel without relying on a BRAM read-during-write mode.

At the wrapper, input acceptance is ``pixel_valid_i && !stall_o``. Hold the
pixel and its configuration until acceptance. Pixels outside the active
span are not accepted. Supply the end pixel only after all earlier pixels
of that span; consuming it closes the span, whether it passes or fails.

``result_valid_o`` identifies a result for every accepted input, including
discarded pixels. ``pixel_valid_o`` identifies a passing result and
``discard_o`` a failing result. Results remain stable under downstream
``stall_i``. A result is consumed when ``result_valid_o && !stall_i``;
only then can a passing depth write commit. Downstream logic must consume
discarded results as well, otherwise a rejected final pixel cannot release
the span. This initial stage commits depth immediately and assumes no later
fragment discard that would require undoing that depth write.

Reset and integration
---------------------

Reset is synchronous and aborts controller/pixel state; RAM data is retained.
Reset the DDR adapter at the same time or drain it first so that an old
response cannot be mistaken for a new transaction. Reset during rendering
does not roll back writes already committed to DDR. Restart only with a
consistent external depth buffer.

The wrapper does not carry X/Y, color or texture payloads through the
comparison stage. Hold their corresponding external pipeline register on
``stall_i`` and load it on input acceptance. The rasterizer and interpolator
must advance pixels only on this same acceptance. The new-line event is
separate: consume ``new_line_o`` once to initialize interpolation while
pixel acceptance is disabled.

The :doc:`pixel_raster_pipeline` wrapper supplies queued first/lookahead
descriptors from the rasterizer's span mode, retains their Y coordinates,
and advances interpolation only on fragment acceptance. The standalone
tests still drive the span producer and pixel consumer directly.

Verification
------------

Run ``make -C tb/re/z_test lint test``. The default parameter matrix is
16, 17, 24 and 32 depth bits. The memory test checks byte masks, wide and
scalar access, both bank selections, simultaneous front/back traffic,
viewport limits and retained data across reset. The wrapper test models DDR
with independently randomized command readiness and completion latency.
Its reference depth array is updated from accepted input pixels, independently
of the RTL's bank states and DDR write data.

Directed cases cover all comparisons, disabled tests/writes, a final-pixel
write, single-pixel spans, full-width spans, partial bursts, repeated pixel
addresses, downstream stalls, and successive triangles touching the same
rows. Random cases vary span widths, positions and both viewport modes. Coverage
checks require DDR reads and writes to overlap pixel acceptance.

CLEAR_Z service
---------------

``z_tester`` also accepts ``clear_valid_i && clear_ready_o`` with depth,
base address and ``viewport_size_i``. The mode determines the complete
surface size and slot layout.
The caller validates the complete allocation before requesting clear and
holds the configuration until clear_done_o. Clear and normal scanline jobs
are exclusive; wait for readiness before starting either one.

``z_clear.sv`` captures a job and writes consecutive 16-byte words with
mask ``16'hffff``. It uses one address register and one remaining-word
counter, with no row counters or padding masks. For 16-bit slots the
word counts are 38400 (VGA) and 9600 (QVGA); 32-bit slots double these
counts. Data, address and count registers need no reset because job
acceptance initializes them before any request. Clear ignores depth
test/write enables. It issues no reads. Its writes use the
same DDR port and complete only after the final write response. The scanline
controller is reset while clear is active so old bank state cannot be reused.
The RE uses 16-bit unsigned Q0.16 depth; the generic unit also supports the
existing 32-bit slots for Z_WIDTH greater than 16.

The dedicated ``z_clear_tb`` checks both full surfaces for every tested
Z width, with randomized request stalls and response latency. It verifies
linear addresses, full masks, zero padding inside depth slots, captured
job inputs, reset cancellation and completion after the last response.
