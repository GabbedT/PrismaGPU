`ifndef PIXEL_RASTERIZER_SV
    `define PIXEL_RASTERIZER_SV

module pixel_rasterizer #(
    parameter bit SPAN_ONLY = 1'b0
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* From/To setup stage */
    input logic start_i,
    output logic request_o,

    /* Bounding box from shared configuration registers */
    input logic [9:0] bb_x_start_i,
    input logic [9:0] bb_x_end_i,
    input logic [8:0] bb_y_start_i,
    input logic [8:0] bb_y_end_i,
    
    /* Edges */
    input setup_edge_t [2:0] edge_i,

    /* Pixel out */
    output logic [9:0] pixel_x_o,
    output logic [8:0] pixel_y_o,

    /* First span coordinates, one cycle before its first valid pixel */
    output logic new_line_o,
    output logic pixel_valid_o,

    /* In SPAN_ONLY mode, new_line_o transfers an inclusive span on !stall_i.
     * done_o follows all nonempty spans, including draws with no samples. */
    output logic [9:0] span_x_end_o,
    output logic done_o
);


//====================================================================================
//      PARAMETERS AND FUNCTIONS
//====================================================================================

    localparam TM = 2;
    localparam TB = 1;
    localparam MB = 0;

    /* Index of couples */
    localparam TB_TM = 0;
    localparam TB_MB = 1;

//====================================================================================
//      REGISTERS
//====================================================================================


    typedef enum logic [2:0] {
        IDLE, Y_LOOP_SETUP, X_LOOP_SETUP, RASTER_PIXEL, INCREMENT_Y, RASTER_END
    } state_t;

    state_t state_CRT, state_NXT;
    logic couple_CRT, couple_NXT;
    logic [10:0] x_index_CRT, x_index_NXT;
    logic [9:0] y_index_CRT, y_index_NXT;
    logic signed [32:0] x_start_CRT, x_start_NXT, x_end_CRT, x_end_NXT;
    logic [8:0] y_start_CRT, y_start_NXT, y_end_CRT, y_end_NXT;
    logic signed [31:0] x_left_CRT, x_left_NXT, x_right_CRT, x_right_NXT;
    setup_edge_t [2:0] edge_CRT;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                state_CRT <= IDLE;
                couple_CRT <= TB_TM;
                x_index_CRT <= '0;
                y_index_CRT <= '0;
                x_start_CRT <= '0;
                x_end_CRT <= '0;
                y_start_CRT <= '0;
                y_end_CRT <= '0;
                x_left_CRT <= '0;
                x_right_CRT <= '0;
                edge_CRT <= '0;
            end else if (!stall_i) begin
                state_CRT <= state_NXT;
                couple_CRT <= couple_NXT;
                x_index_CRT <= x_index_NXT;
                y_index_CRT <= y_index_NXT;
                x_start_CRT <= x_start_NXT;
                x_end_CRT <= x_end_NXT;
                y_start_CRT <= y_start_NXT;
                y_end_CRT <= y_end_NXT;
                x_left_CRT <= x_left_NXT;
                x_right_CRT <= x_right_NXT;

                if (start_i & request_o) begin
                    edge_CRT <= edge_i;
                end
            end
        end

//====================================================================================
//      FSM LOGIC
//====================================================================================

    logic signed [32:0] x_left_pixel, x_right_pixel;
    logic flat_top, flat_bottom, outside_bb;

    assign flat_top = ((couple_CRT == TB_TM) && !edge_CRT[TM].valid);
    assign flat_bottom = ((couple_CRT == TB_MB) && !edge_CRT[MB].valid);

    assign x_left_pixel = ($signed(x_left_CRT) + 33'sd2047) >>> 12;
    assign x_right_pixel = (($signed(x_right_CRT) + 33'sd2047) >>> 12) - 33'sd1;

    assign outside_bb = (x_left_pixel > $signed({23'b0, bb_x_end_i})) | (x_right_pixel < $signed({23'b0, bb_x_start_i}));

        always_comb begin
            /* Default values */
            state_NXT = state_CRT;
            couple_NXT = couple_CRT;
            x_index_NXT = x_index_CRT;
            y_index_NXT = y_index_CRT;
            x_start_NXT = x_start_CRT;
            x_end_NXT = x_end_CRT;
            y_start_NXT = y_start_CRT;
            y_end_NXT = y_end_CRT;
            x_left_NXT = x_left_CRT;
            x_right_NXT = x_right_CRT;

            request_o = 1'b0;
            pixel_x_o = '0;
            pixel_y_o = '0;
            new_line_o = 1'b0;
            pixel_valid_o = 1'b0;
            span_x_end_o = '0;
            done_o = 1'b0;

            case (state_CRT)
                IDLE: begin
                    /* Request triangle to setup unit */
                    request_o = !stall_i;

                    if (start_i && request_o) begin
                        couple_NXT = TB_TM;
                        state_NXT = Y_LOOP_SETUP;
                    end
                end

                Y_LOOP_SETUP: begin
                    state_NXT = X_LOOP_SETUP;

                    /* Loop indexes */
                    y_index_NXT = '0;
                    x_index_NXT = '0;

                    if (couple_CRT == TB_TM) begin
                        /* Setup initial left and right X coord */
                        if (edge_CRT[TB].is_left) begin
                            x_left_NXT = edge_CRT[TB].x_initial;
                            x_right_NXT = edge_CRT[TM].x_initial;
                        end else begin
                            x_left_NXT = edge_CRT[TM].x_initial;
                            x_right_NXT = edge_CRT[TB].x_initial;
                        end


                        if (edge_CRT[TB].j_start > bb_y_start_i) begin
                            /* Top vertex is lower on the screen than bounding box */
                            y_start_NXT = edge_CRT[TB].j_start;
                        end else begin
                            /* Clip */
                            y_start_NXT = bb_y_start_i;
                        end

                        if (edge_CRT[TM].j_end < bb_y_end_i) begin
                            /* Bottom vertex is higher on the screen than bounding box */
                            y_end_NXT = edge_CRT[TM].j_end;
                        end else begin
                            /* Clip */
                            y_end_NXT = bb_y_end_i;
                        end
                    end else if (couple_CRT == TB_MB) begin
                        /* TB has already advanced to the first row of MB */
                        if (edge_CRT[TB].is_left) begin
                            x_right_NXT = edge_CRT[MB].x_initial;
                        end else begin
                            x_left_NXT = edge_CRT[MB].x_initial;
                        end


                        if (edge_CRT[MB].j_start > bb_y_start_i) begin
                            /* Top vertex is lower on the screen than bounding box */
                            y_start_NXT = edge_CRT[MB].j_start;
                        end else begin
                            /* Clip */
                            y_start_NXT = bb_y_start_i;
                        end

                        if (edge_CRT[MB].j_end < bb_y_end_i) begin
                            /* Bottom vertex is higher on the screen than bounding box */
                            y_end_NXT = edge_CRT[MB].j_end;
                        end else begin
                            /* Clip */
                            y_end_NXT = bb_y_end_i;
                        end
                    end

                    if (!edge_CRT[TB].valid) begin
                        state_NXT = RASTER_END;
                    end else if ((y_start_NXT > y_end_NXT) | flat_top | flat_bottom) begin
                        if (couple_CRT == TB_TM) begin
                            /* Go to the next couple */
                            state_NXT = Y_LOOP_SETUP;

                            couple_NXT = TB_MB;
                        end else begin
                            /* Terminate */
                            state_NXT = RASTER_END;
                        end
                    end
                end
                
                X_LOOP_SETUP: begin
                    state_NXT = SPAN_ONLY ? INCREMENT_Y : RASTER_PIXEL;
                    
                    /* Restart the pixel offset for each row */
                    x_index_NXT = '0;

                    /* Clip to BB */
                    x_start_NXT = ($signed({23'b0, bb_x_start_i}) > x_left_pixel) ? $signed({23'b0, bb_x_start_i}) : x_left_pixel;
                    x_end_NXT = ($signed({23'b0, bb_x_end_i}) > x_right_pixel) ? x_right_pixel : $signed({23'b0, bb_x_end_i});

                    /* Check before narrowing the signed span bounds */
                    if ((x_left_pixel > x_right_pixel) | outside_bb | (bb_x_start_i > bb_x_end_i)) begin
                        state_NXT = INCREMENT_Y;
                    end else begin
                        /* Initialize interpolation before the first pixel */
                        pixel_x_o = x_start_NXT[9:0];
                        pixel_y_o = y_start_CRT + y_index_CRT[8:0];
                        span_x_end_o = x_end_NXT[9:0];
                        
                        new_line_o = 1'b1;
                    end
                end

                RASTER_PIXEL: begin
                    x_index_NXT = x_index_CRT + 1;

                    /* Emit a pixel until end of line */
                    if ({22'b0, x_index_CRT} <= (x_end_CRT - x_start_CRT)) begin
                        pixel_x_o = x_start_CRT[9:0] + x_index_CRT[9:0];
                        pixel_y_o = y_start_CRT + y_index_CRT[8:0];
                        pixel_valid_o = 1'b1;
                    end else begin
                        state_NXT = INCREMENT_Y;
                    end
                end

                INCREMENT_Y: begin
                    y_index_NXT = y_index_CRT + 1;

                    if (y_index_NXT <= ({1'b0, y_end_CRT} - {1'b0, y_start_CRT})) begin
                        /* If outer Y loop has not ended */
                        state_NXT = X_LOOP_SETUP;
                    end else if (couple_CRT == TB_TM) begin
                        /* Outer Y loop has ended and another couple remains */
                        couple_NXT = TB_MB;
                        state_NXT = Y_LOOP_SETUP;
                    end else begin
                        /* Finished */
                        state_NXT = RASTER_END;
                    end

                    /* Increase X of edge slope */
                    if (couple_CRT == TB_TM) begin
                        if (edge_CRT[TB].is_left) begin
                            x_left_NXT = x_left_CRT + edge_CRT[TB].sx;
                            x_right_NXT = x_right_CRT + edge_CRT[TM].sx;
                        end else begin
                            x_left_NXT = x_left_CRT + edge_CRT[TM].sx;
                            x_right_NXT = x_right_CRT + edge_CRT[TB].sx;
                        end
                    end else begin
                        if (edge_CRT[TB].is_left) begin
                            x_left_NXT = x_left_CRT + edge_CRT[TB].sx;
                            x_right_NXT = x_right_CRT + edge_CRT[MB].sx;
                        end else begin
                            x_left_NXT = x_left_CRT + edge_CRT[MB].sx;
                            x_right_NXT = x_right_CRT + edge_CRT[TB].sx;
                        end
                    end
                end

                RASTER_END: begin
                    state_NXT = IDLE;
                    done_o = 1'b1;
                end

                default: begin
                    state_NXT = IDLE;
                end
            endcase    
        end

endmodule : pixel_rasterizer

`endif
