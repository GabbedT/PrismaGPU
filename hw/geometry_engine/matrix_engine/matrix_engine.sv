`ifndef MATRIX_ENGINE_SV
    `define MATRIX_ENGINE_SV

import triangle_pkg::*;

module matrix_engine (
    /* Vertex to process */
    input vertex_t vertex_i,

    /* Matrix coefficients */
    input logic [3:0][3:0][31:0] coefficient_i,

    /* Processed vertex */
    output vertex_t vertex_o
);

    logic [3:0][31:0] processed_element;

    genvar i;

    generate
        for (i = 0; i < 4; ++i) begin
            line_multiplier matrix_line (
                .vector_i      ( vertex_i.pos         ),
                .coefficient_i ( coefficient_i[i]     ),
                .element_o     ( processed_element[i] )
            );
        end
    endgenerate


        always_comb begin
            vertex_o = vertex_i;

            vertex_o.pos.x = processed_element[0];
            vertex_o.pos.y = processed_element[1];
            vertex_o.pos.z = processed_element[2];
            vertex_o.pos.w = processed_element[3];
        end

endmodule

`endif