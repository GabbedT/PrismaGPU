`ifndef TRIANGLE_MULTIPLY_UNIT_SV
    `define TRIANGLE_MULTIPLY_UNIT_SV

module triangle_multiply_unit #(
    parameter int LATENCY = 0
) (
    input logic clk_i, 
    input logic rst_n_i,

    /* Request interface */
    input logic req_valid_i,
    output logic req_ready_o,

    /* Operand interface */
    input logic signed [53:0] operand_a_i,
    input logic signed [32:0] operand_b_i,

    /* Result interface */
    input logic resp_ready_i,
    output logic resp_valid_o,
    output logic signed [86:0] product_o
);

`ifdef _VIVADO_
    
    localparam int PIPE_LENGTH = LATENCY > 0 ? LATENCY : 1;

    initial begin
        if (LATENCY < 1) $fatal(1, "Set LATENCY to the generated multiplier pipeline depth");
    end


    logic active;
    logic [PIPE_LENGTH-1:0] valid_pipe;
    logic signed [86:0] ip_product;

    triangle_multiply_ip u_ip (
        .CLK(clk_i), 
        .SCLR(!rst_n_i), 
        .A(operand_a_i), 
        .B(operand_b_i), 
        .P(ip_product)
    );

    assign req_ready_o = !active & !resp_valid_o;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            active <= 1'b0;
            valid_pipe <= '0;
            resp_valid_o <= 1'b0;
            product_o <= '0;
        end else begin
            valid_pipe <= (valid_pipe << 1) | {{(PIPE_LENGTH-1){1'b0}}, (req_valid_i & req_ready_o)};

            if (req_valid_i & req_ready_o) begin
                active <= 1'b1;
            end

            if (valid_pipe[PIPE_LENGTH-1]) begin
                product_o <= ip_product;
                resp_valid_o <= 1'b1;
                active <= 1'b0;
            end

            if (resp_valid_o & resp_ready_i) begin
                resp_valid_o <= 1'b0;
            end
        end
    end

`else

    assign req_ready_o = !resp_valid_o;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            resp_valid_o <= 1'b0;
            product_o <= '0;
        end else begin
            if (req_valid_i & req_ready_o) begin
                product_o <= 87'($signed(operand_a_i) * $signed(operand_b_i));
                resp_valid_o <= 1'b1;
            end else if (resp_valid_o & resp_ready_i) begin
                resp_valid_o <= 1'b0;
            end
        end
    end

`endif

endmodule : triangle_multiply_unit

`endif
