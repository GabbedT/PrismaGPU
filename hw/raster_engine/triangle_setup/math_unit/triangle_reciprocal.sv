`ifndef TRIANGLE_RECIPROCAL_SV
    `define TRIANGLE_RECIPROCAL_SV

module triangle_reciprocal (
    input logic clk_i, 
    input logic rst_n_i,

    input logic req_valid_i,
    output logic req_ready_o,

    input logic signed [37:0] denominator_i,
    input denominator_format_t den_format_i,

    input logic resp_ready_i,
    output logic resp_valid_o,
    output reciprocal_t result_o,
    output logic div_zero_o
);

    localparam int NEWTON_STEPS = 3;
    localparam int SEED_SHIFT = 15; // F17 -> F32

    typedef enum logic [2:0] {R_IDLE, SEED, PRODUCT_MX, CORRECTION, PRODUCT_XC, UPDATE_X, R_RESPONSE} recip_state_t;

    recip_state_t state;
    logic signed [38:0] extended_denominator;
    logic [38:0] magnitude, normalized;
    logic [5:0] leading_one;
    logic [33:0] multiplier_b, m, x, correction, rounded_product;
    logic [67:0] product;
    logic [68:0] correction_full;
    logic [17:0] seed;
    logic [1:0] iteration;

    assign extended_denominator = {denominator_i[37], denominator_i};
    assign magnitude = 39'(denominator_i[37] ? -extended_denominator : extended_denominator);
    
        always_comb begin
            leading_one = '0;

            for (int i = 0; i < 39; i++) begin
                if (magnitude[i]) begin
                    leading_one = 6'(i);
                end
            end

            if (leading_one <= 32) begin
                normalized = magnitude << (32 - leading_one);
            end else begin
                normalized = magnitude >> (leading_one - 32);
            end
        end

    reciprocal_lut lookup_table (
        .index_i      ( m[31:22] ), 
        .reciprocal_o ( seed     )
    );


    assign multiplier_b = state == PRODUCT_MX ? m : correction;
    assign correction_full = (69'd2 << 64) - {1'b0, product};
    assign rounded_product = product[65:32] + 34'(product[31] & ((|product[30:0]) | product[32]));
    assign req_ready_o = state == R_IDLE;
    assign resp_valid_o = state == R_RESPONSE;


    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state <= R_IDLE;
            iteration <= '0;

            result_o <= '0;
            div_zero_o <= 1'b0;
        end else begin
            case (state)
                R_IDLE: if (req_valid_i & req_ready_o) begin
                    result_o <= '0;
                    result_o.negative <= denominator_i[37];
                    result_o.exponent <= (den_format_i == DEN_F16 ? 8'sd16 : 8'sd8) - $signed({2'b0, leading_one});

                    div_zero_o <= denominator_i == 0;

                    m <= normalized[33:0];
                    iteration <= '0;

                    if (denominator_i == 0) begin
                        state <= R_RESPONSE;

                        result_o <= '0;
                    end else begin
                        state <= SEED;
                    end
                end

                SEED: begin
                    x <= 34'(seed) << SEED_SHIFT;
                    state <= PRODUCT_MX;
                end

                PRODUCT_MX, PRODUCT_XC: begin
                    product <= x * multiplier_b;
                    state <= state == PRODUCT_MX ? CORRECTION : UPDATE_X;
                end

                CORRECTION: begin
                    correction <= correction_full[65:32] + 34'(correction_full[31] & ((|correction_full[30:0]) | correction_full[32]));
                    state <= PRODUCT_XC;
                end

                UPDATE_X: begin
                    x <= rounded_product;
                    
                    if (iteration == 2'(NEWTON_STEPS-1)) begin
                        result_o.mantissa <= rounded_product[33:2] + 32'(rounded_product[1] & (rounded_product[0] | rounded_product[2]));
                        state <= R_RESPONSE;
                    end else begin
                        iteration <= iteration + 1'b1;
                        state <= PRODUCT_MX;
                    end
                end

                R_RESPONSE: begin
                    if (resp_ready_i) begin
                        state <= R_IDLE;
                    end
                end

                default: state <= R_IDLE;
            endcase
        end
    end

endmodule : triangle_reciprocal

`endif
