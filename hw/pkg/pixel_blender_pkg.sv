`ifndef PIXEL_BLENDER_PKG_SV
    `define PIXEL_BLENDER_PKG_SV

package pixel_blender_pkg;

    localparam int PIXEL_BLENDER_LATENCY = 4;

    /* Bit-compatible with ZenithSoC vga_pkg::pixel_t: R[11:8], G[7:4], B[3:0]. */
    typedef struct packed {
        logic [3:0] red;
        logic [3:0] green;
        logic [3:0] blue;
    } pixel_t;

endpackage : pixel_blender_pkg

`endif
