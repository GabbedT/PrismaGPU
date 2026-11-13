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

    /* Evaluate after interpolation: signed F12 -> unsigned F12 in [0,15].
     * This is saturation only; all twelve fractional bits remain unchanged. */
    function automatic logic [15:0] clamp_fragment_color(input logic signed [35:0] value);
        if (value <= 0) return 16'd0;
        if (value >= 36'sd61440) return 16'd61440;
        return value[15:0];
    endfunction

endpackage : pixel_blender_pkg

import pixel_blender_pkg::*;

`endif
