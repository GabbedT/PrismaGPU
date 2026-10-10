`ifndef MATRIX_ENGINE_SV
    `define MATRIX_ENGINE_SV

module matrix_engine (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Vertex to process */
    input input_vertex_t vertex_i,
    input logic valid_i,

    /* Matrix coefficients */
    input logic [3:0][3:0][31:0] coefficient_i,

    /* Processed vertex */
    output vertex_t vertex_o,
    output logic valid_o,
    output logic busy_o
);

    logic [3:0][24:0] vertex_position;
    logic [3:0][31:0] processed_element;
    tex_coord_t texture_product_ff, texture_ff;
    color_t color_product_ff, color_ff;
    logic valid_product_ff;

    /* Align attributes and valid with the products, then the partial sums. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            texture_product_ff.u <= 32'($signed(vertex_i.tex.u));
            texture_product_ff.v <= 32'($signed(vertex_i.tex.v));
            color_product_ff <= vertex_i.col;
            texture_ff <= texture_product_ff;
            color_ff <= color_product_ff;
        end

        if (!rst_n_i) begin
            valid_product_ff <= 1'b0;
            valid_o <= 1'b0;
        end else if (!stall_i) begin
            valid_product_ff <= valid_i;
            valid_o <= valid_product_ff;
        end
    end

    assign busy_o = valid_product_ff | valid_o;

    /* Explicit indices preserve the packed vertex layout. */
    assign vertex_position[0] = vertex_i.pos.x;
    assign vertex_position[1] = vertex_i.pos.y;
    assign vertex_position[2] = vertex_i.pos.z;
    assign vertex_position[3] = vertex_i.pos.w;

    genvar i;

    generate
        for (i = 0; i < 4; ++i) begin
            line_multiplier matrix_line (
                .clk_i         ( clk_i                ),
                .stall_i       ( stall_i              ),
                .vector_i      ( vertex_position      ),
                .coefficient_i ( coefficient_i[i]     ),
                .element_o     ( processed_element[i] )
            );
        end
    endgenerate


        always_comb begin
            vertex_o.tex = texture_ff;
            vertex_o.col = color_ff;

            vertex_o.pos.x = processed_element[0];
            vertex_o.pos.y = processed_element[1];
            vertex_o.pos.z = processed_element[2];
            vertex_o.pos.w = processed_element[3];
        end

endmodule

`endif
