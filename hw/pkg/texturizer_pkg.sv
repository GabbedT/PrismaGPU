`ifndef TEXTURIZER_PKG_SV
    `define TEXTURIZER_PKG_SV

package texturizer_pkg;

    localparam int TEXTURE_RECIPROCAL_WIDTH = 18;

    /* Leading-one, normalization, LUT, two multiply and two round stages. */
    localparam int TEXTURE_COORDINATE_LATENCY = 2 + 1 + 2 + 2;
    localparam int TEXTURE_MEMORY_LATENCY = 2;
    localparam int TEXTURIZER_LATENCY = TEXTURE_COORDINATE_LATENCY + 1 + TEXTURE_MEMORY_LATENCY;

    typedef enum logic [1:0] {
        TEXTURE_SIZE_8 = 2'b00,
        TEXTURE_SIZE_16 = 2'b01,
        TEXTURE_SIZE_32 = 2'b10,
        TEXTURE_SIZE_64 = 2'b11
    } texture_size_t;

endpackage : texturizer_pkg

import texturizer_pkg::*;

`endif
