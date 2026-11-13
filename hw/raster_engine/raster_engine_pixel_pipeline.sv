`ifndef RASTER_ENGINE_PIXEL_PIPELINE_SV
    `define RASTER_ENGINE_PIXEL_PIPELINE_SV

module raster_engine_pixel_pipeline #(
    parameter integer MULTIPLIER_LATENCY = 0
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Triangle transfer: valid_i && !stall_o */
    input proc_triangle_t triangle_i,
    input logic valid_i,
    output logic stall_o,

    /* Shared configuration stays stable until every accepted triangle completes
     * and busy_o clears */
    input raster_config_t config_i,

    /* Independent texture loading port, eight RGBA4444 texels per beat */
    input logic texture_write_en_i,
    input logic [8:0] texture_write_address_i,
    input logic [127:0] texture_write_data_i,

    /* CLEAR_Z bypasses rasterization and ignores depth test/write enables */
    input logic clear_valid_i,
    output logic clear_ready_o,
    output logic clear_done_o,
    input logic [15:0] clear_depth_i,

    /* Depth DDR: every accepted command, including writes, requires a response */
    output logic ddr_request_o,
    input logic ddr_ready_i,
    output logic ddr_write_o,
    output logic [31:0] ddr_address_o,
    output logic [127:0] ddr_write_data_o,
    output logic [15:0] ddr_mask_o,
    input logic ddr_response_valid_i,
    input logic [127:0] ddr_read_data_i,

    /* ZenithSoC RGB444 pixel transfer: pixel_valid_o && !stall_i */
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

    /* Coordinate triangles from setup acceptance through their final output pixel
     * Setup can prepare a new triangle while an older one is rasterized
     * The active registers preserve the triangle currently being rasterized
     * IDLE means that the raster context is free, not that all pixels have left
     * RASTER feeds spans to the pixel path and waits for their Z work to finish
     * RETIRE saves the number of pixels still travelling through the final stages
     * The tail count keeps completion tied to the correct triangle
     * busy_o covers setup, rasterization, remaining output pixels and CLEAR_Z
     * CLEAR_Z starts only when triangle processing is idle */

    /* IDLE frees the raster context while setup or older pixels may still be active */
    typedef enum logic [1:0] { IDLE, RASTER, RETIRE } state_t;
    state_t state_CRT, state_NXT;

    logic clear_active_CRT, clear_active_NXT;
    logic clear_depth_ready, clear_request;
    logic triangle_accept, setup_ready, setup_valid, setup_accept;
    logic setup_discard, address_error, error_pending;
    setup_status_t setup_status, active_status, tail_status;
    status_t setup_math_status, active_math_status, tail_math_status;
    setup_status_t status_NXT;
    status_t math_status_NXT;
    logic done_NXT;

    /* Keep the active bounding box and flat Z while setup prepares the next triangle
     * Rasterizer and interpolator capture the remaining planes at raster_start */
    logic [9:0] active_x_start, active_x_end;
    logic [8:0] active_y_start, active_y_end;
    logic [16:0] setup_flat_z, flat_z_ff;
    logic raster_finished, depth_started, depth_finished;
    logic context_finished, pixel_accept, pixel_commit, depth_reject;
    logic [5:0] fragments_pending, fragments_next;

    /* Track one older triangle still in texturizer or blender
     * Ordered pixel output lets its remaining count identify the last pixel */
    logic tail_active_CRT, tail_active_NXT, retire_context;
    logic [5:0] tail_remaining_CRT, tail_remaining_NXT;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            clear_active_CRT <= 1'b0;
            tail_active_CRT <= 1'b0;
            done_o <= 1'b0;
            status_o <= SETUP_OK;
            math_status_o <= STATUS_OK;
        end else begin
            state_CRT <= state_NXT;
            clear_active_CRT <= clear_active_NXT;
            tail_active_CRT <= tail_active_NXT;
            done_o <= done_NXT;
            status_o <= status_NXT;
            math_status_o <= math_status_NXT;
        end
    end

    /* Payload is captured before use; validity and FSM state guard unreset registers */
    always_ff @(posedge clk_i) begin
        tail_remaining_CRT <= tail_remaining_NXT;

        if (triangle_accept) begin
            setup_flat_z <= triangle_i.vtx[0].pos.z;
        end

        /* Save setup context */
        if (setup_accept) begin
            active_status <= address_error ? SETUP_INVALID_CONFIG : setup_status;
            active_math_status <= setup_math_status;
            active_x_start <= bb_x_start;
            active_x_end <= bb_x_end;
            active_y_start <= bb_y_start;
            active_y_end <= bb_y_end;
            flat_z_ff <= setup_flat_z;
        end

        if (retire_context) begin
            tail_status <= active_status;
            tail_math_status <= active_math_status;
        end
    end

    always_comb begin
        state_NXT = state_CRT;
        clear_active_NXT = clear_active_CRT;
        tail_active_NXT = tail_active_CRT;
        tail_remaining_NXT = tail_remaining_CRT;
        status_NXT = status_o;
        math_status_NXT = math_status_o;
        done_NXT = 1'b0;

        error_o = (status_o == SETUP_MATH_ERROR) | (status_o == SETUP_INVALID_CONFIG);
        discard_o = status_o != SETUP_OK;
        address_error = config_i.z_test_enable & (config_i.z_buffer_address[3:0] != 0);
        error_pending = (done_o & error_o) |
                        (tail_active_CRT & ((tail_status == SETUP_MATH_ERROR) |
                                            (tail_status == SETUP_INVALID_CONFIG)));

        /* CLEAR_Z owns the depth port only after all triangle work has drained */
        busy_o = (state_CRT != IDLE) | !setup_ready | tail_active_CRT | clear_active_CRT;
        clear_request = clear_valid_i & !busy_o;
        clear_ready_o = clear_depth_ready & !busy_o;
        setup_accept = 1'b0;
        raster_start = 1'b0;
        span_pop = 1'b0;
        depth_start = 1'b0;
        depth_next_valid = 1'b0;
        retire_context = 1'b0;

        if (clear_valid_i & clear_ready_o) begin
            clear_active_NXT = 1'b1;
        end else if (clear_done_o) begin
            clear_active_NXT = 1'b0;
        end

        /* A newly retired context may already be empty. Test its captured
         * count here, keeping the fragment-admission and counter arithmetic
         * out of completion/status selection. */
        if (tail_active_CRT) begin
            if (pixel_commit) begin
                tail_remaining_NXT = tail_remaining_CRT - 1'b1;
            end

            if ((tail_remaining_CRT == 0) || (pixel_commit && tail_remaining_CRT == 1)) begin
                tail_active_NXT = 1'b0;
                done_NXT = 1'b1;
                status_NXT = tail_status;
                math_status_NXT = tail_math_status;
            end
        end

        case (state_CRT)
            IDLE: begin
                setup_accept = setup_valid & !clear_active_CRT & !error_pending;

                if (setup_accept) begin
                    if (setup_discard | address_error) begin
                        state_NXT = RETIRE;
                    end else begin
                        raster_start = 1'b1;
                        state_NXT = RASTER;
                    end
                end
            end

            RASTER: begin
                /* Feed Z ahead of pixel processing; without Z, wait for the walker */
                span_pop = (span_count != 0) & (config_i.z_test_enable ? (depth_started ? depth_next_ready : depth_request) : !span_active);
                depth_start = (span_count != 0) & config_i.z_test_enable & !depth_started;
                depth_next_valid = (span_count != 0) & config_i.z_test_enable & depth_started;

                /* Release shared context after the last fragment and Z write
                 * Texturizer and blender may still contain this triangle */
                if (context_finished) begin
                    state_NXT = RETIRE;
                end
            end

            RETIRE: begin
                error_pending = error_pending | (active_status == SETUP_MATH_ERROR) |
                                (active_status == SETUP_INVALID_CONFIG);

                /* Reuse the tail slot after the previous triangle completes
                 * Include this cycle's pixel transfers in the saved count */
                if (!tail_active_CRT) begin
                    retire_context = 1'b1;
                    tail_remaining_NXT = fragments_next;
                    tail_active_NXT = 1'b1;
                    state_NXT = IDLE;
                end
            end

            default: begin
                state_NXT = IDLE;
            end
        endcase

        /* Setup may accept the next triangle while rasterization is still active */
        stall_o = !rst_n_i | clear_valid_i | clear_active_CRT | !setup_ready | error_pending;
        triangle_accept = valid_i & !stall_o;
    end

//====================================================================================
//      TRIANGLE SETUP
//====================================================================================

    /* Convert the accepted triangle into the values needed to draw its pixels
     * Setup finds the bounding box and applies viewport and scissor limits
     * Edge data describes how the triangle boundaries move from row to row
     * Attribute and color planes describe how values change across the triangle
     * The configuration selects which attributes need to be calculated
     * Setup can finish early and hold its result while rasterization is busy
     * setup_accept transfers that result when the active context becomes free
     * Invalid or discarded triangles still report completion through the controller
     * A valid result starts the rasterizer and initializes the interpolator */

    logic [9:0] bb_x_start, bb_x_end;
    logic [8:0] bb_y_start, bb_y_end;
    setup_edge_t [2:0] edges;
    setup_attribute_t [3:0] attributes;
    setup_color_plane_t [2:0] colors;
    logic [6:0] attribute_valid;
    logic [3:0] flat_r, flat_g, flat_b;

    /* OUTPUT holds the next descriptor until the active context is free */
    triangle_setup #(.MULTIPLIER_LATENCY(MULTIPLIER_LATENCY)) setup_transform (
        .clk_i                 ( clk_i                        ),
        .rst_n_i               ( rst_n_i                      ),
        .triangle_valid_i      ( triangle_accept              ),
        .triangle_ready_o      ( setup_ready                  ),
        .triangle_i            ( triangle_i                   ),
        .gouraud_shading_i     ( config_i.gouraud_shading      ),
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

    /* Produce horizontal intervals instead of sending every pixel from the rasterizer
     * Each span contains its row and the first and last covered X coordinates.
     * This is done to prepare early the Z buffer test, it will fetch the span from
     * the Z buffer in DDR */

    /* One horizontal interval with inclusive X bounds and the DDR base of its Z row */
    typedef struct packed {
        logic [9:0] first_x, last_x;
        logic [8:0] y;
        logic [31:0] address;
        logic last;
    } span_t;

    /* The pending span captures coordinates before address generation. */
    typedef struct packed {
        logic [9:0] first_x, last_x;
        logic [8:0] y;
    } pending_span_t;

    pending_span_t pending_span;
    span_t span_fifo [2], front_span;
    logic pending_valid, span_read_ptr, span_write_ptr;
    logic [1:0] span_count;
    logic span_push, span_pop, raster_stall, raster_start, raster_line, raster_done;
    logic [9:0] raster_x, raster_end_x;
    logic [8:0] raster_y;

    assign raster_stall = span_count == 2;
    assign front_span = span_fifo[span_read_ptr];
    assign span_push = !raster_stall & pending_valid & (raster_line | raster_done);

    /* Emit span bounds; the walker below expands each interval into individual pixels */
    pixel_rasterizer #(.SPAN_ONLY(1'b1)) raster_transform (
        .clk_i         ( clk_i          ),
        .rst_n_i       ( rst_n_i        ),
        .stall_i       ( raster_stall   ),
        .start_i       ( raster_start   ),
        .request_o     (                ),
        .bb_x_start_i  ( active_x_start ),
        .bb_x_end_i    ( active_x_end   ),
        .bb_y_start_i  ( active_y_start ),
        .bb_y_end_i    ( active_y_end   ),
        .edge_i        ( edges          ),
        .pixel_x_o     ( raster_x       ),
        .pixel_y_o     ( raster_y       ),
        .new_line_o    ( raster_line    ),
        .pixel_valid_o (                ),
        .span_x_end_o  ( raster_end_x   ),
        .done_o        ( raster_done    )
    );

    logic [12:0] z_row_units;
    logic [31:0] z_row_offset;

    /* Calculate from the held Y, after rasterization has rounded/clipped X.
     * The offset is 5*y in 128-byte units (QVGA), doubled for VGA. Thirteen
     * unsigned bits cover every 9-bit Y in either mode; there is no rounding.
     * Keep the original 32-bit byte-address wrapping. Configuration remains
     * stable until the pipeline drains, including while this span is held. */
    always_comb begin
        z_row_units = ({4'b0, pending_span.y} << 2) + {4'b0, pending_span.y};

        if (config_i.viewport_size == RE_VIEWPORT_640_480) begin
            z_row_units = z_row_units << 1;
        end

        z_row_offset = {12'b0, z_row_units, 7'b0};
    end

    /* Hold one span until the next span or raster_done determines its last flag
     * Two queued descriptors let Z prefetch into the back bank */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i | raster_start) begin
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
        end
        if (span_push) begin
            span_fifo[span_write_ptr].first_x <= pending_span.first_x;
            span_fifo[span_write_ptr].last_x <= pending_span.last_x;
            span_fifo[span_write_ptr].y <= pending_span.y;
            span_fifo[span_write_ptr].address <= config_i.z_buffer_address + z_row_offset;
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
    logic interpolation_ready;

    /* Start walking when Z has prepared the row, or directly on span_pop without Z */
    assign source_new_line = config_i.z_test_enable ? depth_new_line : span_pop;
    assign source_first_x = config_i.z_test_enable ? depth_first_x : front_span.first_x;
    assign source_last_x = config_i.z_test_enable ? depth_last_x : front_span.last_x;
    assign source_y = source_new_line ? (config_i.z_test_enable ? (line_started ? next_y_ff : first_y_ff) : front_span.y) : active_y_ff;
    
    /* Advance coordinates and interpolation only when the pixel consumer accepts */
    assign pixel_accept = span_active & interpolation_ready &
                          (config_i.z_test_enable ? !depth_stall : !stall_i);

    always_ff @(posedge clk_i) begin
        if (!rst_n_i | raster_start) begin
            span_active <= 1'b0;
            line_started <= 1'b0;
            depth_started <= 1'b0;
            depth_finished <= 1'b0;
        end else begin
            if (span_pop & config_i.z_test_enable) begin
                depth_started <= 1'b1;
            end

            if (depth_done) begin
                depth_finished <= 1'b1;
            end

            if (source_new_line) begin
                span_active <= 1'b1;
                line_started <= 1'b1;
            end else if (pixel_accept & (source_x == last_x_ff)) begin
                span_active <= 1'b0;
            end
        end
    end

    always_ff @(posedge clk_i) begin
        /* Preserve Y alongside the first and prefetched Z span until activation */
        if (span_pop & config_i.z_test_enable) begin
            if (!depth_started) begin
                first_y_ff <= front_span.y;
            end else begin
                next_y_ff <= front_span.y;
            end
        end

        if (source_new_line) begin
            source_x <= source_first_x;
            last_x_ff <= source_last_x;
            active_y_ff <= source_y;
        end else if (pixel_accept) begin
            source_x <= source_x + 1'b1;
        end
    end

    pixel_interpolator interpolate_transform (
        .clk_i                 ( clk_i                                       ),
        .rst_n_i               ( rst_n_i                                     ),
        .start_i               ( raster_start                                ),
        .gouraud_shading_i     ( config_i.gouraud_shading                    ),
        .texture_i             ( config_i.texture_en                         ),
        .perspective_correct_i ( config_i.perspective_correct                ),
        .z_interpolation_i     ( config_i.z_interpolation                    ),
        .bb_x_start_i          ( active_x_start                              ),
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
        .pixel_ready_o         ( interpolation_ready                         ),
        .pixel_valid_o         (                                             ),
        .attr_o                ( interpolated_attributes                     ),
        .color_o               ( interpolated_color                          ),
        .attr_valid_o          (                                             )
    );

//====================================================================================
//      DEPTH TEST AND MATCHING PAYLOAD REGISTERS
//====================================================================================

    logic [15:0] source_z;
    logic depth_valid, depth_discard, depth_result_load, bypass_valid_ff;
    logic [9:0] depth_x_ff;
    logic [8:0] depth_y_ff;
    logic [2:0][15:0] clamped_color, depth_color_ff;
    logic [2:0][43:0] depth_texture_ff;
    logic [9:0] fragment_x_ff;
    logic [8:0] fragment_y_ff;
    logic [2:0][15:0] fragment_color_ff;
    logic [2:0][43:0] fragment_texture_ff;
    logic fragment_valid;

    /* Saturate each evaluated sample once, retaining all F12 fraction bits.
     * The signed 36-bit interpolator accumulators remain unchanged. Depth
     * and texture stages only delay RGB, so this commutes with their holds
     * and removes twenty payload bits per channel from every transit stage. */
    for (genvar channel = 0; channel < 3; channel++) begin : clamp_rgb
        assign clamped_color[channel] = clamp_fragment_color($signed(interpolated_color[channel]));
    end

    /* Saturate signed F16 depth to unsigned Q0.16 without changing fractional scale */
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
        .clear_valid_i        ( clear_request                        ),
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
        .pixel_valid_i        ( span_active & interpolation_ready & config_i.z_test_enable ),
        .pixel_x_i            ( source_x                             ),
        .pixel_z_i            ( source_z                             ),
        .test_enable_i        ( config_i.z_test_enable               ),
        .write_enable_i       ( config_i.z_write_enable              ),
        .compare_i            ( config_i.z_compare                   ),
        .stall_o              ( depth_stall                          ),
        .stall_i              ( stall_i                              ),
        .result_load_o        ( depth_result_load                    ),
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

    /* Keep attributes aligned with both elastic Z stages. A stalled result
     * holds its payload while the read stage may accept one more pixel.
     * Without Z, retain the original one-cycle payload bypass. */
    always_ff @(posedge clk_i) begin
        if (pixel_accept & config_i.z_test_enable) begin
            depth_x_ff <= source_x;
            depth_y_ff <= source_y;
            depth_color_ff <= clamped_color;
            depth_texture_ff <= interpolated_attributes[3:1];
        end
        if (config_i.z_test_enable) begin
            if (depth_result_load) begin
                fragment_x_ff <= depth_x_ff;
                fragment_y_ff <= depth_y_ff;
                fragment_color_ff <= depth_color_ff;
                fragment_texture_ff <= depth_texture_ff;
            end
        end else if (pixel_accept) begin
            fragment_x_ff <= source_x;
            fragment_y_ff <= source_y;
            fragment_color_ff <= clamped_color;
            fragment_texture_ff <= interpolated_attributes[3:1];
        end
        /* With Z disabled, this register supplies the matching payload valid */
        if (!rst_n_i) bypass_valid_ff <= 1'b0;
        else if (!stall_i) bypass_valid_ff <= pixel_accept & !config_i.z_test_enable;
    end

//====================================================================================
//      TEXTURIZER
//====================================================================================

    logic textured_valid, texture_valid;
    logic [9:0] textured_x;
    logic [8:0] textured_y;
    logic [2:0][15:0] textured_color;
    logic [15:0] texel;

    texturizer #(.CLAMPED_COLOR(1'b1)) texture_transform (
        .clk_i           ( clk_i                           ),
        .rst_n_i         ( rst_n_i                         ),
        .stall_i         ( stall_i                         ),
        .stall_o         (                                 ),
        .texture_en_i    ( config_i.texture_en             ),
        .texture_size_i  ( config_i.texture_size           ),
        .pixel_valid_i   ( fragment_valid                  ),
        .pixel_x_i       ( fragment_x_ff                   ),
        .pixel_y_i       ( fragment_y_ff                   ),
        .color_i         ( fragment_color_ff               ),
        .u_over_w_i      ( $signed(fragment_texture_ff[0]) ),
        .v_over_w_i      ( $signed(fragment_texture_ff[1]) ),
        .inv_w_i         ( $signed(fragment_texture_ff[2]) ),
        .write_en_i      ( texture_write_en_i              ),
        .write_address_i ( texture_write_address_i         ),
        .write_data_i    ( texture_write_data_i            ),
        .pixel_valid_o   ( textured_valid                  ),
        .pixel_x_o       ( textured_x                      ),
        .pixel_y_o       ( textured_y                      ),
        .color_o         ( textured_color                  ),
        .texel_o         ( texel                           ),
        .texture_valid_o ( texture_valid                   )
    );

//====================================================================================
//      PIXEL BLENDER AND COMPLETION BARRIER
//====================================================================================

    pixel_blender #(.CLAMPED_COLOR(1'b1)) blend_transform (
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

    /* Output acceptance retires a pixel here; framebuffer DDR completion is external */
    assign pixel_commit = pixel_valid_o & !stall_i;
    
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) fragments_pending <= '0;
        else fragments_pending <= fragments_next;
    end

    /* Count accepted fragments until they leave the pipeline or fail the Z test */
    assign fragments_next = fragments_pending + pixel_accept - pixel_commit - depth_reject;

    /* The raster context is reusable after all spans and Z writes finish
     * Remaining texturizer and blender pixels are tracked separately as the tail */
    assign context_finished = raster_finished & !pending_valid & (span_count == 0) & !span_active &
                              (!depth_started | depth_finished);

endmodule : raster_engine_pixel_pipeline

`endif
