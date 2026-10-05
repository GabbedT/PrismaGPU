`ifndef GE_REGISTERS_PKG
    `define GE_REGISTERS_PKG

package ge_registers_pkg;
    
    typedef enum logic { CW, CCW } front_face_t;

    typedef enum logic [1:0] { NONE, FRONT, BACK } cull_mode_t;

endpackage : ge_registers_pkg

import ge_registers_pkg::*;

`endif