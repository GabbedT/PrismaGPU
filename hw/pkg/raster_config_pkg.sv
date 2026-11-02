`ifndef RASTER_CONFIG_PKG_SV
    `define RASTER_CONFIG_PKG_SV

package raster_config_pkg;

    /* Driven by external configuration registers. Hold from triangle acceptance
     * through done_o, including stalls and the final depth write response. */
    typedef struct packed {
        logic gouraud_shading;
        logic texture_en;
        logic perspective_correct;
        logic z_interpolation;
        logic [9:0] viewport_width;
        logic [8:0] viewport_height;
        logic scissor_enable;
        logic [9:0] scissor_xmin;
        logic [9:0] scissor_xmax;
        logic [8:0] scissor_ymin;
        logic [8:0] scissor_ymax;
        texture_size_t texture_size;
        logic z_test_enable;
        logic z_write_enable;
        logic [2:0] z_compare;
        logic [31:0] z_buffer_address;
        logic [15:0] z_buffer_pitch;
    } raster_config_t;

endpackage : raster_config_pkg

import raster_config_pkg::*;

`endif
