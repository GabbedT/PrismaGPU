`ifndef PIXEL_BLENDER_SV
    `define PIXEL_BLENDER_SV

module pixel_blender (
    input logic clk_i,
    input logic rst_n_i,

    /* Global pipeline hold, shared with the texturizer. */
    input logic stall_i,
    output logic stall_o,

    input logic pixel_valid_i,
    input logic [9:0] pixel_x_i,
    input logic [8:0] pixel_y_i,

    /* Signed S(36,12), channel scale 0..15, lanes 0=R, 1=G, 2=B. */
    input logic [2:0][35:0] color_i,
    input logic [15:0] texel_i,
    input logic texture_valid_i,

    output logic pixel_valid_o,
    output logic [9:0] pixel_x_o,
    output logic [8:0] pixel_y_o,
    output pixel_t pixel_o
);

    localparam int LATENCY = PIXEL_BLENDER_LATENCY;

    logic [LATENCY - 1:0] valid_pipe;
    logic [9:0] x_pipe [LATENCY];
    logic [8:0] y_pipe [LATENCY];

    logic [2:0][15:0] color_clamped;
    logic [2:0][3:0] texture_rgb;
    logic [3:0] alpha, inverse_alpha;
    logic [2:0][19:0] color_product;
    logic [2:0][7:0] texture_product;
    logic [2:0][19:0] weighted_sum;

    assign stall_o = stall_i;

    function automatic logic [15:0] clamp_color(input logic signed [35:0] value);
        if (value <= 0) return 16'd0;
        if (value >= 36'sd61440) return 16'd61440;
        return value[15:0];
    endfunction

    /* Convert numerator / (15 * 4096) to RGB4, nearest with ties to even */
    function automatic logic [3:0] quantize_color(input logic [19:0] numerator);
        logic [4:0] digit_sum;
        logic [3:0] quotient;
        logic [4:0] remainder;
        logic increment;

        digit_sum = {1'b0, numerator[19:16]} + {1'b0, numerator[15:12]};
        quotient = numerator[19:16];
        remainder = digit_sum;

        if (digit_sum >= 5'd15) begin
            quotient = quotient + 4'd1;
            remainder = digit_sum - 5'd15;
        end

        /* Half of 15 is 7.5: retain the twelve fractional bits for the tie. */
        increment = (remainder > 5'd7) | ((remainder == 5'd7) & ((numerator[11:0] > 12'd2048) |
                    ((numerator[11:0] == 12'd2048) & quotient[0])));

        return quotient + {3'b0, increment};
    endfunction

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_pipe <= '0;
        end else if (!stall_i) begin
            valid_pipe <= {valid_pipe[LATENCY - 2:0], pixel_valid_i};
        end
    end

    /* Reset flushes validity even under stall; payload is meaningful only
     * with pixel_valid_o. All payload and valid registers hold on stall. */
    always_ff @(posedge clk_i) begin
        if (rst_n_i & !stall_i) begin
            x_pipe[0] <= pixel_x_i;
            y_pipe[0] <= pixel_y_i;
            for (int stage = 1; stage < LATENCY; stage++) begin
                x_pipe[stage] <= x_pipe[stage - 1];
                y_pipe[stage] <= y_pipe[stage - 1];
            end

            /* Stage 1: clamp the base color, retaining all F12 precision.
             * An invalid texel becomes transparent; ignore all its bits. */
            for (int channel = 0; channel < 3; channel++) begin
                color_clamped[channel] <= clamp_color($signed(color_i[channel]));
                texture_rgb[channel] <= texture_valid_i ? texel_i[12 - 4*channel +: 4] : 4'd0;
            end
            
            alpha <= texture_valid_i ? texel_i[3:0] : 4'd0;
            inverse_alpha <= texture_valid_i ? (4'd15 - texel_i[3:0]) : 4'd15;

            for (int channel = 0; channel < 3; channel++) begin
                /* Stage 2: unsigned 16x4 base and 4x4 texture products. */
                color_product[channel] <= color_clamped[channel] * inverse_alpha;
                texture_product[channel] <= texture_rgb[channel] * alpha;

                /* Stage 3: weighted F12 numerator, maximum 921600. */
                weighted_sum[channel] <= color_product[channel] + {texture_product[channel], 12'b0};
            end

            /* Stage 4: exact normalization and a single final rounding. */
            pixel_o.red <= quantize_color(weighted_sum[0]);
            pixel_o.green <= quantize_color(weighted_sum[1]);
            pixel_o.blue <= quantize_color(weighted_sum[2]);
        end
    end

    assign pixel_valid_o = valid_pipe[LATENCY - 1];
    assign pixel_x_o = x_pipe[LATENCY - 1];
    assign pixel_y_o = y_pipe[LATENCY - 1];

endmodule : pixel_blender

`endif
