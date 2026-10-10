`ifndef PERSPECTIVE_DIVIDER_SV
    `define PERSPECTIVE_DIVIDER_SV

module perspective_divider (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    input vertex_t vertex_i,
    input logic valid_i,

    output vertex_t vertex_o,
    output logic error_o,
    output logic valid_o,
    output logic busy_o
);

//====================================================================================
//      INPUT REGISTER
//====================================================================================

    vertex_t vertex_CRT;
    logic reciprocal_error, reciprocal_error_ff, reciprocal_valid;

        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                vertex_CRT <= vertex_i;
            end
        end

    /* Preserve every vertex token, including failed perspective divisions. */
        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                reciprocal_error_ff <= 1'b0;
            end else if (!stall_i) begin
                reciprocal_error_ff <= valid_i & reciprocal_error;
            end
        end


//====================================================================================
//      RECIPROCAL W COORDINATE
//====================================================================================

    logic [17:0] reciprocal; logic signed [5:0] exponent;
    inv_w_t inv_w;

    assign inv_w.mantissa = reciprocal;
    assign inv_w.exponent = -exponent;

    reciprocal_divider divider (
        .clk_i        ( clk_i            ),
        .rst_n_i      ( rst_n_i          ),
        .stall_i      ( stall_i          ),

        .divisor_i    ( vertex_i.pos.w   ),
        .valid_i      ( valid_i          ),

        .error_o      ( reciprocal_error ),
        .valid_o      ( reciprocal_valid ),
        .reciprocal_o ( reciprocal       ),
        .exponent_o   ( exponent         )
    );


//====================================================================================
//      PERSPECTIVE PRODUCTS
//====================================================================================

    inv_w_t inv_w_input_ff, inv_w_ff;
    color_t color_input_ff, color_ff;
    logic product_valid_ff, product_error_ff;

    perspective_product product_x (
        .clk_i        ( clk_i            ),
        .stall_i      ( stall_i          ),
        .value_i      ( vertex_CRT.pos.x ),
        .reciprocal_i ( reciprocal       ),
        .exponent_i   ( exponent         ),
        .value_o      ( vertex_o.pos.x   )
    );

    perspective_product product_y (
        .clk_i        ( clk_i            ),
        .stall_i      ( stall_i          ),
        .value_i      ( vertex_CRT.pos.y ),
        .reciprocal_i ( reciprocal       ),
        .exponent_i   ( exponent         ),
        .value_o      ( vertex_o.pos.y   )
    );

    perspective_product product_z (
        .clk_i        ( clk_i            ),
        .stall_i      ( stall_i          ),
        .value_i      ( vertex_CRT.pos.z ),
        .reciprocal_i ( reciprocal       ),
        .exponent_i   ( exponent         ),
        .value_o      ( vertex_o.pos.z   )
    );

    perspective_product product_u (
        .clk_i        ( clk_i            ),
        .stall_i      ( stall_i          ),
        .value_i      ( vertex_CRT.tex.u ),
        .reciprocal_i ( reciprocal       ),
        .exponent_i   ( exponent         ),
        .value_o      ( vertex_o.tex.u   )
    );

    perspective_product product_v (
        .clk_i        ( clk_i            ),
        .stall_i      ( stall_i          ),
        .value_i      ( vertex_CRT.tex.v ),
        .reciprocal_i ( reciprocal       ),
        .exponent_i   ( exponent         ),
        .value_o      ( vertex_o.tex.v   )
    );

    /* Align reciprocal, color and control with the input and product registers. */
        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                inv_w_input_ff <= inv_w;
                color_input_ff <= vertex_CRT.col;
                inv_w_ff <= inv_w_input_ff;
                color_ff <= color_input_ff;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                product_valid_ff <= 1'b0;
                product_error_ff <= 1'b0;
                valid_o <= 1'b0;
                error_o <= 1'b0;
            end else if (!stall_i) begin
                product_valid_ff <= reciprocal_valid;
                product_error_ff <= reciprocal_error_ff;
                valid_o <= product_valid_ff;
                error_o <= product_error_ff;
            end
        end

    /* Pack inv_w_t in bits [23:0]; upper eight bits are padding. */
    assign vertex_o.pos.w = {8'b0, inv_w_ff};
    assign vertex_o.col = color_ff;

    assign busy_o = reciprocal_valid | product_valid_ff | valid_o;

endmodule : perspective_divider

`endif
