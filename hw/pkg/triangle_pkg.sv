`ifndef TRIANGLE_PKG
    `define TRIANGLE_PKG

package triangle_pkg;
    
    /* Q16.16 Coordinates */
    typedef struct packed {
        logic [31:0] x;
        logic [31:0] y;
        logic [31:0] z;
        logic [31:0] w;
    } position_t;

    /* Q16.8 Coordinates */
    typedef struct packed {
        logic [23:0] x;
        logic [23:0] y;
        logic [23:0] z;
        logic [23:0] w;
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

`endif