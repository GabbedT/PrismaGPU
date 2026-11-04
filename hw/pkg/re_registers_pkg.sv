`ifndef RE_REGISTERS_PKG
    `define RE_REGISTERS_PKG

package re_registers_pkg;

    typedef enum logic {
        RE_VIEWPORT_640_480 = 1'b0,
        RE_VIEWPORT_320_240 = 1'b1
    } re_viewport_size_t;

    /* Matches the unsigned comparison encoding used by depth_tester. */
    typedef enum logic [2:0] {
        RE_Z_NEVER    = 3'd0,
        RE_Z_LESS     = 3'd1,
        RE_Z_EQUAL    = 3'd2,
        RE_Z_LEQUAL   = 3'd3,
        RE_Z_GREATER  = 3'd4,
        RE_Z_NOTEQUAL = 3'd5,
        RE_Z_GEQUAL   = 3'd6,
        RE_Z_ALWAYS   = 3'd7
    } re_z_compare_t;

    /* Word addresses; byte offset = register address << 2.
     * All registers are 32 bits wide. Unlisted addresses are invalid. */
    typedef enum logic [5:0] {
        RE_CTRL           = 6'h00, /* 0x00: RW / pulse */
        RE_STATUS         = 6'h01, /* 0x04: RO */

        /* Command Buffer */
        RE_CMD_BASE       = 6'h02, /* 0x08: RW */
        RE_CMD_END        = 6'h03, /* 0x0C: RW */

        /* Primitive Buffer */
        RE_PRIM_BASE      = 6'h04, /* 0x10: RW */
        RE_PRIM_END       = 6'h05, /* 0x14: RW */

        /* Interrupt */
        RE_IRQ_EN         = 6'h06, /* 0x18: RW */
        RE_IRQ_PEND       = 6'h07, /* 0x1C: RW1C */

        /* Z Buffer */
        RE_ZBUF_BASE      = 6'h08, /* 0x20: RW */
        RE_ZBUF_END       = 6'h09, /* 0x24: RW */

        /* Rendering Configuration */
        RE_DRAW_CFG       = 6'h0A, /* 0x28: RW */
        RE_Z_CFG          = 6'h0B, /* 0x2C: RW */
        RE_TEX_CFG        = 6'h0C, /* 0x30: RW */

        /* Viewport and Scissor */
        RE_VP_CFG         = 6'h0D, /* 0x34: RW */
        RE_SCISSOR_X      = 6'h0F, /* 0x3C: RW */
        RE_SCISSOR_Y      = 6'h10, /* 0x40: RW */

        /* Execution Pointers */
        RE_CMD_PTR        = 6'h11, /* 0x44: RO */
        RE_PRIM_PTR       = 6'h12, /* 0x48: RO */

        /* Packed RGB444 Framebuffer */
        RE_FRMBUF_BEGIN   = 6'h13, /* 0x4C: RW */
        RE_FRMBUF_END     = 6'h14, /* 0x50: RW */

        /* Performance */
        RE_TRI_INPUT      = 6'h20, /* 0x80: RO */
        RE_TRI_DONE       = 6'h21, /* 0x84: RO */
        RE_TRI_DISCARDED  = 6'h22, /* 0x88: RO */
        RE_STALL          = 6'h23, /* 0x8C: RO */
        RE_PIXEL_OUTPUT   = 6'h24, /* 0x90: RO */
        RE_PIXEL_Z_REJECT = 6'h25, /* 0x94: RO */
        RE_CYCLES         = 6'h26  /* 0x98: RO */
    } re_registers_t;


    /* RE_CTRL[8:0]; unused bits read as zero and ignore writes.
     * Command bits are write-one pulses and read as zero.
     * STOP completes the current command before pausing; START resumes it
     * at the next command, or starts a new list at RE_CMD_BASE.
     * Clearing enable prevents new work but allows in-flight work to drain. */
    typedef struct packed {
        logic enable_pcounters;   /* [8] */
        logic [3:0] reserved;     /* [7:4] */
        logic soft_reset;         /* [3] */
        logic stop_processing;    /* [2] */
        logic start_processing;   /* [1] */
        logic enable;             /* [0] */
    } re_control_t;


    /* RE_STATUS[31:0]; unlike GE, IRQ fields have their own layout.
     * NOTIFY_ID latches on NOTIFY completion, independently of IRQ_EN.
     * Hardware and soft reset clear it; other control/IRQ operations preserve it.
     * DONE is list completion, not the per-triangle pipeline done pulse.
     * It requires completed depth writes and framebuffer writer completion. */
    typedef struct packed {
        logic [25:0] notify_id; /* [31:6]: ID of the last completed NOTIFY */
        logic error;          /* [5]: OR of pending error IRQs, independent of mask */
        logic cmd_exhausted;  /* [4]: all list commands executed/issued */
        logic paused;         /* [3]: STOP or NOTIFY reached, prior work completed */
        logic stall;          /* [2]: waiting for memory or pixel consumer */
        logic done;           /* [1]: list and all in-flight work completed */
        logic busy;           /* [0]: list running or work still in flight */
    } re_status_t;


    /* RE_IRQ_EN/PEND[5:0]. Independent events, not a one-hot error code.
     * PEND latches events even when masked; write one to clear each bit.
     * A simultaneous new event takes priority over clearing that bit.
     * Empty/degenerate triangles are normal discards, not error events. */
    typedef struct packed {
        logic math_error;     /* [5]: setup arithmetic failure */
        logic address_error;  /* [4]: alignment, bounds, overflow or DDR access failure */
        logic config_error;   /* [3]: invalid rendering configuration */
        logic command_error;  /* [2]: invalid command encoding or payload */
        logic paused;         /* [1]: entered paused state */
        logic done;           /* [0]: completed command list */
    } re_irq_t;


    /* RE_DRAW_CFG[4:0]. Hold rendering configuration stable from triangle
     * acceptance through completion, including stalls and depth writeback.
     * Texture sampling requires perspective_correct=1. */
    typedef struct packed {
        logic scissor_enable;      /* [4] */
        logic z_interpolation;     /* [3]: zero selects vertex zero's depth */
        logic perspective_correct; /* [2] */
        logic texture_en;          /* [1] */
        logic gouraud_shading;     /* [0]: zero selects flat shading */
    } re_draw_config_t;


    /* RE_Z_CFG[4:0]. Disabling the test also suppresses depth writes.
     * Use an enabled ALWAYS test for unconditional depth writes. */
    typedef struct packed {
        re_z_compare_t z_compare;  /* [4:2] */
        logic z_write_enable;      /* [1] */
        logic z_test_enable;       /* [0] */
    } re_z_config_t;


    /* RE_TEX_CFG[1:0]; reuse the texturizer's 8/16/32/64 encoding.
     * Texture RAM retains its fixed physical stride of 64 texels. */
    typedef struct packed {
        texture_size_t texture_size; /* [1:0] */
    } re_texture_config_t;


    /* RE_VP_CFG[0]: zero selects 640x480, one selects 320x240.
     * Hardware reset selects 640x480; soft reset preserves the mode. */
    typedef struct packed {
        re_viewport_size_t viewport_size;
    } re_viewport_config_t;


    /* RE_SCISSOR_X[25:0] and RE_SCISSOR_Y[24:0]. Unsigned integer pixel
     * coordinates, both bounds inclusive; unused bits read as zero. */
    typedef struct packed {
        logic [9:0] xmax;      /* [25:16] */
        logic [5:0] reserved;  /* [15:10] */
        logic [9:0] xmin;      /* [9:0] */
    } re_scissor_x_t;

    typedef struct packed {
        logic [8:0] ymax;      /* [24:16] */
        logic [6:0] reserved;  /* [15:9] */
        logic [8:0] ymin;      /* [8:0] */
    } re_scissor_y_t;

endpackage : re_registers_pkg

import re_registers_pkg::*;

`endif
