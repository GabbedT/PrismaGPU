`ifndef LINE_MULTIPLIER_SV
    `define LINE_MULTIPLIER_SV

module line_multiplier (
    input logic clk_i,
    input logic stall_i,

    input logic [3:0][24:0] vector_i,
    input logic [3:0][31:0] coefficient_i,

    output logic [31:0] element_o
);

    logic signed [3:0][56:0] products, products_ff;
    logic [3:0][24:0] vector_ff;
    logic [3:0][31:0] coefficient_ff;

    /* Capture both operands together before multiplication. Vivado can use
     * DSP input registers, separating the unpacker BRAM/read mux from the
     * multiplier cascade. This also preserves which matrix belongs to each
     * accepted vertex when software updates coefficients between vertices. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            vector_ff <= vector_i;
            coefficient_ff <= coefficient_i;
        end
    end

    for (genvar i = 0; i < 4; i++) begin
        assign products[i] = $signed(vector_ff[i]) * $signed(coefficient_ff[i]);
    end

    /* Second stage: register the four products. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            products_ff <= products;
        end
    end


    logic signed [57:0] partial_sum_01_ff, partial_sum_23_ff;
    logic signed [58:0] sum;

    /* Third stage: add each pair of registered products in parallel. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            partial_sum_01_ff <= {products_ff[0][56], products_ff[0]} + {products_ff[1][56], products_ff[1]};
            partial_sum_23_ff <= {products_ff[2][56], products_ff[2]} + {products_ff[3][56], products_ff[3]};
        end
    end

    /* Combine the registered partial sums. */
    assign sum = partial_sum_01_ff + partial_sum_23_ff;

    /* Q16.16 */
    assign element_o = sum[47:16];
    
endmodule : line_multiplier

`endif
