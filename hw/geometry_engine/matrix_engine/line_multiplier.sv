`ifndef LINE_MULTIPLIER_SV
    `define LINE_MULTIPLIER_SV

module line_multiplier (
    input logic [3:0][31:0] vector_i,
    input logic [3:0][31:0] coefficient_i,

    output logic [31:0] element_o
);

    logic signed [3:0][63:0] products;

    for (genvar i = 0; i < 4; i++) begin
        assign products[i] = $signed(vector_i[i]) * $signed(coefficient_i[i]);
    end


    logic signed [65:0] sum; 
    
    assign sum = {{2{products[0][63]}}, products[0]} + {{2{products[1][63]}}, products[1]} +
                 {{2{products[2][63]}}, products[2]} + {{2{products[3][63]}}, products[3]};

    /* Q16.16 */
    assign element_o = sum[47:16];
    
endmodule : line_multiplier

`endif