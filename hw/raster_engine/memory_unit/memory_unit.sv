`ifndef RE_MEMORY_UNIT_SV
    `define RE_MEMORY_UNIT_SV

module memory_unit (
    input logic clk_i,
    input logic rst_n_i,

    /* Execution control */
    input logic initialize_i,
    input logic invalidate_i,
    input logic abort_i,
    input logic reset_execution_i,
    input logic discard_framebuffer_i,

    /* Register configuration; byte ranges [BASE, END) */
    input logic [31:0] command_base_i,
    input logic [31:0] command_end_i,
    input logic [31:0] primitive_base_i,
    input logic [31:0] primitive_end_i,
    input logic [31:0] z_base_i,
    input logic [31:0] z_end_i,
    input logic [31:0] framebuffer_base_i,
    input logic [31:0] framebuffer_end_i,
    input raster_config_t config_i,

    /* Command fetch and retirement */
    input logic command_request_i,
    input logic command_ready_i,
    input logic command_commit_i,
    output re_command_t command_o,
    output logic command_valid_o,
    output logic [31:0] command_pointer_o,
    output logic [31:0] primitive_pointer_o,

    /* Primitive fetch and pipeline transfer */
    input logic draw_start_i,
    input logic [27:0] draw_count_i,
    output proc_triangle_t primitive_o,
    output logic primitive_valid_o,
    input logic primitive_ready_i,

    /* Texture load and RAM write */
    input logic texture_start_i,
    input logic [31:0] texture_address_i,
    output logic texture_done_o,
    output logic texture_write_en_o,
    output logic [8:0] texture_write_address_o,
    output logic [127:0] texture_write_data_o,

    /* Depth memory client */
    input logic z_request_i,
    input logic z_write_i,
    output logic z_ready_o,
    output logic z_response_o,
    input logic [31:0] z_address_i,
    input logic [127:0] z_write_data_i,
    input logic [15:0] z_mask_i,
    output logic [127:0] z_read_data_o,

    /* Final pixel writer */
    input pixel_t pixel_i,
    input logic [9:0] pixel_x_i,
    input logic [8:0] pixel_y_i,
    input logic pixel_valid_i,
    output logic pixel_ready_o,

    /* Destination pixel read */
    input logic blend_valid_i,
    output logic blend_ready_o,
    input logic [9:0] blend_x_i,
    input logic [8:0] blend_y_i,
    output pixel_t blend_pixel_o,
    output logic blend_valid_o,
    input logic blend_ready_i,

    /* Drain and status */
    input logic framebuffer_flush_i,
    output logic framebuffer_idle_o,
    output logic idle_o,
    output logic address_error_o,

    /* External memory */
    gpu_ddr_interface.master read_ddr,
    gpu_ddr_interface.master write_ddr
);

//====================================================================================
//      INTERNAL MEMORY CHANNELS
//====================================================================================

    localparam integer READ_COMMAND = 0;
    localparam integer READ_PRIMITIVE = 1;
    localparam integer READ_TEXTURE = 2;
    localparam integer READ_Z = 3;
    localparam integer READ_FRAMEBUFFER = 4;
    localparam integer WRITE_Z = 0;
    localparam integer WRITE_FRAMEBUFFER = 1;

    logic [4:0] read_request, read_ready, read_response, read_error;
    logic [4:0][31:0] read_address;
    logic [127:0] read_data;
    logic read_idle;

    logic [1:0] write_request, write_ready, write_response, write_error;
    logic [1:0][31:0] write_address;
    logic [1:0][127:0] write_data;
    logic [1:0][15:0] write_mask;
    logic write_idle;

    logic cancel, clear_fetch;
    logic framebuffer_reset, framebuffer_error, z_address_valid, z_address_error_CRT;
    logic z_checked_CRT, z_address_valid_CRT;
    logic texture_active;

    assign cancel = abort_i | reset_execution_i;
    assign clear_fetch = cancel | initialize_i | invalidate_i;
    assign framebuffer_reset = discard_framebuffer_i | invalidate_i | initialize_i;

    assign idle_o = read_idle & write_idle & framebuffer_idle_o & !texture_active;
    assign address_error_o = framebuffer_error | (|read_error) | (|write_error) | z_address_error_CRT;

//====================================================================================
//      EXECUTION POINTERS
//====================================================================================

    /* Fetch does not retire commands or consume primitives. */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i | reset_execution_i) begin
            command_pointer_o <= '0;
            primitive_pointer_o <= '0;
        end else if (initialize_i) begin
            command_pointer_o <= command_base_i;
            primitive_pointer_o <= primitive_base_i;
        end else if (!cancel) begin
            if (command_commit_i) begin
                command_pointer_o <= command_pointer_o + 32'd4;
            end

            if (primitive_valid_o & primitive_ready_i) begin
                primitive_pointer_o <= primitive_pointer_o + 32'd64;
            end
        end
    end

//====================================================================================
//      COMMAND FETCH
//====================================================================================

    logic [127:0] command_buffer, command_fill;
    logic [31:0] command_available;
    logic [2:0] command_words, command_lanes, command_fill_words;
    logic command_wait;

    assign command_available = (command_end_i - command_pointer_o) >> 2;
    assign command_lanes = 3'd4 - {1'b0, command_pointer_o[3:2]};
    assign command_o = re_command_t'(command_buffer[31:0]);
    assign command_valid_o = command_request_i & (command_words != 0) & !cancel;

    assign read_request[READ_COMMAND] = !cancel & command_request_i & !command_wait &
                                        (command_words == 0) & (command_pointer_o < command_end_i);
    assign read_address[READ_COMMAND] = {command_pointer_o[31:4], 4'b0};

    /* Ignore words before BASE and after END in the aligned DDR beat. */
    always_comb begin
        case (command_pointer_o[3:2])
            2'd0: command_fill = read_data;
            2'd1: command_fill = {32'b0, read_data[127:32]};
            2'd2: command_fill = {64'b0, read_data[127:64]};
            2'd3: command_fill = {96'b0, read_data[127:96]};
        endcase

        if (command_available < {29'b0, command_lanes}) begin
            command_fill_words = command_available[2:0];
        end else begin
            command_fill_words = command_lanes;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i | clear_fetch) begin
            command_buffer <= '0;
            command_words <= '0;
            command_wait <= 1'b0;
        end else begin
            if (read_ready[READ_COMMAND]) begin
                command_wait <= 1'b1;
            end

            if (read_response[READ_COMMAND]) begin
                command_wait <= 1'b0;

                if (!read_error[READ_COMMAND]) begin
                    command_buffer <= command_fill;
                    command_words <= command_fill_words;
                end
            end

            if (command_valid_o & command_ready_i) begin
                command_buffer <= {32'b0, command_buffer[127:32]};
                command_words <= command_words - 3'd1;
            end
        end
    end

//====================================================================================
//      PRIMITIVE FETCH
//====================================================================================

    logic [3:0][127:0] primitive_buffer;
    logic [1:0] primitive_beat;
    logic [27:0] primitive_remaining;
    logic [32:0] primitive_address;
    logic primitive_wait;

    assign primitive_o = proc_triangle_t'(primitive_buffer);
    assign primitive_address = {1'b0, primitive_pointer_o} + {27'b0, primitive_beat, 4'b0};

    assign read_request[READ_PRIMITIVE] = !cancel & (primitive_remaining != 0) &
                                          !primitive_valid_o & !primitive_wait;
    assign read_address[READ_PRIMITIVE] = primitive_address[31:0];

    /* Assemble one triangle ahead of the pipeline, least significant word first. */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i | clear_fetch) begin
            primitive_buffer <= '0;
            primitive_beat <= '0;
            primitive_remaining <= '0;
            primitive_valid_o <= 1'b0;
            primitive_wait <= 1'b0;
        end else begin
            if (draw_start_i) begin
                primitive_remaining <= draw_count_i;
            end

            if (read_ready[READ_PRIMITIVE]) begin
                primitive_wait <= 1'b1;
            end

            if (read_response[READ_PRIMITIVE]) begin
                primitive_wait <= 1'b0;

                if (!read_error[READ_PRIMITIVE]) begin
                    primitive_buffer[primitive_beat] <= read_data;
                    primitive_beat <= primitive_beat + 2'd1;

                    if (primitive_beat == 2'd3) begin
                        primitive_valid_o <= 1'b1;
                    end
                end
            end

            if (primitive_valid_o & primitive_ready_i) begin
                primitive_valid_o <= 1'b0;
                primitive_remaining <= primitive_remaining - 28'd1;
            end
        end
    end

    /* The processor validates the whole DRAW before enabling these reads. */
    // synthesis translate_off
    always_ff @(posedge clk_i) begin
        if (rst_n_i & read_ready[READ_PRIMITIVE]) begin
            assert (primitive_address + 33'd16 <= {1'b0, primitive_end_i});
        end
    end
    // synthesis translate_on

//====================================================================================
//      TEXTURE FETCH
//====================================================================================

    logic [31:0] texture_address;
    logic [9:0] texture_beat, texture_beats, texture_load_beats;
    texture_size_t texture_size;
    logic texture_wait;

    assign read_request[READ_TEXTURE] = !cancel & texture_active & !texture_wait;
    assign read_address[READ_TEXTURE] = texture_address;
    assign texture_write_data_o = read_data;
    assign texture_write_en_o = read_response[READ_TEXTURE] & !read_error[READ_TEXTURE] &
                                texture_active & !cancel;

    /* Compact source rows map to the RAM's fixed stride of eight words. */
    always_comb begin
        case (texture_size)
            TEXTURE_SIZE_8:  texture_write_address_o = {texture_beat[5:0], 3'b000};
            TEXTURE_SIZE_16: texture_write_address_o = {texture_beat[6:1], 2'b00, texture_beat[0]};
            TEXTURE_SIZE_32: texture_write_address_o = {texture_beat[7:2], 1'b0, texture_beat[1:0]};
            TEXTURE_SIZE_64: texture_write_address_o = texture_beat[8:0];
        endcase

        case (config_i.texture_size)
            TEXTURE_SIZE_8:  texture_load_beats = 10'd8;
            TEXTURE_SIZE_16: texture_load_beats = 10'd32;
            TEXTURE_SIZE_32: texture_load_beats = 10'd128;
            TEXTURE_SIZE_64: texture_load_beats = 10'd512;
        endcase
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i | clear_fetch) begin
            texture_wait <= 1'b0;
            texture_active <= 1'b0;
            texture_address <= '0;
            texture_size <= TEXTURE_SIZE_8;
            texture_beat <= '0;
            texture_beats <= '0;
            texture_done_o <= 1'b0;
        end else begin
            texture_done_o <= 1'b0;

            if (texture_start_i) begin
                texture_active <= 1'b1;
                texture_address <= texture_address_i;
                texture_size <= config_i.texture_size;
                texture_beat <= '0;
                texture_beats <= texture_load_beats;
            end

            if (read_ready[READ_TEXTURE]) begin
                texture_wait <= 1'b1;
            end

            if (read_response[READ_TEXTURE]) begin
                texture_wait <= 1'b0;

                if (!read_error[READ_TEXTURE]) begin
                    texture_address <= texture_address + 32'd16;
                    texture_beat <= texture_beat + 10'd1;

                    if ((texture_beat + 10'd1) == texture_beats) begin
                        texture_active <= 1'b0;
                        texture_done_o <= 1'b1;
                    end
                end
            end
        end
    end

//====================================================================================
//      Z BUFFER PORT
//====================================================================================

    /* For aligned A, the full-width condition A+16 <= END is exactly
     * A[31:4] < END[31:4], including an unaligned END and A=0xfffffff0.
     * Compare word indices directly so the post-mux address does not pass
     * through an increment before range validation and DDR arbitration. */
    assign z_address_valid = (z_address_i[3:0] == 0) & (z_address_i >= z_base_i) &
                            (z_address_i[31:4] < z_end_i[31:4]);

    /* The Z producer holds request, address, direction, data and mask until
     * ready. Validate this held descriptor one clock before arbitration;
     * only a checked address may reserve DDR. This separates the clear/line
     * address mux and range comparisons from the other clients' ready paths. */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i | clear_fetch) begin
            z_checked_CRT <= 1'b0;
            z_address_valid_CRT <= 1'b0;
            z_address_error_CRT <= 1'b0;
        end else begin
            z_address_error_CRT <= 1'b0;
            if (!z_request_i || z_ready_o) begin
                z_checked_CRT <= 1'b0;
            end else if (!z_checked_CRT) begin
                z_checked_CRT <= 1'b1;
                z_address_valid_CRT <= z_address_valid;
                z_address_error_CRT <= !z_address_valid;
            end
        end
    end

    assign read_request[READ_Z] = !cancel & z_request_i & !z_write_i & z_checked_CRT & z_address_valid_CRT;
    assign read_address[READ_Z] = z_address_i;

    assign write_request[WRITE_Z] = !cancel & z_request_i & z_write_i & z_checked_CRT & z_address_valid_CRT;
    assign write_address[WRITE_Z] = z_address_i;
    assign write_data[WRITE_Z] = z_write_data_i;
    assign write_mask[WRITE_Z] = z_mask_i;

    assign z_ready_o = z_checked_CRT & z_address_valid_CRT & !cancel &
                       (z_write_i ? write_ready[WRITE_Z] : read_ready[READ_Z]);
    assign z_response_o = !cancel & (read_response[READ_Z] | write_response[WRITE_Z]);
    assign z_read_data_o = read_data;

//====================================================================================
//      FRAMEBUFFER WRITER AND BLEND CACHE
//====================================================================================

    framebuffer_access framebuffer (
        .clk_i                   ( clk_i                                 ),
        .rst_n_i                 ( rst_n_i                               ),
        .abort_i                 ( framebuffer_reset                     ),
        .drain_i                 ( cancel                                ),
        .flush_i                 ( framebuffer_flush_i                   ),
        .base_i                  ( framebuffer_base_i                    ),
        .end_i                   ( framebuffer_end_i                     ),
        .viewport_size_i         ( config_i.viewport_size                ),
        .pixel_i                 ( pixel_i                               ),
        .pixel_x_i               ( pixel_x_i                             ),
        .pixel_y_i               ( pixel_y_i                             ),
        .pixel_valid_i           ( pixel_valid_i & !cancel              ),
        .pixel_ready_o           ( pixel_ready_o                         ),
        .blend_valid_i           ( blend_valid_i & !cancel              ),
        .blend_ready_o           ( blend_ready_o                         ),
        .blend_x_i               ( blend_x_i                             ),
        .blend_y_i               ( blend_y_i                             ),
        .blend_pixel_o           ( blend_pixel_o                         ),
        .blend_valid_o           ( blend_valid_o                         ),
        .blend_ready_i           ( blend_ready_i                         ),
        .idle_o                  ( framebuffer_idle_o                    ),
        .address_error_o         ( framebuffer_error                     ),
        .read_request_o          ( read_request[READ_FRAMEBUFFER]        ),
        .read_ready_i            ( read_ready[READ_FRAMEBUFFER]          ),
        .read_response_i         ( read_response[READ_FRAMEBUFFER]       ),
        .read_address_o          ( read_address[READ_FRAMEBUFFER]        ),
        .read_data_i             ( read_data                             ),
        .write_request_o         ( write_request[WRITE_FRAMEBUFFER]      ),
        .write_ready_i           ( write_ready[WRITE_FRAMEBUFFER]        ),
        .write_response_i        ( write_response[WRITE_FRAMEBUFFER]     ),
        .write_address_o         ( write_address[WRITE_FRAMEBUFFER]      ),
        .write_data_o            ( write_data[WRITE_FRAMEBUFFER]         ),
        .write_mask_o            ( write_mask[WRITE_FRAMEBUFFER]         )
    );

//====================================================================================
//      DDR ARBITERS
//====================================================================================

    memory_arbiter #(
        .CLIENTS ( 5    ),
        .WRITE   ( 1'b0 )
    ) reader (
        .clk_i      ( clk_i                  ),
        .rst_n_i    ( rst_n_i                ),
        .abort_i    ( discard_framebuffer_i  ),
        .request_i  ( read_request           ),
        .ready_o    ( read_ready             ),
        .address_i  ( read_address           ),
        .data_i     ( '0                     ),
        .mask_i     ( '0                     ),
        .response_o ( read_response          ),
        .error_o    ( read_error             ),
        .data_o     ( read_data              ),
        .idle_o     ( read_idle              ),
        .ddr        ( read_ddr               )
    );

    memory_arbiter #(
        .CLIENTS ( 2    ),
        .WRITE   ( 1'b1 )
    ) writer (
        .clk_i      ( clk_i                  ),
        .rst_n_i    ( rst_n_i                ),
        .abort_i    ( discard_framebuffer_i  ),
        .request_i  ( write_request          ),
        .ready_o    ( write_ready            ),
        .address_i  ( write_address          ),
        .data_i     ( write_data             ),
        .mask_i     ( write_mask             ),
        .response_o ( write_response         ),
        .error_o    ( write_error            ),
        .data_o     (                        ),
        .idle_o     ( write_idle             ),
        .ddr        ( write_ddr              )
    );

endmodule : memory_unit

`endif
