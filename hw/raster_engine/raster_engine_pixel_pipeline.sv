`ifndef RASTER_ENGINE_PIXEL_PIPELINE_SV
    `define RASTER_ENGINE_PIXEL_PIPELINE_SV

module raster_engine_pixel_pipeline (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Triangle transfer: valid_i && !stall_o. */
    input proc_triangle_t triangle_i,
    input logic valid_i,
    output logic stall_o,

    /* External register interface; stable from acceptance through done_o. */
    input raster_config_t config_i,

    /* Independent texture loading port, eight RGBA4444 texels per beat. */
    input logic texture_write_en_i,
    input logic [8:0] texture_write_address_i,
    input logic [127:0] texture_write_data_i,

    /* CLEAR_Z bypasses rasterization and ignores depth test/write enables. */
    input logic clear_valid_i,
    output logic clear_ready_o,
    output logic clear_done_o,
    input logic [15:0] clear_depth_i,

    /* Depth DDR: every accepted command, including writes, requires a response. */
    output logic ddr_request_o,
    input logic ddr_ready_i,
    output logic ddr_write_o,
    output logic [31:0] ddr_address_o,
    output logic [127:0] ddr_write_data_o,
    output logic [15:0] ddr_mask_o,
    input logic ddr_response_valid_i,
    input logic [127:0] ddr_read_data_i,

    /* Pixel transfer: pixel_valid_o && !stall_i. ZenithSoC RGB444. */
    output pixel_t pixel_o,
    output logic [9:0] pixel_x_o,
    output logic [8:0] pixel_y_o,
    output logic pixel_valid_o,
    output logic busy_o,
    output logic done_o,
    output setup_status_t status_o,
    output status_t math_status_o,
    output logic error_o,
    output logic discard_o,
    output logic z_rejected_o
);

//====================================================================================
//      TRANSACTION AND STALL CONTROL
//====================================================================================

    typedef enum logic [1:0] { IDLE, SETUP, RASTER } state_t;
    state_t state_CRT;

    /* Flat Z is triangle payload, not rendering configuration. */
    logic clear_active;
    logic clear_depth_ready, clear_available, clear_request;

    assign clear_available = (state_CRT == IDLE) && !clear_active;
    assign clear_request = clear_valid_i && clear_available;
    assign clear_ready_o = clear_depth_ready && clear_available;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            clear_active <= 1'b0;
        end else if (clear_valid_i && clear_ready_o) begin
            clear_active <= 1'b1;
        end else if (clear_done_o) begin
            clear_active <= 1'b0;
        end
    end
    logic [16:0] flat_z_ff;

    logic triangle_accept, setup_ready, setup_valid, setup_accept;
    logic setup_discard, address_error;
    setup_status_t setup_status;
    status_t setup_math_status;
    logic raster_finished, depth_started, depth_finished;
    logic [5:0] fragments_pending;
    logic pipeline_drained, pixel_accept, pixel_commit, depth_reject;

    assign stall_o = clear_valid_i | clear_active | !rst_n_i | (state_CRT != IDLE) | !setup_ready | stall_i;
    assign triangle_accept = valid_i & !stall_o;
    assign setup_accept = setup_valid & (state_CRT == SETUP);
    assign busy_o = state_CRT != IDLE || clear_active;
    assign error_o = (status_o == SETUP_MATH_ERROR) | (status_o == SETUP_INVALID_CONFIG);
    assign discard_o = status_o != SETUP_OK;
    assign address_error = config_i.z_test_enable & (config_i.z_buffer_address[3:0] != 0);

    always_ff @(posedge clk_i) begin
        if (triangle_accept) begin
            flat_z_ff <= triangle_i.vtx[0].pos.z;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            done_o <= 1'b0;
            status_o <= SETUP_OK;
            math_status_o <= STATUS_OK;
        end else begin
            done_o <= 1'b0;

            case (state_CRT)
                IDLE: begin
                    if (triangle_accept) begin
                        state_CRT <= SETUP;
                        status_o <= SETUP_OK;
                        math_status_o <= STATUS_OK;
                    end
                end

                SETUP: begin
                    if (setup_accept) begin
                        status_o <= address_error ? SETUP_INVALID_CONFIG : setup_status;
                        math_status_o <= setup_math_status;

                        if (setup_discard | address_error) begin
                            state_CRT <= IDLE;
                            done_o <= 1'b1;
                        end else begin
                            state_CRT <= RASTER;
                        end
                    end
                end

                RASTER: begin
                    if (pipeline_drained) begin
                        state_CRT <= IDLE;
                        done_o <= 1'b1;
                    end
                end
            endcase
        end
    end

//====================================================================================
//      TRIANGLE SETUP
//====================================================================================

    logic [9:0] bb_x_start, bb_x_end;
    logic [8:0] bb_y_start, bb_y_end;
    setup_edge_t [2:0] edges;
    setup_attribute_t [3:0] attributes;
    setup_color_plane_t [2:0] colors;
    logic [6:0] attribute_valid;
    logic [3:0] flat_r, flat_g, flat_b;

    /* Planes and edges are captured on raster_start. The setup bounding-box
     * registers retain the reference until the next triangle is accepted. */
    triangle_setup setup_transform (
        .clk_i                 ( clk_i                        ),
        .rst_n_i               ( rst_n_i                      ),
        .triangle_valid_i      ( triangle_accept              ),
        .triangle_ready_o      ( setup_ready                  ),
        .triangle_i            ( triangle_i                   ),
        .gouraud_shading_i      ( config_i.gouraud_shading      ),
        .texture_i             ( config_i.texture_en          ),
        .perspective_correct_i ( config_i.perspective_correct ),
        .z_interpolation_i     ( config_i.z_interpolation     ),
        .viewport_size_i       ( config_i.viewport_size       ),
        .scissor_enable_i      ( config_i.scissor_enable      ),
        .scissor_xmin_i        ( config_i.scissor_xmin        ),
        .scissor_xmax_i        ( config_i.scissor_xmax        ),
        .scissor_ymin_i        ( config_i.scissor_ymin        ),
        .scissor_ymax_i        ( config_i.scissor_ymax        ),
        .setup_valid_o         ( setup_valid                  ),
        .setup_ready_i         ( setup_accept                 ),
        .bb_x_start_o          ( bb_x_start                   ),
        .bb_x_end_o            ( bb_x_end                     ),
        .bb_y_start_o          ( bb_y_start                   ),
        .bb_y_end_o            ( bb_y_end                     ),
        .edge_tm_o             ( edges[2]                     ),
        .edge_tb_o             ( edges[1]                     ),
        .edge_mb_o             ( edges[0]                     ),
        .attr_o                ( attributes                   ),
        .color_o               ( colors                       ),
        .attr_valid_o          ( attribute_valid              ),
        .alpha_o               (                              ),
        .flat_r_o              ( flat_r                       ),
        .flat_g_o              ( flat_g                       ),
        .flat_b_o              ( flat_b                       ),
        .setup_status_o        ( setup_status                 ),
        .math_status_o         ( setup_math_status            ),
        .setup_error_o         (                              ),
        .setup_discard_o       ( setup_discard                ),
        .busy_o                (                              )
    );

//====================================================================================
//      RASTERIZER AND SPAN LOOKAHEAD
//====================================================================================

    typedef struct packed {
        logic [9:0] first_x, last_x;
        logic [8:0] y;
        logic [31:0] address;
        logic last;
    } span_t;
    span_t pending_span, span_fifo [2], front_span;
    logic pending_valid, span_read_ptr, span_write_ptr;
    logic [1:0] span_count;
    logic span_push, span_pop, raster_stall, raster_start, raster_line, raster_done;
    logic [9:0] raster_x, raster_end_x;
    logic [8:0] raster_y;

    assign raster_start = setup_accept & !setup_discard & !address_error;
    assign raster_stall = span_count == 2;
    assign front_span = span_fifo[span_read_ptr];
    assign span_push = !raster_stall & pending_valid & (raster_line | raster_done);

    pixel_rasterizer #(.SPAN_ONLY(1'b1)) raster_transform (
        .clk_i         ( clk_i        ),
        .rst_n_i       ( rst_n_i      ),
        .stall_i       ( raster_stall ),
        .start_i       ( raster_start ),
        .request_o     (              ),
        .bb_x_start_i  ( bb_x_start   ),
        .bb_x_end_i    ( bb_x_end     ),
        .bb_y_start_i  ( bb_y_start   ),
        .bb_y_end_i    ( bb_y_end     ),
        .edge_i        ( edges        ),
        .pixel_x_o     ( raster_x     ),
        .pixel_y_o     ( raster_y     ),
        .new_line_o    ( raster_line  ),
        .pixel_valid_o (              ),
        .span_x_end_o  ( raster_end_x ),
        .done_o        ( raster_done  )
    );

    logic [31:0] z_row_offset;

    always_comb begin
        z_row_offset = (32'(raster_y) << 9) + (32'(raster_y) << 7);

        if (config_i.viewport_size == RE_VIEWPORT_640_480) begin
            z_row_offset = z_row_offset << 1;
        end
    end

    /* Retain one unresolved span until another span or EOF determines last.
     * Two queued descriptors let the Z controller fill its back bank ahead. */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i | triangle_accept) begin
            pending_valid <= 1'b0;
            span_read_ptr <= 1'b0;
            span_write_ptr <= 1'b0;
            span_count <= '0;
            raster_finished <= 1'b0;
        end else begin
            if (!raster_stall) begin
                if (raster_line) pending_valid <= 1'b1;

                if (raster_done) begin
                    pending_valid <= 1'b0;
                    raster_finished <= 1'b1;
                end
            end

            if (span_push) span_write_ptr <= !span_write_ptr;

            if (span_pop) span_read_ptr <= !span_read_ptr;

            if (span_push != span_pop) begin
                if (span_push) begin
                    span_count <= span_count + 1'b1;
                end else begin
                    span_count <= span_count - 1'b1;
                end
            end
        end
    end

    always_ff @(posedge clk_i) begin
        if (!raster_stall & raster_line) begin
            pending_span.first_x <= raster_x;
            pending_span.last_x <= raster_end_x;
            pending_span.y <= raster_y;
            pending_span.address <= config_i.z_buffer_address + z_row_offset;
            pending_span.last <= 1'b0;
        end
        if (span_push) begin
            span_fifo[span_write_ptr] <= pending_span;
            span_fifo[span_write_ptr].last <= raster_done;
        end
    end

//====================================================================================
//      SPAN WALKER AND PIXEL INTERPOLATOR
//====================================================================================

    logic depth_request, depth_next_ready, depth_new_line, depth_done, depth_stall;
    logic depth_start, depth_next_valid;
    logic [9:0] depth_first_x, depth_last_x;
    logic [8:0] first_y_ff, next_y_ff, active_y_ff;
    logic line_started, span_active, source_new_line;
    logic [9:0] source_x, source_first_x, source_last_x, last_x_ff;
    logic [8:0] source_y;
    logic [3:0][43:0] interpolated_attributes;
    logic [2:0][35:0] interpolated_color;

    assign span_pop = (state_CRT == RASTER) & (span_count != 0) &
                      (config_i.z_test_enable ? (depth_started ? depth_next_ready : depth_request) : !span_active);
    assign source_new_line = config_i.z_test_enable ? depth_new_line : span_pop;
    assign source_first_x = config_i.z_test_enable ? depth_first_x : front_span.first_x;
    assign source_last_x = config_i.z_test_enable ? depth_last_x : front_span.last_x;
    assign source_y = source_new_line ?
                      (config_i.z_test_enable ? (line_started ? next_y_ff : first_y_ff) : front_span.y) : active_y_ff;
    assign pixel_accept = rst_n_i & span_active & (config_i.z_test_enable ? !depth_stall : !stall_i);
    assign depth_start = (span_count != 0) & config_i.z_test_enable & !depth_started & (state_CRT == RASTER);
    assign depth_next_valid = (span_count != 0) & config_i.z_test_enable & depth_started & (state_CRT == RASTER);

    always_ff @(posedge clk_i) begin
        if (!rst_n_i | triangle_accept) begin
            span_active <= 1'b0;
            line_started <= 1'b0;
            depth_started <= 1'b0;
            depth_finished <= 1'b0;
        end else begin
            if (span_pop & config_i.z_test_enable) depth_started <= 1'b1;
            if (depth_done) depth_finished <= 1'b1;
            if (source_new_line) begin
                span_active <= 1'b1;
                line_started <= 1'b1;
            end else if (pixel_accept & (source_x == last_x_ff)) span_active <= 1'b0;
        end
    end

    always_ff @(posedge clk_i) begin
        if (span_pop & config_i.z_test_enable) begin
            if (!depth_started) first_y_ff <= front_span.y;
            else next_y_ff <= front_span.y;
        end
        if (source_new_line) begin
            source_x <= source_first_x;
            last_x_ff <= source_last_x;
            active_y_ff <= source_y;
        end else if (pixel_accept) source_x <= source_x + 1'b1;
    end

    pixel_interpolator interpolate_transform (
        .clk_i                 ( clk_i                                       ),
        .rst_n_i               ( rst_n_i                                     ),
        .start_i               ( raster_start                                ),
        .gouraud_shading_i     ( config_i.gouraud_shading                    ),
        .texture_i             ( config_i.texture_en                         ),
        .perspective_correct_i ( config_i.perspective_correct                ),
        .z_interpolation_i     ( config_i.z_interpolation                    ),
        .bb_x_start_i          ( bb_x_start                                  ),
        .bb_y_start_i          ( bb_y_start                                  ),
        .attr_i                ( attributes                                  ),
        .color_i               ( colors                                      ),
        .attr_valid_i          ( attribute_valid                             ),
        .flat_r_i              ( flat_r                                      ),
        .flat_g_i              ( flat_g                                      ),
        .flat_b_i              ( flat_b                                      ),
        .pixel_x_i             ( source_new_line ? source_first_x : source_x ),
        .pixel_y_i             ( source_y                                    ),
        .pixel_valid_i         ( pixel_accept                                ),
        .new_line_i            ( source_new_line                             ),
        .pixel_valid_o         (                                             ),
        .attr_o                ( interpolated_attributes                     ),
        .color_o               ( interpolated_color                          ),
        .attr_valid_o          (                                             )
    );

//====================================================================================
//      DEPTH TEST AND MATCHING PAYLOAD REGISTER
//====================================================================================

    logic [15:0] source_z;
    logic depth_valid, depth_discard, bypass_valid_ff;
    logic [9:0] depth_x_ff;
    logic [8:0] depth_y_ff;
    logic [2:0][35:0] depth_color_ff;
    logic [2:0][43:0] depth_texture_ff;
    logic fragment_valid;

    function automatic logic [15:0] depth_value(input logic signed [43:0] value);
        if (value <= 0) return 16'd0;
        if (value >= 44'sd65535) return 16'hffff;
        return value[15:0];
    endfunction

    assign source_z = depth_value(config_i.z_interpolation ? $signed(interpolated_attributes[0]) :
                                 $signed({27'b0, flat_z_ff}));
    assign fragment_valid = config_i.z_test_enable ? depth_valid : bypass_valid_ff;
    assign z_rejected_o = depth_reject;
    assign depth_reject = config_i.z_test_enable & depth_discard & !stall_i;

    z_tester #(.Z_WIDTH(16), .ADDRESS_WIDTH(32)) depth_transform (
        .clk_i                ( clk_i                                ),
        .rst_n_i              ( rst_n_i                              ),
        .clear_valid_i        ( clear_request ),
        .clear_ready_o        ( clear_depth_ready                    ),
        .clear_done_o         ( clear_done_o                         ),
        .clear_depth_i        ( clear_depth_i                        ),
        .clear_base_i         ( config_i.z_buffer_address            ),
        .viewport_size_i      ( config_i.viewport_size               ),
        .start_i              ( depth_start                          ),
        .request_o            ( depth_request                        ),
        .line_address_i       ( front_span.address                   ),
        .x_start_i            ( front_span.first_x                   ),
        .x_end_i              ( front_span.last_x                    ),
        .last_line_i          ( front_span.last                      ),
        .next_valid_i         ( depth_next_valid                     ),
        .next_ready_o         ( depth_next_ready                     ),
        .next_line_address_i  ( front_span.address                   ),
        .next_x_start_i       ( front_span.first_x                   ),
        .next_x_end_i         ( front_span.last_x                    ),
        .next_last_line_i     ( front_span.last                      ),
        .new_line_o           ( depth_new_line                       ),
        .active_x_start_o     ( depth_first_x                        ),
        .active_x_end_o       ( depth_last_x                         ),
        .done_o               ( depth_done                           ),
        .pixel_valid_i        ( span_active & config_i.z_test_enable ),
        .pixel_x_i            ( source_x                             ),
        .pixel_z_i            ( source_z                             ),
        .test_enable_i        ( config_i.z_test_enable               ),
        .write_enable_i       ( config_i.z_write_enable              ),
        .compare_i            ( config_i.z_compare                   ),
        .stall_o              ( depth_stall                          ),
        .stall_i              ( stall_i                              ),
        .result_valid_o       (                                      ),
        .pixel_valid_o        ( depth_valid                          ),
        .discard_o            ( depth_discard                        ),
        .ddr_request_o        ( ddr_request_o                        ),
        .ddr_ready_i          ( ddr_ready_i                          ),
        .ddr_write_o          ( ddr_write_o                          ),
        .ddr_address_o        ( ddr_address_o                        ),
        .ddr_write_data_o     ( ddr_write_data_o                     ),
        .ddr_mask_o           ( ddr_mask_o                           ),
        .ddr_response_valid_i ( ddr_response_valid_i                 ),
        .ddr_read_data_i      ( ddr_read_data_i                      )
    );

    /* Depth can accept into an empty result register even during an output
     * stall. Capture its matching payload on that same acceptance edge. */
    always_ff @(posedge clk_i) begin
        if (pixel_accept) begin
            depth_x_ff <= source_x;
            depth_y_ff <= source_y;
            depth_color_ff <= interpolated_color;
            depth_texture_ff <= interpolated_attributes[3:1];
        end
        if (!rst_n_i) bypass_valid_ff <= 1'b0;
        else if (!stall_i) bypass_valid_ff <= pixel_accept & !config_i.z_test_enable;
    end

//====================================================================================
//      TEXTURIZER
//====================================================================================

    logic textured_valid, texture_valid;
    logic [9:0] textured_x;
    logic [8:0] textured_y;
    logic [2:0][35:0] textured_color;
    logic [15:0] texel;

    texturizer texture_transform (
        .clk_i           ( clk_i                        ),
        .rst_n_i         ( rst_n_i                      ),
        .stall_i         ( stall_i                      ),
        .stall_o         (                              ),
        .texture_en_i    ( config_i.texture_en          ),
        .texture_size_i  ( config_i.texture_size        ),
        .pixel_valid_i   ( fragment_valid               ),
        .pixel_x_i       ( depth_x_ff                   ),
        .pixel_y_i       ( depth_y_ff                   ),
        .color_i         ( depth_color_ff               ),
        .u_over_w_i      ( $signed(depth_texture_ff[0]) ),
        .v_over_w_i      ( $signed(depth_texture_ff[1]) ),
        .inv_w_i         ( $signed(depth_texture_ff[2]) ),
        .write_en_i      ( texture_write_en_i           ),
        .write_address_i ( texture_write_address_i      ),
        .write_data_i    ( texture_write_data_i         ),
        .pixel_valid_o   ( textured_valid               ),
        .pixel_x_o       ( textured_x                   ),
        .pixel_y_o       ( textured_y                   ),
        .color_o         ( textured_color               ),
        .texel_o         ( texel                        ),
        .texture_valid_o ( texture_valid                )
    );

//====================================================================================
//      PIXEL BLENDER AND COMPLETION BARRIER
//====================================================================================

    pixel_blender blend_transform (
        .clk_i           ( clk_i          ),
        .rst_n_i         ( rst_n_i        ),
        .stall_i         ( stall_i        ),
        .stall_o         (                ),
        .pixel_valid_i   ( textured_valid ),
        .pixel_x_i       ( textured_x     ),
        .pixel_y_i       ( textured_y     ),
        .color_i         ( textured_color ),
        .texel_i         ( texel          ),
        .texture_valid_i ( texture_valid  ),
        .pixel_valid_o   ( pixel_valid_o  ),
        .pixel_x_o       ( pixel_x_o      ),
        .pixel_y_o       ( pixel_y_o      ),
        .pixel_o         ( pixel_o        )
    );

    assign pixel_commit = pixel_valid_o & !stall_i;
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) fragments_pending <= '0;
        else fragments_pending <= fragments_pending + 6'(pixel_accept) - 6'(pixel_commit) - 6'(depth_reject);
    end

    assign pipeline_drained = raster_finished & !pending_valid & (span_count == 0) & !span_active &
                              (fragments_pending == 0) & (!depth_started | depth_finished);

endmodule : raster_engine_pixel_pipeline

`endif
