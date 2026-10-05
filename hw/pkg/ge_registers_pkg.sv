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

endpackage : ge_registers_pkg

import ge_registers_pkg::*;

`endif
