`ifndef RECIPROCAL_DIVIDER_SV
    `define RECIPROCAL_DIVIDER_SV

module reciprocal_divider (
    input logic clk_i,
    input logic rst_n_i,

    input logic [31:0] divisor_i,
    input logic valid_i,

    output logic error_o,
    output logic valid_o,

    /* Q1.24 reciprocal. */
    output logic [24:0] reciprocal_o,
    output logic signed [5:0] exponent_o
);

//====================================================================================
//      LEADING ONE DECODER
//====================================================================================  

    logic [3:0][7:0] splitted_divisor; logic [3:0] one_detect;

    assign splitted_divisor = {1'b0, divisor_i[30:0]};

    assign error_o = divisor_i == '0;


    logic [4:0] leading_one_idx;

        always_comb begin
            /* Default Values */
            leading_one_idx = '0;

            /* Check groups of 8 */
            for (int i = 0; i < 4; ++i) begin
                one_detect[i] = splitted_divisor[i] != '0;
            end

            casez (one_detect)
                4'b0001: begin
                    for (int i = 7; i >= 0; --i) begin
                        if (splitted_divisor[0][i]) begin
                            leading_one_idx = i;
                            break;
                        end
                    end
                end

                4'b001?: begin
                    for (int i = 7; i >= 0; --i) begin
                        if (splitted_divisor[1][i]) begin
                            leading_one_idx = i + 8;
                            break;
                        end
                    end
                end

                4'b01??: begin
                    for (int i = 7; i >= 0; --i) begin
                        if (splitted_divisor[2][i]) begin
                            leading_one_idx = i + 16;
                            break;
                        end
                    end
                end

                4'b1???: begin
                    for (int i = 7; i >= 0; --i) begin
                        if (splitted_divisor[3][i]) begin
                            leading_one_idx = i + 24;
                            break;
                        end
                    end
                end
            endcase
        end


    logic signed [5:0] exponent;
    logic [24:0] shifted_fractional;

    assign exponent = $signed({1'b0, leading_one_idx}) - 6'sd16;

        always_comb begin
            if (leading_one_idx <= 5'd24) begin
                shifted_fractional = divisor_i[30:0] << (24 - leading_one_idx);
            end else begin
                shifted_fractional = divisor_i[30:0] >> (leading_one_idx - 24);
            end
        end


    logic signed [5:0] exponent_stg1; logic [24:0] shifted_fractional_stg1;

        always_ff @(posedge clk_i) begin
            shifted_fractional_stg1 <= shifted_fractional;
            exponent_stg1 <= exponent;
        end


//====================================================================================
//      TABLE LOOKUP
//==================================================================================== 

    reciprocal_lut lut (
        .index_i      ( shifted_fractional_stg1[23:14] ),
        .reciprocal_o ( reciprocal_o                   )
    );

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                valid_o <= 1'b0;
            end else begin
                valid_o <= valid_i & !error_o;
            end
        end

    assign exponent_o = exponent_stg1;

endmodule : reciprocal_divider

`endif