`ifndef FRAMEBUFFER_BLENDER_SV
    `define FRAMEBUFFER_BLENDER_SV

module framebuffer_blender (
    input logic clk_i,
    input logic rst_n_i,

    /* Draw configuration. Keep enable_i stable until busy_o clears.
     * Alpha is unsigned A/15 and is captured with the source pixel. */
    input logic enable_i,
    input logic [3:0] alpha_i,

    /* Source pixel: accept on pixel_valid_i & pixel_ready_o. */
    input pixel_t pixel_i,
    input logic [9:0] pixel_x_i,
    input logic [8:0] pixel_y_i,
    input logic pixel_valid_i,
    output logic pixel_ready_o,

    /* Framebuffer write: hold RGB and coordinates until accepted. */
    output pixel_t pixel_o,
    output logic [9:0] pixel_x_o,
    output logic [8:0] pixel_y_o,
    output logic pixel_valid_o,
    input logic pixel_ready_i,

    /* Destination read request. The memory client flushes preceding writes
     * before servicing this request, preserving overlapping-pixel order. */
    output logic read_valid_o,
    input logic read_ready_i,
    output logic [9:0] read_x_o,
    output logic [8:0] read_y_o,

    /* Destination response: one RGB444 pixel for the accepted request.
     * The response must arrive after the request-accepting clock edge. */
    input pixel_t read_pixel_i,
    input logic read_valid_i,
    output logic read_ready_o,

    /* Covers the held source, destination read, arithmetic and output.
     * The caller includes busy_o in its frame-completion barrier. */
    output logic busy_o
);

//====================================================================================
//      TRANSACTION STATE
//====================================================================================

    typedef enum logic [2:0] {
        IDLE,
        READ_REQUEST,
        READ_RESPONSE,
        SUM,
        QUANTIZE,
        WRITE
    } state_t;

    state_t state_CRT, state_NXT;
    logic source_accept, destination_accept;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
        end else begin
            state_CRT <= state_NXT;
        end
    end

    always_comb begin
        state_NXT = state_CRT;

        case (state_CRT)
            IDLE: begin
                if (enable_i & source_accept) begin
                    state_NXT = READ_REQUEST;
                end
            end

            READ_REQUEST: begin
                if (read_valid_o & read_ready_i) begin
                    state_NXT = READ_RESPONSE;
                end
            end

            READ_RESPONSE: begin
                if (destination_accept) begin
                    state_NXT = SUM;
                end
            end

            SUM: begin
                state_NXT = QUANTIZE;
            end

            QUANTIZE: begin
                state_NXT = WRITE;
            end

            WRITE: begin
                if (pixel_valid_o & pixel_ready_i) begin
                    state_NXT = IDLE;
                end
            end

            default: begin
                state_NXT = IDLE;
            end
        endcase
    end

//====================================================================================
//      RGB444 ARITHMETIC
//====================================================================================

    logic [9:0] pixel_x_CRT;
    logic [8:0] pixel_y_CRT;
    logic [3:0] inverse_alpha_CRT;
    logic [2:0][3:0] source_rgb, destination_rgb;
    logic [2:0][7:0] source_product_CRT, destination_product_CRT;
    logic [2:0][7:0] weighted_sum_CRT;
    pixel_t mixed_CRT;

    /* RGB lanes follow the existing pixel blender: lane 0=R, 1=G, 2=B. */
    assign source_rgb = {pixel_i.blue, pixel_i.green, pixel_i.red};
    assign destination_rgb = {read_pixel_i.blue, read_pixel_i.green, read_pixel_i.red};

    /* N is unsigned in [0,225]. For N=16*H+L, N=15*H+(H+L).
     * H+L is at most 28, so one correction gives quotient and remainder.
     * Round N/15 to nearest: remainder >= 8 rounds up; no tie is possible.
     * Only nibble additions, comparison and subtraction are needed. */
    function automatic logic [3:0] quantize_color(input logic [7:0] numerator);
        logic [4:0] digit_sum;
        logic [4:0] remainder;
        logic [3:0] quotient;

        digit_sum = {1'b0, numerator[7:4]} + {1'b0, numerator[3:0]};
        quotient = numerator[7:4];
        remainder = digit_sum;

        if (digit_sum >= 5'd15) begin
            quotient = quotient + 4'd1;
            remainder = digit_sum - 5'd15;
        end

        return quotient + {3'b0, remainder >= 5'd8};
    endfunction

    /* Payload registers need no reset: state_CRT guards every use and reset
     * cancels the transaction. Source/destination products are 4x4 -> 8 bits.
     * Complementary weights guarantee N=S*A+D*(15-A) <= 225, so the sum
     * also fits eight bits. Keep products, sum and quantization on separate
     * clock edges; no multiplier feeds the normalization logic in one cycle. */
    always_ff @(posedge clk_i) begin
        if (rst_n_i) begin
            if (enable_i & source_accept) begin
                pixel_x_CRT <= pixel_x_i;
                pixel_y_CRT <= pixel_y_i;
                inverse_alpha_CRT <= ~alpha_i;

                for (int channel = 0; channel < 3; channel++) begin
                    source_product_CRT[channel] <= source_rgb[channel] * alpha_i;
                end
            end

            if (destination_accept) begin
                for (int channel = 0; channel < 3; channel++) begin
                    destination_product_CRT[channel] <= destination_rgb[channel] * inverse_alpha_CRT;
                end
            end

            if (state_CRT == SUM) begin
                for (int channel = 0; channel < 3; channel++) begin
                    weighted_sum_CRT[channel] <= source_product_CRT[channel] + destination_product_CRT[channel];
                end
            end

            if (state_CRT == QUANTIZE) begin
                mixed_CRT.red <= quantize_color(weighted_sum_CRT[0]);
                mixed_CRT.green <= quantize_color(weighted_sum_CRT[1]);
                mixed_CRT.blue <= quantize_color(weighted_sum_CRT[2]);
            end
        end
    end

//====================================================================================
//      HANDSHAKES AND OPAQUE BYPASS
//====================================================================================

    /* One source is held until its blended write is accepted. While waiting
     * on any memory handshake, state and the corresponding payload hold.
     * Disabled blending passes the opaque stream through combinationally. */
    assign source_accept = pixel_valid_i & pixel_ready_o;
    assign destination_accept = read_valid_i & read_ready_o;
    assign busy_o = state_CRT != IDLE;

    assign pixel_ready_o = (state_CRT == IDLE) & (enable_i | pixel_ready_i);
    assign pixel_o = enable_i ? mixed_CRT : pixel_i;
    assign pixel_x_o = enable_i ? pixel_x_CRT : pixel_x_i;
    assign pixel_y_o = enable_i ? pixel_y_CRT : pixel_y_i;
    assign pixel_valid_o = (enable_i ? (state_CRT == WRITE) : pixel_valid_i);

    assign read_x_o = pixel_x_CRT;
    assign read_y_o = pixel_y_CRT;
    assign read_valid_o = (state_CRT == READ_REQUEST);
    assign read_ready_o = (state_CRT == READ_RESPONSE);

endmodule : framebuffer_blender

`endif
