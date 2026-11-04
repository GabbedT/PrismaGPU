`ifndef RASTER_ENGINE_SV
    `define RASTER_ENGINE_SV

module raster_engine (
    input logic clk_i,
    input logic rst_n_i,
    output logic interrupt_o,

    /* Register write; word offsets */
    input logic register_write_i,
    input logic [5:0] register_write_address_i,
    input logic [3:0][7:0] register_write_data_i,
    input logic [3:0] register_write_strobe_i,
    output logic register_write_error_o,

    /* Register read */
    input logic register_read_i,
    input logic [5:0] register_read_address_i,
    output logic [31:0] register_read_data_o,
    output logic register_read_error_o,

    /* DDR read and write channels */
    gpu_ddr_interface.master read_ddr,
    gpu_ddr_interface.master write_ddr
);

//====================================================================================
//      CONTROL AND CONFIGURATION
//====================================================================================

    logic enable, start, stop, soft_reset, count_enable;
    logic [31:0] cmd_base, cmd_end;
    logic [31:0] prim_base, prim_end;
    logic [31:0] z_buffer_base, z_buffer_end;
    logic [31:0] fb_base, fb_end;
    raster_config_t config_data;
    logic busy, done, paused, stall, exhausted;
    logic notify_valid;
    logic [25:0] notify_id;
    logic command_error, config_error, address_error, math_error;
    logic [31:0] cmd_ptr, prim_ptr;
    logic [31:0] triangles_in, triangles_done, triangles_discarded;
    logic [31:0] stalls, pixels, z_rejects, cycles;

//====================================================================================
//      COMMAND PROCESSOR / MEMORY UNIT
//====================================================================================

    logic memory_initialize, memory_invalidate, memory_abort;
    logic framebuffer_discard, framebuffer_flush;
    logic memory_idle, framebuffer_idle, memory_error;
    re_command_t fetched_command;
    logic command_request, command_ready, command_commit, command_valid;
    logic draw_start, primitive_valid, primitive_ready;
    logic [27:0] draw_count;
    logic texture_start, texture_done;
    logic [31:0] texture_source_address;

//====================================================================================
//      PIPELINE INTERFACES
//====================================================================================

    proc_triangle_t triangle;
    logic triangle_valid, triangle_stall;
    logic pipe_busy, pipe_done, pipe_error, pipe_discard;
    logic pipe_abort, pipe_reset_n, pipe_z_reject;
    setup_status_t pipe_status;
    status_t pipe_math_status;
    logic texture_write;
    logic [8:0] texture_address;
    logic [127:0] texture_data;
    logic clear_valid, clear_ready, clear_done;
    logic [15:0] clear_depth;
    logic z_request, z_write, z_ready, z_response;
    logic [31:0] z_address;
    logic [127:0] z_data, z_read_data;
    logic [15:0] z_mask;
    pixel_t pixel;
    logic [9:0] pixel_x;
    logic [8:0] pixel_y;
    logic pixel_valid, pixel_ready;
    assign pipe_reset_n = rst_n_i && !pipe_abort;


//====================================================================================
//      REGISTER BANK
//====================================================================================

    raster_engine_registers registers (
        .clk_i                      ( clk_i                    ),
        .rst_n_i                    ( rst_n_i                  ),
        .interrupt_o                ( interrupt_o              ),
        .enable_o                   ( enable                   ),
        .start_processing_o         ( start                    ),
        .stop_processing_o          ( stop                     ),
        .soft_reset_o               ( soft_reset               ),
        .enable_pcounters_o         ( count_enable             ),
        .command_buffer_base_o      ( cmd_base                 ),
        .command_buffer_end_o       ( cmd_end                  ),
        .primitive_buffer_base_o    ( prim_base                ),
        .primitive_buffer_end_o     ( prim_end                 ),
        .z_buffer_base_o            ( z_buffer_base            ),
        .z_buffer_end_o             ( z_buffer_end             ),
        .framebuffer_base_o         ( fb_base                  ),
        .framebuffer_end_o          ( fb_end                   ),
        .config_o                   ( config_data              ),
        .busy_i                     ( busy                     ),
        .done_i                     ( done                     ),
        .stall_i                    ( stall                    ),
        .paused_i                   ( paused                   ),
        .cmd_exhausted_i            ( exhausted                ),
        .notify_valid_i             ( notify_valid             ),
        .notify_id_i                ( notify_id                ),
        .command_error_i            ( command_error            ),
        .config_error_i             ( config_error             ),
        .address_error_i            ( address_error            ),
        .math_error_i               ( math_error               ),
        .command_pointer_i          ( cmd_ptr                  ),
        .primitive_pointer_i        ( prim_ptr                 ),
        .input_triangle_count_i     ( triangles_in             ),
        .done_triangle_count_i      ( triangles_done           ),
        .discarded_triangle_count_i ( triangles_discarded      ),
        .stall_cycle_count_i        ( stalls                   ),
        .output_pixel_count_i       ( pixels                   ),
        .z_rejected_pixel_count_i   ( z_rejects                ),
        .busy_cycle_count_i         ( cycles                   ),
        .write_i                    ( register_write_i         ),
        .write_address_i            ( register_write_address_i ),
        .write_data_i               ( register_write_data_i    ),
        .write_strobe_i             ( register_write_strobe_i  ),
        .write_error_o              ( register_write_error_o   ),
        .read_i                     ( register_read_i          ),
        .read_address_i             ( register_read_address_i  ),
        .read_data_o                ( register_read_data_o     ),
        .read_error_o               ( register_read_error_o    )
    );

//====================================================================================
//      COMMAND PROCESSOR
//====================================================================================

    command_processor commands (
        .clk_i                 ( clk_i                           ),
        .rst_n_i               ( rst_n_i                         ),
        .enable_i              ( enable                          ),
        .start_i               ( start                           ),
        .stop_i                ( stop                            ),
        .soft_reset_i          ( soft_reset                      ),
        .command_base_i        ( cmd_base                        ),
        .command_end_i         ( cmd_end                         ),
        .primitive_base_i      ( prim_base                       ),
        .primitive_end_i       ( prim_end                        ),
        .z_buffer_base_i       ( z_buffer_base                   ),
        .z_buffer_end_i        ( z_buffer_end                    ),
        .framebuffer_base_i    ( fb_base                         ),
        .framebuffer_end_i     ( fb_end                          ),
        .config_i              ( config_data                     ),
        .busy_o                ( busy                            ),
        .done_o                ( done                            ),
        .paused_o              ( paused                          ),
        .stall_o               ( stall                           ),
        .cmd_exhausted_o       ( exhausted                       ),
        .notify_valid_o        ( notify_valid                    ),
        .notify_id_o           ( notify_id                       ),
        .command_error_o       ( command_error                   ),
        .config_error_o        ( config_error                    ),
        .address_error_o       ( address_error                   ),
        .math_error_o          ( math_error                      ),
        .memory_initialize_o   ( memory_initialize               ),
        .memory_invalidate_o   ( memory_invalidate               ),
        .memory_abort_o        ( memory_abort                    ),
        .framebuffer_discard_o ( framebuffer_discard             ),
        .framebuffer_flush_o   ( framebuffer_flush               ),
        .memory_idle_i         ( memory_idle                     ),
        .framebuffer_idle_i    ( framebuffer_idle                ),
        .memory_error_i        ( memory_error                    ),
        .command_request_o     ( command_request                 ),
        .command_ready_o       ( command_ready                   ),
        .command_commit_o      ( command_commit                  ),
        .command_i             ( fetched_command                 ),
        .command_valid_i       ( command_valid                   ),
        .command_pointer_i     ( cmd_ptr                         ),
        .primitive_pointer_i   ( prim_ptr                        ),
        .draw_start_o          ( draw_start                      ),
        .draw_count_o          ( draw_count                      ),
        .primitive_valid_i     ( primitive_valid                 ),
        .primitive_ready_o     ( primitive_ready                 ),
        .triangle_valid_o      ( triangle_valid                  ),
        .triangle_stall_i      ( triangle_stall                  ),
        .pipeline_busy_i       ( pipe_busy                       ),
        .pipeline_done_i       ( pipe_done                       ),
        .pipeline_error_i      ( pipe_error                      ),
        .pipeline_math_error_i ( pipe_status == SETUP_MATH_ERROR ),
        .pixel_ready_i         ( pixel_ready                     ),
        .pipeline_abort_o      ( pipe_abort                      ),
        .texture_start_o       ( texture_start                   ),
        .texture_address_o     ( texture_source_address          ),
        .texture_done_i        ( texture_done                    ),
        .clear_valid_o         ( clear_valid                     ),
        .clear_ready_i         ( clear_ready                     ),
        .clear_done_i          ( clear_done                      ),
        .clear_depth_o         ( clear_depth                     )
    );

//====================================================================================
//      MEMORY UNIT
//====================================================================================

    /* Destination blending will connect to the currently idle read client. */
    memory_unit memory (
        .clk_i                   ( clk_i                  ),
        .rst_n_i                 ( rst_n_i                ),
        .initialize_i            ( memory_initialize      ),
        .invalidate_i            ( memory_invalidate      ),
        .abort_i                 ( memory_abort           ),
        .reset_execution_i       ( soft_reset             ),
        .discard_framebuffer_i   ( framebuffer_discard    ),
        .command_base_i          ( cmd_base               ),
        .command_end_i           ( cmd_end                ),
        .primitive_base_i        ( prim_base              ),
        .primitive_end_i         ( prim_end               ),
        .z_base_i                ( z_buffer_base          ),
        .z_end_i                 ( z_buffer_end           ),
        .framebuffer_base_i      ( fb_base                ),
        .framebuffer_end_i       ( fb_end                 ),
        .config_i                ( config_data            ),
        .command_request_i       ( command_request        ),
        .command_ready_i         ( command_ready          ),
        .command_commit_i        ( command_commit         ),
        .command_o               ( fetched_command        ),
        .command_valid_o         ( command_valid          ),
        .command_pointer_o       ( cmd_ptr                ),
        .primitive_pointer_o     ( prim_ptr               ),
        .draw_start_i            ( draw_start             ),
        .draw_count_i            ( draw_count             ),
        .primitive_o             ( triangle               ),
        .primitive_valid_o       ( primitive_valid        ),
        .primitive_ready_i       ( primitive_ready        ),
        .texture_start_i         ( texture_start          ),
        .texture_address_i       ( texture_source_address ),
        .texture_done_o          ( texture_done           ),
        .texture_write_en_o      ( texture_write          ),
        .texture_write_address_o ( texture_address        ),
        .texture_write_data_o    ( texture_data           ),
        .z_request_i             ( z_request              ),
        .z_write_i               ( z_write                ),
        .z_ready_o               ( z_ready                ),
        .z_response_o            ( z_response             ),
        .z_address_i             ( z_address              ),
        .z_write_data_i          ( z_data                 ),
        .z_mask_i                ( z_mask                 ),
        .z_read_data_o           ( z_read_data            ),
        .pixel_i                 ( pixel                  ),
        .pixel_x_i               ( pixel_x                ),
        .pixel_y_i               ( pixel_y                ),
        .pixel_valid_i           ( pixel_valid            ),
        .pixel_ready_o           ( pixel_ready            ),
        .blend_valid_i           ( 1'b0                   ),
        .blend_ready_o           (                        ),
        .blend_x_i               ( '0                     ),
        .blend_y_i               ( '0                     ),
        .blend_pixel_o           (                        ),
        .blend_valid_o           (                        ),
        .blend_ready_i           ( 1'b1                   ),
        .framebuffer_flush_i     ( framebuffer_flush      ),
        .framebuffer_idle_o      ( framebuffer_idle       ),
        .idle_o                  ( memory_idle            ),
        .address_error_o         ( memory_error           ),
        .read_ddr                ( read_ddr               ),
        .write_ddr               ( write_ddr              )
    );

//====================================================================================
//      PIXEL PIPELINE
//====================================================================================

    raster_engine_pixel_pipeline pipeline (
        .clk_i                   ( clk_i            ),
        .rst_n_i                 ( pipe_reset_n     ),
        .stall_i                 ( !pixel_ready     ),
        .triangle_i              ( triangle         ),
        .valid_i                 ( triangle_valid   ),
        .stall_o                 ( triangle_stall   ),
        .config_i                ( config_data      ),
        .texture_write_en_i      ( texture_write    ),
        .texture_write_address_i ( texture_address  ),
        .texture_write_data_i    ( texture_data     ),
        .clear_valid_i           ( clear_valid      ),
        .clear_ready_o           ( clear_ready      ),
        .clear_done_o            ( clear_done       ),
        .clear_depth_i           ( clear_depth      ),
        .ddr_request_o           ( z_request        ),
        .ddr_ready_i             ( z_ready          ),
        .ddr_write_o             ( z_write          ),
        .ddr_address_o           ( z_address        ),
        .ddr_write_data_o        ( z_data           ),
        .ddr_mask_o              ( z_mask           ),
        .ddr_response_valid_i    ( z_response       ),
        .ddr_read_data_i         ( z_read_data      ),
        .pixel_o                 ( pixel            ),
        .pixel_x_o               ( pixel_x          ),
        .pixel_y_o               ( pixel_y          ),
        .pixel_valid_o           ( pixel_valid      ),
        .busy_o                  ( pipe_busy        ),
        .done_o                  ( pipe_done        ),
        .status_o                ( pipe_status      ),
        .math_status_o           ( pipe_math_status ),
        .error_o                 ( pipe_error       ),
        .discard_o               ( pipe_discard     ),
        .z_rejected_o            ( pipe_z_reject    )
    );

//====================================================================================
//      PERFORMANCE COUNTERS
//====================================================================================

    always_ff @(posedge clk_i) begin
        if (!rst_n_i || soft_reset) begin
            triangles_in <= '0;
            triangles_done <= '0;
            triangles_discarded <= '0;
            stalls <= '0;
            pixels <= '0;
            z_rejects <= '0;
            cycles <= '0;
        end else if (count_enable && !pipe_abort) begin
            if (triangle_valid && !triangle_stall) begin
                triangles_in <= triangles_in + 32'd1;
            end

            if (pipe_done) begin
                triangles_done <= triangles_done + 32'd1;
                if (pipe_discard) begin
                    triangles_discarded <= triangles_discarded + 32'd1;
                end
            end

            if (stall) begin
                stalls <= stalls + 32'd1;
            end

            if (pixel_valid && pixel_ready) begin
                pixels <= pixels + 32'd1;
            end

            if (pipe_z_reject) begin
                z_rejects <= z_rejects + 32'd1;
            end

            if (busy) begin
                cycles <= cycles + 32'd1;
            end
        end
    end

endmodule : raster_engine

`endif
