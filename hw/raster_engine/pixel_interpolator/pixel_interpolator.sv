`ifndef PIXEL_INTERPOLATOR_SV
    `define PIXEL_INTERPOLATOR_SV

module pixel_interpolator (
    input logic clk_i,
    input logic rst_n_i,

    /* Pulse on the same edge as rasterizer start_i & request_o */
    input logic start_i,

    /* Shared configuration; stable until the pipeline is drained */
    input logic gouraud_shading_i,
    input logic texture_i,
    input logic perspective_correct_i,
    input logic z_interpolation_i,

    /* X reference stays stable through interpolation; Y is captured on start_i. */
    input logic [9:0] bb_x_start_i,
    input logic [8:0] bb_y_start_i,

    /* Triangle planes and validity, captured on start_i */
    input setup_attribute_t [3:0] attr_i,
    input setup_color_plane_t [2:0] color_i,
    input logic [6:0] attr_valid_i,
    input logic [3:0] flat_r_i,
    input logic [3:0] flat_g_i,
    input logic [3:0] flat_b_i,

    /* Pixel interface */
    input logic [9:0] pixel_x_i,
    input logic [8:0] pixel_y_i,
    input logic pixel_valid_i,
    input logic new_line_i,

    /* Hold pixel coordinates/valid while row initialization is busy.
     * Once ready, fragments remain combinational with one pixel per clock. */
    output logic pixel_ready_o,
    output logic pixel_valid_o,

    /* Each lane is signed: [0] Z, [1] u/w, [2] v/w, [3] 1/w */
    output logic [3:0][43:0] attr_o,

    /* Each lane is signed: [0] R, [1] G, [2] B */
    output logic [2:0][35:0] color_o,
    output logic [6:0] attr_valid_o
);

//====================================================================================
//      ROW INITIALIZATION AND PIXEL ACCUMULATORS
//====================================================================================

    /* A row notification captures its coordinate deltas. The following three
     * edges register Y products, advance the row reference while registering X
     * products, then initialize X. Each lane reuses one multiplier and product
     * register; no multiplier feeds an accumulator adder in the same cycle.
     * Within a span, accepted pixels still advance by gx once per clock. */
    typedef enum logic [1:0] { READY, MULTIPLY, ADD_ROW, ADD_SPAN } state_t;
    state_t state_CRT;

    setup_attribute_t [3:0] attr_CRT;
    setup_color_plane_t [2:0] color_CRT;
    logic [6:0] attr_valid_CRT;
    logic [8:0] row_y_CRT;
    logic signed [10:0] delta_x_CRT;
    logic signed [9:0] delta_y_CRT;

    /* Signed F16 attributes and F12 colors retain their original accumulator
     * widths. Products fit these widths (32x11 and 24x11 at most); additions
     * wrap at 44/36 bits exactly as before, with no rounding or saturation.
     * ADD_ROW consumes the registered Y product while replacing it with X;
     * ADD_SPAN consumes that X product and the updated row reference. */
    logic [3:0][43:0] attr_row_CRT, attr_acc_CRT;
    logic [2:0][35:0] color_row_CRT, color_acc_CRT;
    logic signed [43:0] attr_product [4];
    logic signed [35:0] color_product [3];
    logic signed [10:0] multiply_delta;
    logic [6:0] attr_mask;
    logic [3:0] attr_enable;
    logic [2:0] color_enable;
    logic [2:0][3:0] flat_color;

    assign attr_mask = attr_valid_CRT & {{3{texture_i & perspective_correct_i}}, {3{gouraud_shading_i}}, z_interpolation_i};
    assign attr_enable = {attr_mask[ATTR_INV_W:ATTR_TEX_U], attr_mask[ATTR_Z]};
    assign color_enable = attr_mask[ATTR_B:ATTR_R];
    assign flat_color = {flat_b_i, flat_g_i, flat_r_i};

    /* Sign-extend the ten-bit Y delta to the shared signed multiplier input. */
    assign multiply_delta = (state_CRT == MULTIPLY) ? $signed(delta_y_CRT) : delta_x_CRT;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_CRT <= READY;
            attr_valid_CRT <= '0;
        end else if (start_i) begin
            /* A new descriptor also cancels any unfinished row initialization.
             * Payload needs no reset: start and state guard every later use. */
            state_CRT <= READY;
            attr_CRT <= attr_i;
            color_CRT <= color_i;
            attr_valid_CRT <= attr_valid_i;
            row_y_CRT <= bb_y_start_i;

            for (int i = 0; i < 4; i++) begin
                attr_row_CRT[i] <= attr_i[i].aref;
                attr_acc_CRT[i] <= '0;
            end
            for (int i = 0; i < 3; i++) begin
                color_row_CRT[i] <= color_i[i].aref;
                color_acc_CRT[i] <= gouraud_shading_i ? 36'b0 : {20'b0, flat_color[i], 12'b0};
            end
        end else begin
            /* One multiplication expression per lane makes X/Y sharing explicit.
             * Reset or start cancels preparation before any product can be used. */
            if ((state_CRT == MULTIPLY) || (state_CRT == ADD_ROW)) begin
                for (int i = 0; i < 4; i++) begin
                    attr_product[i] <= $signed((state_CRT == MULTIPLY) ? attr_CRT[i].gy : attr_CRT[i].gx) * multiply_delta;
                end
                for (int i = 0; i < 3; i++) begin
                    color_product[i] <= $signed((state_CRT == MULTIPLY) ? color_CRT[i].gy : color_CRT[i].gx) * multiply_delta;
                end
            end

            case (state_CRT)
                READY: begin
                    if (new_line_i) begin
                        /* Signed integer distances handle skipped rows and a
                         * changed span origin without introducing drift. */
                        delta_x_CRT <= $signed({1'b0, pixel_x_i}) - $signed({1'b0, bb_x_start_i});
                        delta_y_CRT <= $signed({1'b0, pixel_y_i}) - $signed({1'b0, row_y_CRT});
                        row_y_CRT <= pixel_y_i;

                        state_CRT <= MULTIPLY;
                    end else if (pixel_valid_i) begin
                        for (int i = 0; i < 4; i++) begin
                            if (attr_enable[i]) begin
                                attr_acc_CRT[i] <= $signed(attr_acc_CRT[i]) + $signed(attr_CRT[i].gx);
                            end
                        end

                        for (int i = 0; i < 3; i++) begin
                            if (color_enable[i]) begin
                                color_acc_CRT[i] <= $signed(color_acc_CRT[i]) + $signed(color_CRT[i].gx);
                            end
                        end
                    end
                end

                MULTIPLY: begin
                    state_CRT <= ADD_ROW;
                end

                ADD_ROW: begin
                    for (int i = 0; i < 4; i++) begin
                        if (attr_enable[i]) begin
                            attr_row_CRT[i] <= $signed(attr_row_CRT[i]) + attr_product[i];
                        end
                    end

                    for (int i = 0; i < 3; i++) begin
                        if (color_enable[i]) begin
                            color_row_CRT[i] <= $signed(color_row_CRT[i]) + color_product[i];
                        end
                    end

                    state_CRT <= ADD_SPAN;
                end

                ADD_SPAN: begin
                    for (int i = 0; i < 4; i++) begin
                        if (attr_enable[i]) begin
                            attr_acc_CRT[i] <= $signed(attr_row_CRT[i]) + attr_product[i];
                        end
                    end

                    for (int i = 0; i < 3; i++) begin
                        if (color_enable[i]) begin
                            color_acc_CRT[i] <= $signed(color_row_CRT[i]) + color_product[i];
                        end
                    end

                    state_CRT <= READY;
                end
            endcase
        end
    end

//====================================================================================
//      OUTPUT INTERFACE
//====================================================================================

    /* Row preparation runs independently of downstream stalls. Once ready,
     * bubbles hold the accumulators and the consumer controls pixel_valid_i. */
    assign pixel_ready_o = rst_n_i & (state_CRT == READY) & !start_i & !new_line_i;
    assign pixel_valid_o = pixel_valid_i & pixel_ready_o;
    assign attr_o = attr_acc_CRT;
    assign color_o = color_acc_CRT;
    assign attr_valid_o = attr_mask;

endmodule : pixel_interpolator

`endif
