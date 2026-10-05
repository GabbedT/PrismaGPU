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
    output logic valid_o
);

//====================================================================================
//      FUNCTIONS
//====================================================================================

    /* Apply the mantissa reciprocal and exponent; return signed Q16.16. */
    function automatic logic [31:0] perspective_product (
        input logic [31:0] value_i,
        input logic [24:0] reciprocal_i,
        input logic signed [5:0] exponent_i
    );
        logic signed [32:0] value;
        logic signed [25:0] reciprocal_value;
        logic signed [58:0] product;
        logic [5:0] shift_amount;

        value = {value_i[31], value_i};
        reciprocal_value = {1'b0, reciprocal_i};
        product = value * reciprocal_value;
        shift_amount = 6'sd24 + exponent_i;

        perspective_product = product >>> shift_amount;
    endfunction


//====================================================================================
//      INPUT REGISTER
//====================================================================================

    vertex_t vertex_CRT;

        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                vertex_CRT <= vertex_i;
            end
        end


//====================================================================================
//      RECIPROCAL W COORDINATE
//====================================================================================

    logic [24:0] reciprocal; logic signed [5:0] exponent;

    reciprocal_divider divider (
        .clk_i        ( clk_i   ),
        .rst_n_i      ( rst_n_i ),
        .stall_i      ( stall_i ),

        .divisor_i    ( vertex_i.pos.w ),
        .valid_i      ( valid_i        ),

        .error_o      ( error_o    ),
        .valid_o      ( valid_o    ),
        .reciprocal_o ( reciprocal ),
        .exponent_o   ( exponent   )
    );


//====================================================================================
//      PERSPECTIVE PRODUCTS
//====================================================================================

        always_comb begin
            vertex_o = vertex_CRT;

            vertex_o.pos.w = reciprocal;
            vertex_o.pos.x = perspective_product(vertex_CRT.pos.x, reciprocal, exponent);
            vertex_o.pos.y = perspective_product(vertex_CRT.pos.y, reciprocal, exponent);
            vertex_o.pos.z = perspective_product(vertex_CRT.pos.z, reciprocal, exponent);
            vertex_o.tex.u = perspective_product(vertex_CRT.tex.u, reciprocal, exponent);
            vertex_o.tex.v = perspective_product(vertex_CRT.tex.v, reciprocal, exponent);
        end

endmodule : perspective_divider

`endif
