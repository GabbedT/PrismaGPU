Command processor and memory unit
=================================

``hw/raster_engine/raster_engine.sv`` is the integrated Raster Engine. It
connects the register bank, command processor, memory unit and pixel pipeline.
The controller executes :doc:`commands` in order and exposes :doc:`registers`.

``hw/raster_engine/command_processor/`` contains:

* ``command_processor.sv``: execution, validation, retirement and barriers.

``hw/raster_engine/memory_unit/`` contains:

* ``memory_unit.sv``: command/primitive/texture fetch, Z routing and clients;
* ``memory_arbiter.sv``: a round-robin arbiter with one reserved transaction;
* ``framebuffer_access.sv``: packed RGB444 writes and destination-pixel reads.

The command processor and memory unit are separate instances in
``raster_engine.sv``. Explicit ports carry command fetch/commit, DRAW and texture
requests, primitive handshakes, flush/abort controls and memory status. Execution
pointers originate in the memory unit and feed both the registers and parser.
Primitive data, texture RAM writes, Z accesses and pixels connect directly
between the memory unit and pixel pipeline. The DDR channels terminate at the
memory unit.

The processor keeps state transitions and state-dependent outputs in one
combinational block. Control and error registers reset; command payload,
remaining primitive count and saved ranges are loaded before use and have no
reset. Payload outputs are zero outside their request states. The testbench
uses ``command_processor.vlt`` to schedule the fetch handshake independently
in Verilator without changing the RTL FSM structure.

Commands transfer on ``command_valid_i && command_ready_o``; retirement is a
separate ``command_commit_o`` pulse. DRAW and texture requests are one-cycle
pulses with their payload valid in the same cycle. Primitive data remains in
the memory unit until ``primitive_valid_i && primitive_ready_o``. The parser
gates pipeline valid and memory ready together, so stalls cannot consume a
primitive early. Flush completion uses ``framebuffer_idle_i``; execution barriers
and abort/reset draining use ``memory_idle_i``.

External DDR contract
---------------------

The GPU owns ``hw/common/gpu_ddr_interface.sv`` and does not import ZenithSoC
sources. Its signals deliberately resemble ``dev2ddr_interface``. The top
exposes two master instances: ``read_ddr`` and ``write_ddr``.

.. list-table:: Signals on each instance
   :header-rows: 1

   * - Signal
     - Direction from GPU
     - Meaning
   * - ``trx_req``, ``ready``
     - out, in
     - Request transfers on their conjunction; hold payload until accepted
   * - ``trx_type``
     - out
     - Fixed zero on read_ddr, fixed one on write_ddr
   * - ``trx_addr[31:0]``
     - out
     - Unsigned byte address, aligned to 16 bytes
   * - ``wdata[127:0]``, ``wstrobe[15:0]``
     - out
     - One bit per byte; one writes the byte, zero preserves it
   * - ``read_valid``, ``read_error``, ``rdata[127:0]``
     - in
     - Read completion, error qualifier and data
   * - ``write_valid``, ``write_error``
     - in
     - Write completion and error qualifier

Read and write can progress independently. Each channel permits one reserved
transaction, including a request held under backpressure. Each accepted
request must receive exactly one completion, no earlier than the next cycle.
There is no response-ready signal: each client reserves space first.
An error qualifies valid; error without valid does not complete a transaction.
Unused response signals on the other channel are ignored.

Write completion must guarantee visibility to reads issued afterward. It must
not merely acknowledge enqueueing write data. Integration with ZenithSoC must
provide this ordering, normalize response/error signals, and explicitly map
32-bit GPU addresses to its 27-bit DDR address space. Do not silently discard
high address bits. Hardware reset requires the external adapter to cancel or
reset old transactions; software reset retains their ownership until drained.

The read arbiter services command, primitive, texture, Z and framebuffer
clients. The write arbiter services Z and framebuffer. Rotation occurs at
client acceptance, with no multi-beat lock. Address, data and owner are held
until completion; delayed responses cannot be redirected to a new client.
The internal ready signal means the arbiter has captured and reserved the
request, not necessarily that the external controller accepted it yet.
External completion data and error are captured atomically, then delivered
to the reserved client during a separate response cycle. The arbiter remains
non-idle through delivery, including while aborting, so barriers still wait
for every response. This adds one clock per DDR transaction and removes raw
DDR completion/error inputs from execution and register-status paths.

Fetch and execution
-------------------

A command read fills a 128-bit shift register. Only in-range 32-bit words
are delivered, low bits first, and the first beat can start in any word lane.
CMD_BASE/END remain four-byte aligned. The surrounding 16-byte-aligned beats
must be readable ordinary memory, even if their unused bytes lie outside the
logical command range. No new command beat is fetched while a command executes.

CMD_PTR remains on the current command until it completes successfully.
At command acceptance, the controller records whether the full 33-bit
``CMD_PTR + 4`` equals ``CMD_END``. While that command is active, this flag
drives ``CMD_EXHAUSTED``; an already empty/retired list uses pointer equality.
The status therefore still marks the last command before retirement, including
long operations and pauses, without putting an increment on the status-read
path. Reset clears command ownership, so it cannot expose a stale last flag.
``make -C tb/verilator test-control`` checks this across command lanes, high
addresses, NOTIFY/resume, empty lists and reset during the final command.

PRIM_PTR advances when a complete 64-byte primitive transfers to the pipeline.
The memory unit assembles four 128-bit words, low bits first, into the GE's
512-bit ``proc_triangle_t``. It can assemble one subsequent primitive while
the current triangle renders, but never beyond the current DRAW count.
The controller checks the complete DRAW range before issuing work.

Textures have 8, 16, 32 or 64 texels per side. The memory unit issues 8, 32,
128 or 512 reads respectively and maps compact source rows to the texture
RAM's fixed 64-texel row stride. Load completion follows the last RAM write.
CLEAR_Z uses ``z_clear.sv`` inside ``z_tester``; see :doc:`z_test`.

Framebuffer and blending service
--------------------------------

The framebuffer resides in external DDR. ``framebuffer_access.sv`` manages
accesses using a write-combining register and a one-beat read cache.

The framebuffer matches ZenithSoC VGA's compact RGB444 stream: R[11:8],
G[7:4], B[3:0], first pixel in the lowest bits. The physical row width equals
the width selected by RE_VP_CFG and rows have no padding. RE_FRMBUF_BEGIN is 16-byte aligned and
RE_FRMBUF_END bounds the allocation. Both modes have whole 16-byte rows:
VGA uses 60 DDR words per row; QVGA uses 30. Address generation computes
``y*30`` with a widened shift/subtract and doubles it for VGA, then adds
``floor(3*x/32)``. The pixel bit offset is ``4*((3*x) mod 32)`` and depends
only on X. Address additions and access-end checks retain the carry bit;
no variable-width multiplication is needed for writes or destination reads.

The writer accumulates data and a 128-bit dirty mask. A pixel can span two
beats. On a beat/row change, full beat or explicit flush it writes enabled
bytes. If a dirty byte contains preserved bits of a neighbouring pixel,
it first reads the old beat and merges only dirty bits. Untouched bytes and
nibbles remain unchanged. The CPU and other masters must not write this
surface concurrently with rendering.

The destination-read service accepts x/y and returns one RGB444 pixel with
valid/ready backpressure. A tagged 128-bit cache serves adjacent hits without
DDR. Split pixels require two beats and a temporary partial-pixel register.
Before a destination read, preceding accepted pixel writes are flushed.
Writes and pause/resume invalidate cached data. The service releases the
writer once the response is buffered, even if its consumer is stalled.

The integrated top connects this service to ``framebuffer_blender`` when
``RE_BLEND_CFG`` enables constant-alpha source-over compositing. One pixel is
held through destination read and final write acceptance. Opaque draws bypass
the stage. Existing texture/vertex color mixing happens before destination
blending; see :doc:`pixel_blender`.

Barriers, IRQ and reset
-----------------------

Within DRAW, primitive delivery follows the pipeline's setup readiness;
``pipeline_busy_i`` does not block the next input. ``remaining_CRT`` counts
primitives still to issue and the two-bit ``pending_CRT`` counts accepted
triangles awaiting completion. At most three are outstanding: one in setup,
one using the raster context, and one finishing its downstream pixels.
Discarded triangles also complete in order and decrement the pending count.

The pipeline releases its raster context after the final fragment and all Z
write responses. The next setup can run before that point, but the next Z
reads cannot observe uncommitted depth values. Pixel payloads remain ordered
through the downstream stages; framebuffer writes can combine pixels from
successive triangles when they belong to the same beat and row.

DRAW_RUN waits for all requested transfers and completions and an idle
pipeline. DRAW_DRAIN then flushes the last partial framebuffer beat and waits
for its write response before COMMIT. There is no per-triangle framebuffer
flush. NOTIFY and natural list completion still wait for all memory work.
Destination reads retain the framebuffer service's flush-before-read rule;
the destination blending stage preserves pixel ordering, and its busy state
participates in drain/flush/reset barriers.

For NOTIFY, the register bank captures the ID on the edge entering PAUSED or
DONE. Those live status flags are exposed after capture, so polling cannot
observe a completed NOTIFY with the previous ID. The bank's existing edge
detector captures the IRQ on the following clock. Masking IRQ does not affect
the pause or the ID. START resumes; acknowledging IRQ alone does not.

STOP or clearing enable finishes the current command, including an entire
DRAW, then pauses. A final command instead reaches DONE. START while busy or
with enable clear has no effect. START from DONE starts a new list; from
PAUSED it resumes saved pointers and invalidates prefetched commands. Rendering
configuration may change while paused. Changing command/primitive BASE/END
before resuming raises a configuration error; use software reset for a new list.

Command/primitive buffer validity, framebuffer/depth surface bounds and the
texture/perspective configuration check are registered before execution
control consumes them. START already enters INITIALIZE for one clock, so
configuration supplied together with START is checked before memory is
initialized, without adding another initialization state. Configuration
remains stable while BUSY; paused reconfiguration is sampled before resume.
The full 33-bit surface limits retain overflow detection.

Unknown opcodes and unused payload bits raise command_error. Invalid rendering
configuration raises config_error; bounds, alignment, overflow and DDR access
failures raise address_error. Arithmetic failures raise math_error. Errors
leave CMD_PTR on the failed command and require software reset before restart.
Accepted pixel writes are flushed for non-memory errors. A memory failure
aborts residual local data; a partially written result is not rolled back.

Software reset invalidates local work, clears pointers/counters and the
bank-owned ID/IRQ state, and resets the pipeline. It does not forget requests
already presented to DDR, even those not yet accepted. BUSY stays asserted
until their responses arrive; read results from the aborted job are discarded.
Only then can another START be accepted. The synchronous datapath reset is
independent of the register bank's optional ASYNC hardware-reset configuration.

Verification
------------

From the repository root:

.. code-block:: console

   make -C tb/verilator test-control
   make -C tb/verilator test

The directed control test changes configuration together with START and
checks both viewport sizes, buffer alignment, empty lists, short ranges,
32-bit overflow, configuration-error priority, and disabled depth checks.
It verifies that invalid Z reads/writes never reach DDR, that their error is
registered, and that cancellation or initialization clears the fault event.
The firmware integration checks textured, depth-tested and blended images,
direct/buffered rendering, slower memory, deterministic replay and watchdog
failure reporting.
