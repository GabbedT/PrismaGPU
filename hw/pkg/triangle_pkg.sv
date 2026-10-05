`ifndef TRIANGLE_PKG
    `define TRIANGLE_PKG

package triangle_pkg;

    /* Positive 1/w = (Q1.24 mantissa) * 2^exponent; 31 packed bits. */
    typedef struct packed {
        logic [24:0] mantissa;
        logic signed [5:0] exponent;
    } inv_w_t;
    
    /* Q16.16 Coordinates */
    typedef struct packed {
        logic [31:0] x;
        logic [31:0] y;
        logic [31:0] z;
        logic [31:0] w;
    } position_t;

    /* Q16.8 coordinates and normalized reciprocal W. */
    typedef struct packed {
        logic [23:0] x;
        logic [23:0] y;
        logic [23:0] z;
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
        proc_vertex_t [2:0] vtx;
    } proc_triangle_t;

endpackage : triangle_pkg

import triangle_pkg::*;

`endif
