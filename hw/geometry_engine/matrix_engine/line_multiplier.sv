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

    for (genvar i = 0; i < 4; i++) begin
        assign products[i] = $signed(vector_i[i]) * $signed(coefficient_i[i]);
    end

    /* First stage: register the four products. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            products_ff <= products;
        end
    end


    logic signed [57:0] partial_sum_01_ff, partial_sum_23_ff;
    logic signed [58:0] sum;

    /* Second stage: add each pair of registered products in parallel. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            partial_sum_01_ff <= {products_ff[0][56], products_ff[0]} + {products_ff[1][56], products_ff[1]};
            partial_sum_23_ff <= {products_ff[2][56], products_ff[2]} + {products_ff[3][56], products_ff[3]};
        end
    end

    /* Third stage: combine the registered partial sums. */
    assign sum = partial_sum_01_ff + partial_sum_23_ff;

    /* Q16.16 */
    assign element_o = sum[47:16];
    
endmodule : line_multiplier

`endif
