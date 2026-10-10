`ifndef GE_REGISTERS_PKG
    `define GE_REGISTERS_PKG

package ge_registers_pkg;
    
    typedef enum logic { CW, CCW } front_face_t;

    typedef enum logic [1:0] { NONE, FRONT, BACK } cull_mode_t;

    /* One-hot pipeline error code; clipping has priority. */
    typedef enum logic [1:0] {
        TRIANGLE_NO_ERROR          = 2'b00,
        TRIANGLE_CLIP_ERROR        = 2'b01,
        TRIANGLE_PERSPECTIVE_ERROR = 2'b10
    } triangle_error_t;

    /* Word addresses; byte offset = register address << 2. */
    typedef enum logic [5:0] {
        GE_CTRL          = 6'h00, /* 0x00 */
        GE_STATUS        = 6'h01, /* 0x04 */

        /* Vertex Buffer */
        GE_VTX_BASE      = 6'h02, /* 0x08 */
        GE_VTX_END       = 6'h03, /* 0x0C */

        /* Primitive Buffer */
        GE_PRIM_BASE     = 6'h04, /* 0x10 */
        GE_PRIM_END      = 6'h05, /* 0x14 */

        /* Interrupt */
        GE_IRQ_EN        = 6'h06, /* 0x18 */
        GE_IRQ_PEND      = 6'h07, /* 0x1C */

        /* Matrix Result in forward mode */
        GE_MTX_RES_0     = 6'h08, /* 0x20 */
        GE_MTX_RES_1     = 6'h09, /* 0x24 */
        GE_MTX_RES_2     = 6'h0A, /* 0x28 */
        GE_MTX_RES_3     = 6'h0B, /* 0x2C */

        /* Matrix Coefficients */
        GE_MTX_00        = 6'h0C, /* 0x30 */
        GE_MTX_01        = 6'h0D, /* 0x34 */
        GE_MTX_02        = 6'h0E, /* 0x38 */
        GE_MTX_03        = 6'h0F, /* 0x3C */
        GE_MTX_10        = 6'h10, /* 0x40 */
        GE_MTX_11        = 6'h11, /* 0x44 */
        GE_MTX_12        = 6'h12, /* 0x48 */
        GE_MTX_13        = 6'h13, /* 0x4C */
        GE_MTX_20        = 6'h14, /* 0x50 */
        GE_MTX_21        = 6'h15, /* 0x54 */
        GE_MTX_22        = 6'h16, /* 0x58 */
        GE_MTX_23        = 6'h17, /* 0x5C */
        GE_MTX_30        = 6'h18, /* 0x60 */
        GE_MTX_31        = 6'h19, /* 0x64 */
        GE_MTX_32        = 6'h1A, /* 0x68 */
        GE_MTX_33        = 6'h1B, /* 0x6C */

        /* Viewport */
        GE_VP_WIDTH      = 6'h1C, /* 0x70 */
        GE_VP_HEIGHT     = 6'h1D, /* 0x74 */

        /* 0x78 and 0x7C are reserved. */

        /* Performance */
        GE_TRI_INPUT     = 6'h20, /* 0x80 */
        GE_TRI_OUTPUT    = 6'h21, /* 0x84 */
        GE_TRI_DISCARDED = 6'h22, /* 0x88 */
        GE_STALL         = 6'h23  /* 0x8C */
    } ge_registers_t;


    /* GE_CTRL[9:0]; bits [31:10] are reserved and read as zero. */
    typedef struct packed {
        logic raster_forward;              /* [9]: bypass packer, send triangles to raster */
        logic enable_pcounters;            /* [8] */
        logic matrix_forward;              /* [7] */
        cull_mode_t cull_mode;             /* [6:5]: NONE, FRONT, BACK */
        front_face_t front_face;           /* [4]: CW, CCW */
        logic soft_reset;                  /* [3]: write-one pulse, reads zero */
        logic stop_processing;             /* [2]: write-one pulse, reads zero */
        logic start_processing;            /* [1]: write-one pulse, reads zero */
        logic enable;                      /* [0] */
    } ge_control_t;


    /* GE_STATUS[4:0]; GE_IRQ_EN/PEND use the same bit positions. */
    typedef struct packed {
        triangle_error_t errors; /* [4:3]: one-hot pipeline error code */
        logic stall;             /* [2]: pipeline stalled */
        logic done;              /* [1]: vertex fetch finished */
        logic busy;              /* [0]: pipeline not empty */
    } ge_status_t;

endpackage : ge_registers_pkg

import ge_registers_pkg::*;

`endif
