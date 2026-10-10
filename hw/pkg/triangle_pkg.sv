`ifndef TRIANGLE_PKG
    `define TRIANGLE_PKG

package triangle_pkg;

    /* Positive 1/w = (Q1.17 mantissa) * 2^exponent; 24 packed bits. */
    typedef struct packed {
        logic [17:0] mantissa;
        logic signed [5:0] exponent;
    } inv_w_t;
    
    /* Q16.16 Coordinates */
    typedef struct packed {
        logic [31:0] x;
        logic [31:0] y;
        logic [31:0] z;
        logic [31:0] w;
    } position_t;

    /* Signed screen XY with eight fractional bits; unsigned Z with sixteen. */
    typedef struct packed {
        logic signed [18:0] x;
        logic signed [17:0] y;
        logic [16:0] z;
        inv_w_t      w;
    } screen_pos_t;

    typedef struct packed {
        logic [31:0] u;
        logic [31:0] v;
    } tex_coord_t;

    typedef struct packed {
        logic [3:0] r;
        logic [3:0] g;
        logic [3:0] b;
        logic [3:0] a;
    } color_t;

    /* Wire input: 170 bits per vertex, 510 bits plus two padding bits per triangle.
     * All position/texture fields retain sixteen fractional bits. */
    typedef struct packed {
        logic signed [24:0] x, y, z, w;
    } input_position_t;

    typedef struct packed {
        logic signed [26:0] u, v;
    } input_tex_coord_t;

    typedef struct packed {
        input_position_t pos;
        input_tex_coord_t tex;
        color_t col;
    } input_vertex_t;

    typedef struct packed {
        position_t  pos;
        tex_coord_t tex;
        color_t     col;
    } vertex_t;

    /* Post process vertex */
    typedef struct packed {
        screen_pos_t pos;
        tex_coord_t  tex;
        color_t      col;
    } proc_vertex_t;

    typedef struct packed {
        vertex_t [2:0] vtx;
    } triangle_t;

    /* Post process triangle */
    typedef struct packed {
        /* Twice signed screen area, with 16 fractional bits; set by culling. */
        logic signed [37:0] area;
        proc_vertex_t [2:0] vtx;
    } proc_triangle_t;

endpackage : triangle_pkg

import triangle_pkg::*;

`endif
