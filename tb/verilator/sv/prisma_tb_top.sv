module prisma_tb_top (
    input logic clk_i,
    input logic rst_n_i,
    input logic reg_write_i,
    input logic [6:0] reg_write_address_i,
    input logic [31:0] reg_write_data_i,
    input logic [3:0] reg_write_strobe_i,
    output logic reg_write_error_o,
    input logic reg_read_i,
    input logic [6:0] reg_read_address_i,
    output logic [31:0] reg_read_data_o,
    output logic reg_read_error_o,
    input logic [31:0] latency_i,
    input logic [31:0] gap_i,
    input logic [31:0] seed_i,
    input logic frame_begin_i,
    output logic frame_complete_o,
    output logic [31:0] framebuffer_base_o,
    output logic viewport_small_o,
    output logic busy_o,
    output logic interrupt_o
);

//====================================================================================
//      GPU AND EXTERNAL INTERFACES
//====================================================================================

    localparam int MEMORY_BYTES = 8 * 1024 * 1024;
    logic done, ge_done, ge_write, ge_read, ge_idle, stream_end;
    logic [31:0] vertex_base, vertex_end, primitive_base, primitive_end;
    logic [127:0] input_word, output_word;
    logic [4:0] input_count, output_count;
    logic [31:0] source, source_end, destination, destination_end, ge_delay;
    logic dma_active, dma_started, dma_forward, output_pending;
    logic read_pending, write_pending;
    gpu_ddr_interface read_ddr(), write_ddr();

    prismaGPU dut (
        .clk_i                   ( clk_i                                  ),
        .rst_n_i                 ( rst_n_i                                ),
        .interrupt_o             ( interrupt_o                            ),
        .busy_o                  ( busy_o                                 ),
        .done_o                  ( done                                   ),
        .reg_write_i             ( reg_write_i                            ),
        .reg_write_address_i     ( reg_write_address_i                    ),
        .reg_write_data_i        ( reg_write_data_i                       ),
        .reg_write_strobe_i      ( reg_write_strobe_i                     ),
        .reg_write_error_o       ( reg_write_error_o                      ),
        .reg_read_i              ( reg_read_i                             ),
        .reg_read_address_i      ( reg_read_address_i                     ),
        .reg_read_data_o         ( reg_read_data_o                        ),
        .reg_read_error_o        ( reg_read_error_o                       ),
        .vertex_buffer_base_o    ( vertex_base                            ),
        .vertex_buffer_end_o     ( vertex_end                             ),
        .primitive_buffer_base_o ( primitive_base                         ),
        .primitive_buffer_end_o  ( primitive_end                          ),
        .ge_done_i               ( ge_done                                ),
        .write_i                 ( ge_write                               ),
        .write_data_i            ( input_word                             ),
        .input_word_count_o      ( input_count                            ),
        .read_i                  ( ge_read                                ),
        .read_data_o             ( output_word                            ),
        .output_word_count_o     ( output_count                           ),
        .stream_end_i            ( stream_end                             ),
        .read_ddr                ( read_ddr                               ),
        .write_ddr               ( write_ddr                              )
    );

    gpu_memory #(.BYTES(MEMORY_BYTES)) memory_model (
        .clk_i              ( clk_i           ),
        .rst_n_i            ( rst_n_i         ),
        .latency_i          ( latency_i       ),
        .gap_i              ( gap_i           ),
        .seed_i             ( seed_i          ),
        .ge_read_address_i  ( source          ),
        .ge_read_data_o     ( input_word      ),
        .ge_write_i         ( output_pending  ),
        .ge_write_address_i ( destination     ),
        .ge_write_data_i    ( output_word     ),
        .read_pending_o     ( read_pending    ),
        .write_pending_o    ( write_pending   ),
        .rd                 ( read_ddr        ),
        .wr                 ( write_ddr       )
    );

//====================================================================================
//      GE MEMORY AGENT
//====================================================================================

    /* Start/stop follows the real GE control register. FIFO reads are synchronous;
     * output_pending writes the registered word on the following rising edge. */
    assign ge_idle = dut.ge_idle;
    assign stream_end = dma_started && dma_forward && source == source_end;
    assign ge_write = dma_active && dut.ge.processing && dut.ge.enable &&
                      !dut.ge.stop_processing && !dut.ge.soft_reset &&
                      source < source_end && input_count < 16 && ge_delay == 0;
    assign ge_read = dma_active && !dma_forward && output_count != 0 &&
                     !output_pending && !dut.ge.soft_reset;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i || dut.ge.soft_reset) begin
            dma_active <= 1'b0;
            dma_started <= 1'b0;
            dma_forward <= 1'b0;
            output_pending <= 1'b0;
            ge_done <= 1'b0;
            source <= '0;
            source_end <= '0;
            destination <= '0;
            destination_end <= '0;
            ge_delay <= '0;
        end else begin
            output_pending <= ge_read;
            if (ge_delay != 0) ge_delay <= ge_delay - 1;
            if (ge_write) begin
                source <= source + 16;
                ge_delay <= latency_i + gap_i;
            end
            if (output_pending) begin
                assert (destination <= destination_end && destination_end - destination >= 16)
                    else $fatal(1, "Primitive buffer overflow at %h (end %h)", destination, destination_end);
                destination <= destination + 16;
            end
            if (dma_active && source == source_end && ge_idle && output_count == 0 &&
                !dut.ge.packer.triangle_valid && dut.ge.packer.triangle_count == 0 && !output_pending) begin
                dma_active <= 1'b0;
                ge_done <= 1'b1;
            end
            if (dut.ge.start_processing && !dma_active) begin
                assert (vertex_base[3:0] == 0 && vertex_base <= vertex_end && vertex_end <= MEMORY_BYTES &&
                        ((vertex_end - vertex_base) % 64) == 0)
                    else $fatal(1, "Invalid GE input range");
                assert (primitive_base[3:0] == 0 && primitive_base <= primitive_end && primitive_end <= MEMORY_BYTES)
                    else $fatal(1, "Invalid GE output range");
                dma_active <= 1'b1;
                dma_started <= 1'b1;
                dma_forward <= dut.ge.raster_forward;
                ge_done <= 1'b0;
                source <= vertex_base;
                source_end <= vertex_end;
                destination <= primitive_base;
                destination_end <= primitive_end;
                ge_delay <= latency_i;
            end
        end
    end

//====================================================================================
//      FRAME COMPLETION AND PERFORMANCE EVENTS
//====================================================================================

    logic frame_active, done_previous, frame_end;
    logic [45:0][31:0] events;
    assign framebuffer_base_o = dut.re.fb_base;
    assign viewport_small_o = dut.re.config_data.viewport_size;
    assign frame_end = frame_active && done && !done_previous;
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            frame_active <= 1'b0;
            done_previous <= 1'b0;
            frame_complete_o <= 1'b0;
        end else begin
            done_previous <= done;
            frame_complete_o <= frame_end;
            if (frame_begin_i) begin
                assert (!frame_active) else $fatal(1, "Frame begun before previous completion");
                frame_active <= 1'b1;
            end
            if (frame_end) begin
                assert (!dut.re.pipe_busy && !dut.re.blend_busy && dut.re.memory_idle && !read_pending && !write_pending)
                    else $fatal(1, "Frame completion before memory writeback");
                frame_active <= 1'b0;
            end
        end
    end

    always_comb begin
        events = '0;
        events[0] = 1;
        events[1] = busy_o;
        events[2] = dut.ge.busy;
        events[3] = dut.re.busy;
        events[4] = ge_write;
        events[5] = output_pending;
        events[6] = dut.ge.vertex_valid && !dut.ge.unpacker_stall;
        events[7] = dut.ge.pipeline.matrix_valid && !dut.ge.pipeline.stall_o;
        events[8] = dut.ge.pipeline.clip_valid && !dut.ge.pipeline.clip_stall;
        events[9] = dut.ge.pipeline.perspective_valid && !dut.ge.pipeline.perspective_stall;
        events[10] = dut.ge.pipeline.viewport_valid && !dut.ge.pipeline.viewport_stall;
        events[11] = dut.ge.triangle_valid && !dut.ge.pipeline_stall;
        events[12] = dut.ge.pipeline.clip_discard;
        events[13] = dut.ge.pipeline.cull_discard && !dut.ge.pipeline_stall;
        events[14] = dut.re.triangle_valid && !dut.re.triangle_stall;
        events[15] = dut.re.pipe_done;
        events[16] = dut.re.pipe_done && dut.re.pipe_discard;
        events[17] = dut.re.pixel_valid && dut.re.pixel_ready;
        events[18] = dut.re.pipe_z_reject;
        events[19] = !ge_idle && dut.ge.raster_forward && dut.raster_stall;
        events[20] = dut.ge.busy && !dut.ge.raster_forward && dut.ge.packer_stall;
        events[21] = dma_active && source < source_end && input_count == 16;
        events[22] = !dut.re.pipeline.setup_ready;
        events[23] = dut.re.pipeline.state_CRT == dut.re.pipeline.RASTER;
        events[24] = dut.re.pixel_valid && !dut.re.pixel_ready;
        events[25] = read_ddr.trx_req && read_ddr.ready;
        events[26] = write_ddr.trx_req && write_ddr.ready;
        events[27] = read_ddr.trx_req && !read_ddr.ready;
        events[28] = write_ddr.trx_req && !write_ddr.ready;
        events[29] = read_pending;
        events[30] = write_pending;
        events[31] = (write_ddr.trx_req && write_ddr.ready) ? $countones(write_ddr.wstrobe) : 0;
        events[32] = ge_write ? 16 : 0;
        events[33] = output_pending ? 16 : 0;
        events[34] = reg_read_i;
        events[35] = reg_write_i;
        events[36] = (read_ddr.read_valid && read_ddr.read_error) || (write_ddr.write_valid && write_ddr.write_error);
        events[37] = dut.re.pipe_done && dut.re.pipe_error;
        events[38] = dut.ge.error != TRIANGLE_NO_ERROR;
        events[39] = frame_end;
        events[40] = dut.re.blend_request && dut.re.blend_request_ready;
        events[41] = dut.re.blend_busy;
        events[42] = dut.re.texture_write;
        events[43] = dut.re.framebuffer_valid && dut.re.framebuffer_ready;
        events[44] = !dut.re.pipeline.setup_ready && !dut.re.pipeline.setup_valid;
        events[45] = dut.re.pipeline.setup_valid && !dut.re.pipeline.setup_accept;
    end

    perf_counter counters (
        .clk_i         ( clk_i         ),
        .rst_n_i       ( rst_n_i       ),
        .frame_begin_i ( frame_begin_i ),
        .frame_end_i   ( frame_end     ),
        .events_i      ( events        )
    );

    always @(posedge clk_i) begin
        if (rst_n_i && dut.re.pipeline.setup_accept &&
            (dut.re.pipeline.setup_status == SETUP_INVALID_CONFIG ||
             dut.re.pipeline.setup_status == SETUP_MATH_ERROR)) begin
            $display("[SETUP] status=%0d math=%0d command=%0d triangle=%h",
                dut.re.pipeline.setup_status, dut.re.pipeline.setup_math_status,
                dut.re.pipeline.setup_transform.math_command_CRT,
                dut.re.pipeline.setup_transform.triangle_CRT);
        end
    end

    export "DPI-C" function gpu_debug_state;
    function string gpu_debug_state();
        return $sformatf("GE src=%h end=%h fifo=%0d idle=%b DMA=%b done=%b | RE cmd=%0d pipe=%0d setup=%0d input=%0d done=%0d pixels=%0d spans=%0d active=%b finished=%b depth=%b/%b fragments=%0d tail=%b/%0d FB=%0d DDR=%b/%b",
            source, source_end, input_count, ge_idle, dma_active, ge_done,
            dut.re.commands.state_CRT, dut.re.pipeline.state_CRT, dut.re.pipeline.setup_transform.state_CRT,
            dut.re.triangles_in, dut.re.triangles_done, dut.re.pixels,
            dut.re.pipeline.span_count, dut.re.pipeline.span_active, dut.re.pipeline.raster_finished,
            dut.re.pipeline.depth_started, dut.re.pipeline.depth_finished,
            dut.re.pipeline.fragments_pending, dut.re.pipeline.tail_active_CRT, dut.re.pipeline.tail_remaining_CRT,
            dut.re.memory.framebuffer.state, read_pending, write_pending);
    endfunction

endmodule : prisma_tb_top
