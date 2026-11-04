`ifndef RE_COMMANDS_PKG_SV
    `define RE_COMMANDS_PKG_SV

package re_commands_pkg;

    /* Every command occupies one 32-bit word: opcode [31:28], payload [27:0].
     * Command buffer BASE/END are 4-byte aligned; END is exclusive.
     * Unlisted opcodes and nonzero unused payload bits are command errors. */
    typedef enum logic [3:0] {
        RE_CMD_LOAD_TEXTURE = 4'h1,
        RE_CMD_DRAW         = 4'h2,
        RE_CMD_NOTIFY       = 4'h3,
        RE_CMD_CLEAR_Z      = 4'h4
    } re_opcode_t;

    typedef struct packed {
        re_opcode_t opcode;

        union packed {
            logic [27:0] raw;
            
            /* For LOAD_TEXTURE */
            logic [27:0] address_upper;

            /* For DRAW */
            logic [27:0] primitive_count;

            /* For NOTIFY: ID fits RE_STATUS[31:6]. */
            struct packed {
                logic [1:0] unused;
                logic [25:0] id;
            } notify;

            /* For CLEAR_Z */
            struct packed {
                logic [11:0] unused;
                logic [15:0] depth;
            } clear_z;
        } payload;
    } re_command_t;

    /* LOAD_TEXTURE: reconstruct the unsigned byte address as
     * {payload.address_upper, 4'b0000}; all 32 address bits remain representable
     * for 16-byte-aligned sources. Load N*N RGBA4444 texels from compact
     * rows, with N selected by RE_TEX_CFG. The loader maps these rows to
     * the texture RAM's fixed 64-texel stride. Wait for previous rendering
     * before overwriting RAM and finish loading before the next command. */

    /* DRAW: payload.primitive_count is unsigned; zero is a no-op. Consume successive
     * 64-byte records from RE_PRIM_PTR, including discarded triangles.
     * Check the complete range against RE_PRIM_END without address overflow
     * before issuing work. Complete rendering before the next command. */
     
    /* NOTIFY carries payload.notify.id; payload.notify.unused must be zero.
     * Drain prior work, latch the ID into RE_STATUS[31:6] and halt.
     * The ID persists until the next NOTIFY, hardware reset or soft reset;
     * START, STOP, natural list completion and IRQ acknowledgement preserve it.
     * If commands remain, signal PAUSED and resume at the next command on
     * START, preserving the primitive pointer. At END, signal DONE instead.
     * Events latch in IRQ_PEND; IRQ_EN controls delivery to the CPU.
     * The integrated controller also waits for framebuffer writer completion. */

    /* CLEAR_Z: payload.clear_z.depth is unsigned Q0.16 in [15:0];
     * payload.clear_z.unused occupies [27:16] and must be zero.
     * Fill viewport_width samples on each of viewport_height rows using
     * RE_ZBUF_BASE and the derived pitch; leave row padding untouched.
     * Ignore scissor and Z test/write enables. Validate configuration and
     * bounds against RE_ZBUF_END before writing, detecting address overflow.
     * Drain prior work and await all write responses before continuing. */
     
endpackage : re_commands_pkg

import re_commands_pkg::*;

`endif
