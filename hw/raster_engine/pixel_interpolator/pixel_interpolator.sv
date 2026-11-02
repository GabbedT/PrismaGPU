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

    /* Reference pixel indices; stable until this triangle is drained */
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

    /* Combinational fragments; no output register or backpressure */
    output logic pixel_valid_o,

    /* Each lane is signed: [0] Z, [1] u/w, [2] v/w, [3] 1/w */
    output logic [3:0][43:0] attr_o,

    /* Each lane is signed: [0] R, [1] G, [2] B */
    output logic [2:0][35:0] color_o,
    output logic [6:0] attr_valid_o
);

//====================================================================================
//      REGISTERS
//====================================================================================

    setup_attribute_t [3:0] attr_CRT, attr_NXT;
    setup_color_plane_t [2:0] color_CRT, color_NXT;
    logic [6:0] attr_valid_CRT, attr_valid_NXT;
    logic [8:0] row_y_CRT, row_y_NXT;

    /* Row references stay at bb_x_start; accumulators follow the span */
    logic [3:0][43:0] attr_row_CRT, attr_row_NXT, attr_acc_CRT, attr_acc_NXT;
    logic [2:0][35:0] color_row_CRT, color_row_NXT, color_acc_CRT, color_acc_NXT;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                attr_valid_CRT <= '0;
            end else begin
                attr_valid_CRT <= attr_valid_NXT;
            end
        end

        always_ff @(posedge clk_i) begin
            if (rst_n_i) begin
                attr_CRT <= attr_NXT;
                color_CRT <= color_NXT;
                row_y_CRT <= row_y_NXT;
                attr_row_CRT <= attr_row_NXT;
                attr_acc_CRT <= attr_acc_NXT;
                color_row_CRT <= color_row_NXT;
                color_acc_CRT <= color_acc_NXT;
            end
        end

//====================================================================================
//      INTERPOLATION LOGIC
//====================================================================================

    logic [6:0] attr_mask;
    logic [3:0] attr_enable;
    logic [2:0] color_enable;
    logic [2:0][3:0] flat_color;
    logic signed [10:0] delta_x;
    logic signed [9:0] delta_y;
    logic signed [44:0] attr_row_next [4], attr_start [4];
    logic signed [36:0] color_row_next [3], color_start [3];

    /* Build mask to enable interpolation for attributes */
    assign attr_mask = attr_valid_CRT & {{3{texture_i & perspective_correct_i}}, {3{gouraud_shading_i}}, z_interpolation_i};
    
    /* Extract enable from the mask */
    assign attr_enable = {attr_mask[ATTR_INV_W:ATTR_TEX_U], attr_mask[ATTR_Z]};
    assign color_enable = attr_mask[ATTR_B:ATTR_R];
    
    assign flat_color = {flat_b_i, flat_g_i, flat_r_i};

    /* Integer pixel deltas: no extra half-pixel offset or fractional shift */
    assign delta_x = $signed({1'b0, pixel_x_i}) - $signed({1'b0, bb_x_start_i});
    assign delta_y = $signed({1'b0, pixel_y_i}) - $signed({1'b0, row_y_CRT});

        always_comb begin
            /* Default values */
            attr_NXT = attr_CRT;
            color_NXT = color_CRT;
            attr_valid_NXT = attr_valid_CRT;
            row_y_NXT = row_y_CRT;
            attr_row_NXT = attr_row_CRT;
            attr_acc_NXT = attr_acc_CRT;
            color_row_NXT = color_row_CRT;
            color_acc_NXT = color_acc_CRT;

           
            /* Calculate next row attributes Y and X */
            for (int i = 0; i < 4; i++) begin
                attr_row_next[i] = $signed(attr_row_CRT[i]) + (attr_CRT[i].gy * delta_y);
                attr_start[i] = attr_row_next[i] + (attr_CRT[i].gx * delta_x);
            end

            /* Calculate next row color Y and X */
            for (int i = 0; i < 3; i++) begin
                color_row_next[i] = $signed(color_row_CRT[i]) + (color_CRT[i].gy * delta_y);
                color_start[i] = color_row_next[i] + (color_CRT[i].gx * delta_x);
            end

            if (start_i) begin
                /* Initialize registers */
                attr_NXT = attr_i;
                color_NXT = color_i;
                attr_valid_NXT = attr_valid_i;
                row_y_NXT = bb_y_start_i;

                for (int i = 0; i < 4; i++) begin
                    attr_row_NXT[i] = attr_i[i].aref;
                    attr_acc_NXT[i] = '0;
                end

                for (int i = 0; i < 3; i++) begin
                    color_row_NXT[i] = color_i[i].aref;
                    color_acc_NXT[i] = gouraud_shading_i ? 36'b0 : {20'b0, flat_color[i], 12'b0};
                end
            end else if (new_line_i) begin
                row_y_NXT = pixel_y_i;

                /* On new line save the new attribute results */
                for (int i = 0; i < 4; i++) begin
                    if (attr_enable[i]) begin
                        attr_row_NXT[i] = attr_row_next[i][43:0];
                        attr_acc_NXT[i] = attr_start[i][43:0];
                    end
                end

                for (int i = 0; i < 3; i++) begin
                    if (color_enable[i]) begin
                        color_row_NXT[i] = color_row_next[i][35:0];
                        color_acc_NXT[i] = color_start[i][35:0];
                    end
                end
            end else if (pixel_valid_i) begin
                /* Bubbles hold the accumulators; valid pixels advance X by one */
                for (int i = 0; i < 4; i++) begin
                    if (attr_enable[i]) begin
                        attr_acc_NXT[i] = $signed(attr_acc_CRT[i]) + 44'($signed(attr_CRT[i].gx));
                    end
                end

                for (int i = 0; i < 3; i++) begin
                    if (color_enable[i]) begin
                        color_acc_NXT[i] = $signed(color_acc_CRT[i]) + 36'($signed(color_CRT[i].gx));
                    end
                end
            end
        end

//====================================================================================
//      OUTPUT INTERFACE
//====================================================================================

    assign pixel_valid_o = rst_n_i & pixel_valid_i & !start_i & !new_line_i;
    assign attr_o = attr_acc_CRT;
    assign color_o = color_acc_CRT;
    assign attr_valid_o = attr_mask;

endmodule : pixel_interpolator

`endif
