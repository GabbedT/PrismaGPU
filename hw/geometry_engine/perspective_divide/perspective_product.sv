`ifndef PERSPECTIVE_PRODUCT_SV
    `define PERSPECTIVE_PRODUCT_SV

module perspective_product (
    input logic clk_i,
    input logic stall_i,

    input logic [31:0] value_i,
    input logic [17:0] reciprocal_i,
    input logic signed [5:0] exponent_i,

    output logic [31:0] value_o
);

//====================================================================================
//      INPUT REGISTER
//====================================================================================

    logic signed [31:0] value_ff;
    logic signed [18:0] reciprocal_ff;
    logic [5:0] shift_amount_ff;

        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                value_ff <= value_i;
                reciprocal_ff <= {1'b0, reciprocal_i};
                shift_amount_ff <= 6'sd17 + exponent_i;
            end
        end


//====================================================================================
//      PERSPECTIVE PRODUCT
//====================================================================================

    logic signed [50:0] product, product_ff;
    logic [5:0] product_shift_amount_ff;

    assign product = value_ff * reciprocal_ff;

        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                product_ff <= product;
                product_shift_amount_ff <= shift_amount_ff;
            end
        end

    /* Apply the mantissa reciprocal and exponent; return signed Q16.16. */
    assign value_o = 32'(product_ff >>> product_shift_amount_ff);

endmodule : perspective_product

`endif
