`ifndef RE_COMMAND_PROCESSOR_SV
    `define RE_COMMAND_PROCESSOR_SV

module command_processor (
    input logic clk_i,
    input logic rst_n_i,

    /* Execution control */
    input logic enable_i,
    input logic start_i,
    input logic stop_i,
    input logic soft_reset_i,

    /* Memory ranges */
    input logic [31:0] command_base_i,
    input logic [31:0] command_end_i,
    input logic [31:0] primitive_base_i,
    input logic [31:0] primitive_end_i,
    input logic [31:0] z_buffer_base_i,
    input logic [31:0] z_buffer_end_i,
    input logic [31:0] framebuffer_base_i,
    input logic [31:0] framebuffer_end_i,

    /* Rendering configuration */
    input raster_config_t config_i,

    /* Status and interrupt events */
    output logic busy_o,
    output logic done_o,
    output logic paused_o,
    output logic stall_o,
    output logic cmd_exhausted_o,
    output logic notify_valid_o,
    output logic [25:0] notify_id_o,
    output logic command_error_o,
    output logic config_error_o,
    output logic address_error_o,
    output logic math_error_o,

    /* Memory execution control */
    output logic memory_initialize_o,
    output logic memory_invalidate_o,
    output logic memory_abort_o,
    output logic framebuffer_discard_o,
    output logic framebuffer_flush_o,
    input logic memory_idle_i,
    input logic framebuffer_idle_i,
    input logic memory_error_i,

    /* Command fetch and retirement */
    output logic command_request_o,
    output logic command_ready_o,
    output logic command_commit_o,
    input re_command_t command_i,
    input logic command_valid_i,
    input logic [31:0] command_pointer_i,
    input logic [31:0] primitive_pointer_i,

    /* DRAW request and primitive handshake */
    output logic draw_start_o,
    output logic [27:0] draw_count_o,
    input logic primitive_valid_i,
    output logic primitive_ready_o,
    output logic triangle_valid_o,
    input logic triangle_stall_i,

    /* Pipeline status and abort */
    input logic pipeline_busy_i,
    input logic pipeline_done_i,
    input logic pipeline_error_i,
    input logic pipeline_math_error_i,
    input logic pixel_ready_i,
    output logic pipeline_abort_o,

    /* Texture load request */
    output logic texture_start_o,
    output logic [31:0] texture_address_o,
    input logic texture_done_i,

    /* Exclusive Z clear */
    output logic clear_valid_o,
    input logic clear_ready_i,
    input logic clear_done_i,
    output logic [15:0] clear_depth_o
);

//====================================================================================
//      REGISTERS
//====================================================================================

    typedef enum logic [4:0] {
        IDLE, INITIALIZE, RESUME,
        FETCH, DECODE,
        DRAW_START, DRAW_RUN, TRIANGLE_DRAIN,
        TEXTURE_START, TEXTURE_WAIT,
        CLEAR_REQUEST, CLEAR_WAIT,
        COMMIT, NOTIFY_DRAIN, NOTIFY_COMMIT, NOTIFY_REPORT,
        PAUSE_DRAIN, END_DRAIN, PAUSED, DONE,
        ERROR_DRAIN, ERROR_HALT, RESET_DRAIN
    } state_t;

    state_t state_CRT, state_NXT;
    re_command_t command_CRT, command_NXT;
    logic discard_memory_CRT, discard_memory_NXT;
    logic command_active_CRT, command_active_NXT;
    logic list_loaded_CRT, list_loaded_NXT;
    logic triangle_active_CRT, triangle_active_NXT;
    logic pause_requested_CRT, pause_requested_NXT;
    logic [27:0] remaining_CRT, remaining_NXT;
    logic [31:0] saved_command_base_CRT, saved_command_base_NXT;
    logic [31:0] saved_command_end_CRT, saved_command_end_NXT;
    logic [31:0] saved_primitive_base_CRT, saved_primitive_base_NXT;
    logic [31:0] saved_primitive_end_CRT, saved_primitive_end_NXT;
    logic command_error_CRT, command_error_NXT;
    logic config_error_CRT, config_error_NXT;
    logic address_error_CRT, address_error_NXT;
    logic math_error_CRT, math_error_NXT;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            discard_memory_CRT <= 1'b0;
            command_active_CRT <= 1'b0;
            list_loaded_CRT <= 1'b0;
            triangle_active_CRT <= 1'b0;
            pause_requested_CRT <= 1'b0;
            command_error_CRT <= 1'b0;
            config_error_CRT <= 1'b0;
            address_error_CRT <= 1'b0;
            math_error_CRT <= 1'b0;
        end else begin
            state_CRT <= state_NXT;
            discard_memory_CRT <= discard_memory_NXT;
            command_active_CRT <= command_active_NXT;
            list_loaded_CRT <= list_loaded_NXT;
            triangle_active_CRT <= triangle_active_NXT;
            pause_requested_CRT <= pause_requested_NXT;
            command_error_CRT <= command_error_NXT;
            config_error_CRT <= config_error_NXT;
            address_error_CRT <= address_error_NXT;
            math_error_CRT <= math_error_NXT;
        end
    end

    /* Payload is loaded before DECODE, DRAW_RUN or RESUME can consume it. */
    always_ff @(posedge clk_i) begin
        command_CRT <= command_NXT;
        remaining_CRT <= remaining_NXT;
        saved_command_base_CRT <= saved_command_base_NXT;
        saved_command_end_CRT <= saved_command_end_NXT;
        saved_primitive_base_CRT <= saved_primitive_base_NXT;
        saved_primitive_end_CRT <= saved_primitive_end_NXT;
    end


//====================================================================================
//      RANGE VALIDATION
//====================================================================================

    logic command_range_valid, primitive_range_valid, list_valid;
    logic framebuffer_valid, z_valid, draw_range_valid;
    logic resume_valid, draw_config_valid, draw_address_valid;
    logic [34:0] primitive_limit;
    logic [32:0] command_next, framebuffer_limit, z_limit, texture_limit;
    logic [31:0] framebuffer_bytes;
    logic [31:0] z_bytes;
    logic [13:0] texture_bytes;

        always_comb begin
            texture_bytes = 14'd128;

            case (config_i.texture_size)
                TEXTURE_SIZE_8:  begin
                    texture_bytes = 14'd128;
                end

                TEXTURE_SIZE_16: begin
                    texture_bytes = 14'd512;
                end

                TEXTURE_SIZE_32: begin
                    texture_bytes = 14'd2048;
                end

                TEXTURE_SIZE_64: begin
                    texture_bytes = 14'd8192;
                end
            endcase
        end
    
    /* Aligned command words in a forward byte range. */
    assign command_range_valid = (command_base_i[1:0] == 0) & (command_end_i[1:0] == 0) &
                                 (command_base_i <= command_end_i);

    /* Primitive base is 16-byte aligned; range size is a multiple of 64. */
    assign primitive_range_valid = (primitive_base_i[3:0] == 0) & (primitive_base_i <= primitive_end_i) &
                                 (primitive_base_i[5:0] == primitive_end_i[5:0]);

    /* FSM can start fetching valid buffers */
    assign list_valid = command_range_valid & primitive_range_valid;

    always_comb begin
        framebuffer_bytes = 32'd460800;
        z_bytes = 32'd614400;

        if (config_i.viewport_size == RE_VIEWPORT_320_240) begin
            framebuffer_bytes = 32'd115200;
            z_bytes = 32'd153600;
        end
    end

    /* Check limit and validity */
    assign framebuffer_limit = {1'b0, framebuffer_base_i} + {1'b0, framebuffer_bytes};
    assign framebuffer_valid = (framebuffer_base_i[3:0] == 0) & (framebuffer_limit <= {1'b0, framebuffer_end_i});

    assign z_limit = {1'b0, z_buffer_base_i} + {1'b0, z_bytes};
    assign z_valid = (z_buffer_base_i[3:0] == 0) & (config_i.z_buffer_address == z_buffer_base_i) &
                        (z_limit <= {1'b0, z_buffer_end_i});

    /* Keep carry bits until after range checks. */
    assign command_next = {1'b0, command_pointer_i} + 33'd4;
    assign primitive_limit = 35'(primitive_pointer_i) + (35'(command_CRT.payload.primitive_count) << 6);
    assign draw_range_valid = primitive_limit <= 35'(primitive_end_i);
    assign texture_limit = {1'b0, command_CRT.payload.address_upper, 4'b0} + {19'b0, texture_bytes};

    /* Resume keeps the command and primitive ranges unchanged. */
    assign resume_valid = (saved_command_base_CRT == command_base_i) & (saved_command_end_CRT == command_end_i) &
                            (saved_primitive_base_CRT == primitive_base_i) & (saved_primitive_end_CRT == primitive_end_i);

    assign draw_config_valid = !config_i.texture_en | config_i.perspective_correct;
    assign draw_address_valid = draw_range_valid & framebuffer_valid & (!config_i.z_test_enable | z_valid);


//====================================================================================
//      FSM LOGIC
//====================================================================================

    logic start_request, pipeline_ready;
    logic memory_fault, pipeline_fault;

    always_comb begin
        /* Register defaults */
        state_NXT = state_CRT;
        command_NXT = command_CRT;
        discard_memory_NXT = discard_memory_CRT;
        command_active_NXT = command_active_CRT;
        list_loaded_NXT = list_loaded_CRT;
        triangle_active_NXT = triangle_active_CRT;
        pause_requested_NXT = pause_requested_CRT;
        remaining_NXT = remaining_CRT;
        saved_command_base_NXT = saved_command_base_CRT;
        saved_command_end_NXT = saved_command_end_CRT;
        saved_primitive_base_NXT = saved_primitive_base_CRT;
        saved_primitive_end_NXT = saved_primitive_end_CRT;
        command_error_NXT = 1'b0;
        config_error_NXT = 1'b0;
        address_error_NXT = 1'b0;
        math_error_NXT = 1'b0;

        memory_fault = 1'b0;
        pipeline_fault = 1'b0;

        /* Output defaults */
        busy_o = 1'b1;
        done_o = 1'b0;
        paused_o = 1'b0;
        cmd_exhausted_o = list_loaded_CRT & ((command_pointer_i == command_end_i) |
                          (command_active_CRT & (command_next == {1'b0, command_end_i})));
        notify_valid_o = 1'b0;
        notify_id_o = '0;
        command_error_o = command_error_CRT;
        config_error_o = config_error_CRT;
        address_error_o = address_error_CRT;
        math_error_o = math_error_CRT;

        memory_initialize_o = 1'b0;
        memory_invalidate_o = 1'b0;
        memory_abort_o = 1'b0;
        framebuffer_discard_o = discard_memory_CRT;
        framebuffer_flush_o = 1'b0;
        command_commit_o = 1'b0;
        draw_start_o = 1'b0;
        draw_count_o = '0;
        pipeline_abort_o = 1'b0;
        texture_start_o = 1'b0;
        texture_address_o = '0;
        clear_valid_o = 1'b0;
        clear_depth_o = '0;

        start_request = start_i & enable_i & !stop_i;
        pipeline_ready = 1'b0;
        command_ready_o = 1'b0;
        command_request_o = 1'b0;
        primitive_ready_o = 1'b0;
        triangle_valid_o = 1'b0;
        stall_o = pipeline_busy_i & !pixel_ready_i;

        case (state_CRT)
            IDLE: begin
                busy_o = start_request;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (start_request) begin
                    state_NXT = INITIALIZE;

                    /* Initialize registers */
                    pause_requested_NXT = 1'b0;
                    discard_memory_NXT = 1'b0;

                    saved_command_base_NXT = command_base_i;
                    saved_command_end_NXT = command_end_i;
                    saved_primitive_base_NXT = primitive_base_i;
                    saved_primitive_end_NXT = primitive_end_i;
                end
            end

            DONE: begin
                framebuffer_flush_o = 1'b1;
                busy_o = start_request;
                done_o = 1'b1;
                memory_invalidate_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (start_request) begin
                    /* Initialize another request immediately after being done */
                    state_NXT = INITIALIZE;

                    pause_requested_NXT = 1'b0;
                    discard_memory_NXT = 1'b0;
                    
                    saved_command_base_NXT = command_base_i;
                    saved_command_end_NXT = command_end_i;
                    saved_primitive_base_NXT = primitive_base_i;
                    saved_primitive_end_NXT = primitive_end_i;
                end
            end

            PAUSED: begin
                framebuffer_flush_o = 1'b1;
                busy_o = start_request;
                paused_o = 1'b1;
                memory_invalidate_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (start_request) begin
                    state_NXT = RESUME;

                    pause_requested_NXT = 1'b0;
                    discard_memory_NXT = 1'b0;
                end
            end

            INITIALIZE: begin
                memory_initialize_o = list_valid;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                list_loaded_NXT = list_valid;

                if (!list_valid) begin
                    address_error_NXT = 1'b1;
                    state_NXT = ERROR_DRAIN;
                end else begin
                    state_NXT = FETCH;
                end
            end

            RESUME: begin
                memory_invalidate_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (!resume_valid) begin
                    config_error_NXT = 1'b1;
                    state_NXT = ERROR_DRAIN;
                end else begin
                    state_NXT = FETCH;
                end
            end

            FETCH: begin
                stall_o = stall_o | !command_valid_i;
                
                command_ready_o = enable_i & !stop_i & !pause_requested_CRT & !soft_reset_i;
                command_request_o = command_ready_o & (command_pointer_i < command_end_i);

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (command_pointer_i == command_end_i) begin
                    /* End of program */
                    state_NXT = END_DRAIN;
                end else if (pause_requested_CRT | stop_i | !enable_i) begin
                    /* Pause program */
                    state_NXT = PAUSE_DRAIN;
                end else if (command_valid_i & command_ready_o) begin
                    /* Decode current command */
                    state_NXT = DECODE;

                    command_NXT = command_i;
                    command_active_NXT = 1'b1;
                end
            end

            DECODE: begin
                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                case (command_CRT.opcode)
                    RE_CMD_DRAW: begin
                        if (command_CRT.payload.primitive_count == 0) begin
                            /* Nothing to do, no primitive to fetch */
                            state_NXT = COMMIT;
                        end else if (!draw_config_valid) begin
                            /* Invalid config, can't draw */
                            state_NXT = ERROR_DRAIN;

                            config_error_NXT = 1'b1;
                        end else if (!draw_address_valid) begin
                            /* Invalid draw address */
                            state_NXT = ERROR_DRAIN;

                            address_error_NXT = 1'b1;
                        end else begin
                            /* Start drawing N primitives */
                            state_NXT = DRAW_START;

                            remaining_NXT = command_CRT.payload.primitive_count;
                        end
                    end

                    RE_CMD_LOAD_TEXTURE: begin
                        if (texture_limit[32]) begin
                            state_NXT = ERROR_DRAIN;

                            address_error_NXT = 1'b1;
                        end else begin
                            state_NXT = TEXTURE_START;
                        end
                    end

                    RE_CMD_NOTIFY: begin
                        if (command_CRT.payload.notify.unused != 0) begin
                            /* Illegal */
                            state_NXT = ERROR_DRAIN;

                            command_error_NXT = 1'b1;
                        end else begin
                            state_NXT = NOTIFY_DRAIN;
                        end
                    end

                    RE_CMD_CLEAR_Z: begin
                        if (command_CRT.payload.clear_z.unused != 0) begin
                            state_NXT = ERROR_DRAIN;
                            
                            command_error_NXT = 1'b1;
                        end else if (!z_valid) begin
                            state_NXT = ERROR_DRAIN;

                            address_error_NXT = 1'b1;
                        end else begin
                            state_NXT = CLEAR_REQUEST;
                        end
                    end

                    default: begin
                        command_error_NXT = 1'b1;
                        state_NXT = ERROR_DRAIN;
                    end
                endcase
            end

            DRAW_START: begin
                /* Notify the memory unit to fetch N primitives */
                draw_start_o = 1'b1;
                draw_count_o = command_CRT.payload.primitive_count;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                state_NXT = DRAW_RUN;
            end

            DRAW_RUN: begin
                /* Monitor status from memory unit */
                pipeline_ready = !triangle_active_CRT & !pipeline_busy_i & !pipeline_error_i & !soft_reset_i;
                primitive_ready_o = pipeline_ready & !triangle_stall_i;
                triangle_valid_o = pipeline_ready & primitive_valid_i;

                stall_o = stall_o | (!triangle_active_CRT & (!primitive_valid_i | !primitive_ready_o));

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (primitive_valid_i & primitive_ready_o) begin
                    triangle_active_NXT = 1'b1;
                end

                if (pipeline_done_i & triangle_active_CRT) begin
                    /* Pipe has done processing a triangle */
                    state_NXT = TRIANGLE_DRAIN;

                    triangle_active_NXT = 1'b0;
                    remaining_NXT = remaining_CRT - 28'd1;
                end
            end

            TRIANGLE_DRAIN: begin
                framebuffer_flush_o = 1'b1;
                stall_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (framebuffer_idle_i & !pipeline_busy_i) begin
                    if (remaining_CRT == 0) begin
                        /* Done executing the primitive batch */
                        state_NXT = COMMIT;
                    end else begin
                        /* Draw another primitive */
                        state_NXT = DRAW_RUN;
                    end
                end
            end

            TEXTURE_START: begin
                texture_start_o = 1'b1;
                texture_address_o = {command_CRT.payload.address_upper, 4'b0};

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                state_NXT = TEXTURE_WAIT;
            end

            TEXTURE_WAIT: begin
                stall_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                /* Wait texture memory to fill */
                if (texture_done_i) begin
                    state_NXT = COMMIT;
                end
            end

            CLEAR_REQUEST: begin
                clear_valid_o = !soft_reset_i;
                clear_depth_o = command_CRT.payload.clear_z.depth;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                /* Wait for Z buffer controller to be ready */
                if (clear_ready_i) begin
                    state_NXT = CLEAR_WAIT;
                end
            end

            CLEAR_WAIT: begin
                stall_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                /* Z buffer controller has done */
                if (clear_done_i) begin
                    state_NXT = COMMIT;
                end
            end

            COMMIT: begin
                command_commit_o = !soft_reset_i;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                /* Done, fetch another command */
                if (command_commit_o) begin
                    command_active_NXT = 1'b0;
                end

                state_NXT = FETCH;
            end

            NOTIFY_DRAIN: begin
                framebuffer_flush_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                /* Wait for no activity from pipeline and memory */
                if (memory_idle_i & !pipeline_busy_i) begin
                    state_NXT = NOTIFY_COMMIT;
                end
            end

            NOTIFY_COMMIT: begin
                command_commit_o = !soft_reset_i;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (command_commit_o) begin
                    command_active_NXT = 1'b0;
                end

                state_NXT = NOTIFY_REPORT;
            end

            NOTIFY_REPORT: begin
                /* NOTIFY_ID is latched before DONE/PAUSED becomes visible. */
                notify_valid_o = !soft_reset_i;
                notify_id_o = command_CRT.payload.notify.id;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                /* If notify is the last instruction: end program, otherwise
                 * just pause it and wait for resume */
                if (command_pointer_i == command_end_i) begin
                    state_NXT = DONE;
                end else begin
                    state_NXT = PAUSED;
                end
            end

            PAUSE_DRAIN: begin
                framebuffer_flush_o = 1'b1;
                stall_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (memory_idle_i & !pipeline_busy_i) begin
                    state_NXT = PAUSED;
                end
            end

            END_DRAIN: begin
                framebuffer_flush_o = 1'b1;
                stall_o = 1'b1;

                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;

                if (memory_idle_i & !pipeline_busy_i) begin
                    state_NXT = DONE;
                end
            end

            ERROR_DRAIN: begin
                framebuffer_flush_o = 1'b1;
                memory_abort_o = 1'b1;
                pipeline_abort_o = 1'b1;

                memory_fault = memory_error_i;

                if (memory_idle_i) begin
                    state_NXT = ERROR_HALT;
                end
            end

            ERROR_HALT: begin
                busy_o = 1'b0;
                memory_abort_o = 1'b1;
                pipeline_abort_o = 1'b1;
            end

            RESET_DRAIN: begin
                memory_abort_o = 1'b1;
                pipeline_abort_o = 1'b1;
                framebuffer_discard_o = 1'b1;
                stall_o = 1'b1;

                if (memory_idle_i) begin
                    state_NXT = IDLE;
                end
            end

            default: begin
                memory_fault = memory_error_i;
                pipeline_fault = !soft_reset_i & pipeline_done_i & pipeline_error_i;
            end
        endcase

        stall_o = busy_o & stall_o;
        
        if (busy_o & (stop_i | !enable_i)) begin
            pause_requested_NXT = 1'b1;
        end


        if (memory_fault) begin
            discard_memory_NXT = 1'b1;
        end

        if (pipeline_fault | memory_fault) begin
            address_error_NXT = memory_error_i;
            config_error_NXT = !memory_error_i & !pipeline_math_error_i;
            math_error_NXT = !memory_error_i & pipeline_math_error_i;
            triangle_active_NXT = 1'b0;
            state_NXT = ERROR_DRAIN;
        end

        /* Reset wins over completion and error events; accepted DDR work drains. */
        if (soft_reset_i) begin
            memory_abort_o = 1'b1;
            pipeline_abort_o = 1'b1;
            framebuffer_discard_o = 1'b1;
            state_NXT = RESET_DRAIN;
            discard_memory_NXT = 1'b0;
            command_active_NXT = 1'b0;
            list_loaded_NXT = 1'b0;
            triangle_active_NXT = 1'b0;
            pause_requested_NXT = 1'b0;
            command_error_NXT = 1'b0;
            config_error_NXT = 1'b0;
            address_error_NXT = 1'b0;
            math_error_NXT = 1'b0;
        end
    end

endmodule : command_processor

`endif
