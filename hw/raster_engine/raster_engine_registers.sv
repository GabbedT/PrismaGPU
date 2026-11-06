`ifndef RASTER_ENGINE_REGISTERS_SV
    `define RASTER_ENGINE_REGISTERS_SV

module raster_engine_registers (
    input logic clk_i,
    input logic rst_n_i,
    output logic interrupt_o,

    /* Control; command outputs are one-cycle pulses for the external controller. */
    output logic enable_o,
    output logic passthrough_o,
    output logic start_processing_o,
    output logic stop_processing_o,
    output logic soft_reset_o,
    output logic enable_pcounters_o,

    /* Memory unit configuration; unsigned byte ranges [BASE, END). */
    output logic [31:0] command_buffer_base_o,
    output logic [31:0] command_buffer_end_o,
    output logic [31:0] primitive_buffer_base_o,
    output logic [31:0] primitive_buffer_end_o,
    output logic [31:0] z_buffer_base_o,
    output logic [31:0] z_buffer_end_o,
    output logic [31:0] framebuffer_base_o,
    output logic [31:0] framebuffer_end_o,

    /* Shared pipeline configuration, including the derived depth row pitch. */
    output raster_config_t config_o,

    /* Live controller status; busy must cover execution and all pending work. */
    input logic busy_i,
    input logic done_i,
    input logic stall_i,
    input logic paused_i,
    input logic cmd_exhausted_i,

    /* One-cycle NOTIFY completion pulse, coincident with PAUSED/DONE entry.
     * The controller asserts this only after prior work has drained. */
    input logic notify_valid_i,
    input logic [25:0] notify_id_i,

    /* Error events are captured on rising edges, independently of IRQ_EN. */
    input logic command_error_i,
    input logic config_error_i,
    input logic address_error_i,
    input logic math_error_i,

    /* Read-only execution pointers and counters supplied by the controller. */
    input logic [31:0] command_pointer_i,
    input logic [31:0] primitive_pointer_i,
    input logic [31:0] input_triangle_count_i,
    input logic [31:0] done_triangle_count_i,
    input logic [31:0] discarded_triangle_count_i,
    input logic [31:0] stall_cycle_count_i,
    input logic [31:0] output_pixel_count_i,
    input logic [31:0] z_rejected_pixel_count_i,
    input logic [31:0] busy_cycle_count_i,

    /* Write interface; addresses are word offsets (byte address [7:2]). */
    input logic write_i,
    input logic [5:0] write_address_i,
    input logic [3:0][7:0] write_data_i,
    input logic [3:0] write_strobe_i,
    output logic write_error_o,

    /* Combinational read interface, as in geometry_engine_registers. */
    input logic read_i,
    input logic [5:0] read_address_i,
    output logic [31:0] read_data_o,
    output logic read_error_o
);

    re_registers_t write_address, read_address;
    logic write_register, write_address_valid, read_address_valid;
    logic configuration_write, write_blocked;

    assign write_address = re_registers_t'(write_address_i);
    assign read_address = re_registers_t'(read_address_i);
    assign write_register = write_i & write_address_valid & !write_blocked;

//====================================================================================
//      MASK GENERATION
//====================================================================================

    logic [31:0] mask, masked_data;

    always_comb begin
        for (int i = 0; i < 4; ++i) begin
            mask[8*i +: 8] = write_strobe_i[i] ? '1 : '0;
        end
    end

    assign masked_data = write_data_i & mask;

//====================================================================================
//      ERROR CHECK
//====================================================================================

    always_comb begin
        write_address_valid = 1'b0;
        configuration_write = 1'b0;

        case (write_address)
            RE_CTRL, RE_IRQ_EN, RE_IRQ_PEND: write_address_valid = 1'b1;

            RE_CMD_BASE, RE_CMD_END, RE_PRIM_BASE, RE_PRIM_END,
            RE_ZBUF_BASE, RE_ZBUF_END, RE_FRMBUF_BEGIN, RE_FRMBUF_END, RE_DRAW_CFG, RE_Z_CFG, RE_TEX_CFG,
            RE_VP_CFG, RE_BLEND_CFG, RE_SCISSOR_X, RE_SCISSOR_Y: begin
                write_address_valid = 1'b1;
                configuration_write = 1'b1;
            end

            default: ;
        endcase
    end

    /* Keep config_o and memory bounds stable while the controller is busy.
     * CTRL and IRQ access remain available. Value validation belongs to the
     * pipeline/controller; bus errors do not create rendering error IRQs. */
    assign write_blocked = (configuration_write & busy_i) |
                           ((write_address == RE_CTRL) & write_strobe_i[0] &
                            (write_data_i[0][4] != passthrough_o) & (busy_i | paused_i));
                            
    assign read_address_valid = (read_address <= RE_BLEND_CFG) |
                                ((read_address >= RE_SCISSOR_X) & (read_address <= RE_FRMBUF_END)) |
                                ((read_address >= RE_TRI_INPUT) & (read_address <= RE_CYCLES));
    
    assign write_error_o = write_i & (!write_address_valid | write_blocked);
    assign read_error_o = read_i & !read_address_valid;


//====================================================================================
//      CONTROL REGISTER
//====================================================================================

    re_control_t control_register, control_read;

    always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
        if (!rst_n_i) begin
            control_register <= '0;
        end else begin
            control_register.start_processing <= 1'b0;
            control_register.stop_processing <= 1'b0;
            control_register.soft_reset <= 1'b0;

            if (write_register & (write_address == RE_CTRL)) begin
                if (write_strobe_i[0]) begin
                    control_register.enable <= write_data_i[0][0];
                    control_register.passthrough <= write_data_i[0][4];
                    control_register.start_processing <= write_data_i[0][1];
                    control_register.stop_processing <= write_data_i[0][2];
                    control_register.soft_reset <= write_data_i[0][3];
                end

                if (write_strobe_i[1]) begin
                    control_register.enable_pcounters <= write_data_i[1][0];
                end
            end
        end
    end

    always_comb begin
        control_read = control_register;
        control_read.start_processing = 1'b0;
        control_read.stop_processing = 1'b0;
        control_read.soft_reset = 1'b0;
    end

    assign enable_o = control_register.enable;
    assign passthrough_o = control_register.passthrough;
    assign start_processing_o = control_register.start_processing;
    assign stop_processing_o = control_register.stop_processing;
    assign soft_reset_o = control_register.soft_reset;
    assign enable_pcounters_o = control_register.enable_pcounters;


//====================================================================================
//      STATUS AND INTERRUPT REGISTERS
//====================================================================================

    re_status_t status_register;
    logic [25:0] notify_id;
    re_irq_t enable_interrupt, pending_interrupt;
    re_irq_t event_source, event_previous, event_edge, clear_interrupt;

        always_comb begin
            status_register = '0;
            status_register.notify_id = notify_id;
            status_register.busy = busy_i;
            status_register.done = done_i;
            status_register.stall = stall_i;
            status_register.paused = paused_i;
            status_register.cmd_exhausted = cmd_exhausted_i;
            status_register.error = pending_interrupt.command_error | pending_interrupt.config_error |
                                    pending_interrupt.address_error | pending_interrupt.math_error;

            event_source = '0;
            event_source.done = done_i;
            event_source.paused = paused_i;
            event_source.command_error = command_error_i;
            event_source.config_error = config_error_i;
            event_source.address_error = address_error_i;
            event_source.math_error = math_error_i;
        end

    assign event_edge = event_source & ~event_previous;
    assign clear_interrupt = (write_register & (write_address == RE_IRQ_PEND) & write_strobe_i[0]) ? re_irq_t'(write_data_i[0][5:0]) : re_irq_t'('0);

    always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
        if (!rst_n_i) begin
            notify_id <= '0;
        end else if (soft_reset_o) begin
            notify_id <= '0;
        end else if (notify_valid_i) begin
            notify_id <= notify_id_i;
        end
    end


        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                enable_interrupt <= '0;
            end else if (write_register & (write_address == RE_IRQ_EN) & write_strobe_i[0]) begin
                enable_interrupt <= re_irq_t'(write_data_i[0][5:0]);
            end
        end

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                event_previous <= '0;
                pending_interrupt <= '0;
            end else if (soft_reset_o) begin
                event_previous <= '0;
                pending_interrupt <= '0;
            end else begin
                event_previous <= event_source;

                /* W1C; a simultaneous new event takes priority. */
                pending_interrupt <= (pending_interrupt & ~clear_interrupt) | event_edge;
            end
        end

    assign interrupt_o = (pending_interrupt & enable_interrupt) != '0;


//====================================================================================
//      BUFFER REGISTERS
//====================================================================================

    logic [31:0] command_buffer_base, command_buffer_end;
    logic [31:0] primitive_buffer_base, primitive_buffer_end;
    logic [31:0] z_buffer_base, z_buffer_end;
    logic [31:0] framebuffer_base, framebuffer_end;

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                command_buffer_base <= '0;
                command_buffer_end <= '0;
                primitive_buffer_base <= '0;
                primitive_buffer_end <= '0;
                z_buffer_base <= '0;
                z_buffer_end <= '0;
                framebuffer_base <= '0;
                framebuffer_end <= '0;
            end else if (write_register) begin
                case (write_address)
                    RE_FRMBUF_BEGIN: framebuffer_base <= masked_data | (framebuffer_base & ~mask);
                    RE_FRMBUF_END: framebuffer_end <= masked_data | (framebuffer_end & ~mask);
                    RE_CMD_BASE: command_buffer_base <= masked_data | (command_buffer_base & ~mask);
                    
                    RE_CMD_END: command_buffer_end <= masked_data | (command_buffer_end & ~mask);
                    
                    RE_PRIM_BASE: primitive_buffer_base <= masked_data | (primitive_buffer_base & ~mask);
                    
                    RE_PRIM_END: primitive_buffer_end <= masked_data | (primitive_buffer_end & ~mask);
                    
                    RE_ZBUF_BASE: z_buffer_base <= masked_data | (z_buffer_base & ~mask);
                    
                    RE_ZBUF_END: z_buffer_end <= masked_data | (z_buffer_end & ~mask);
                    
                    default: ;
                endcase
            end
        end

    assign command_buffer_base_o = command_buffer_base;
    assign command_buffer_end_o = command_buffer_end;
    assign primitive_buffer_base_o = primitive_buffer_base;
    assign primitive_buffer_end_o = primitive_buffer_end;
    assign z_buffer_base_o = z_buffer_base;
    assign z_buffer_end_o = z_buffer_end;
    assign framebuffer_base_o = framebuffer_base;
    assign framebuffer_end_o = framebuffer_end;

//====================================================================================
//      RENDERING CONFIGURATION REGISTERS
//====================================================================================

    re_draw_config_t draw_config;
    logic [4:0] blend_config;
    re_z_config_t z_config;
    re_texture_config_t texture_config;
    re_scissor_x_t scissor_x;
    re_scissor_y_t scissor_y;
    re_viewport_config_t viewport_config;

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                draw_config <= '0;
                blend_config <= '0;
                z_config <= '0;
                texture_config <= '0;
                scissor_x <= '0;
                scissor_y <= '0;
                viewport_config <= '0;
            end else if (write_register) begin
                case (write_address)
                    RE_DRAW_CFG: draw_config <= re_draw_config_t'(masked_data[4:0] | (draw_config & ~mask[4:0]));
                    
                    RE_BLEND_CFG: blend_config <= masked_data[4:0] | (blend_config & ~mask[4:0]);

                    RE_Z_CFG: z_config <= re_z_config_t'(masked_data[4:0] | (z_config & ~mask[4:0]));
                    
                    RE_TEX_CFG: texture_config <= re_texture_config_t'(masked_data[1:0] | (texture_config & ~mask[1:0]));
                    
                    RE_VP_CFG: viewport_config <= re_viewport_config_t'(masked_data[0] | (viewport_config & ~mask[0]));

                    RE_SCISSOR_X: begin
                        scissor_x.xmin <= masked_data[9:0] | (scissor_x.xmin & ~mask[9:0]);
                        scissor_x.xmax <= masked_data[25:16] | (scissor_x.xmax & ~mask[25:16]);
                    end

                    RE_SCISSOR_Y: begin
                        scissor_y.ymin <= masked_data[8:0] | (scissor_y.ymin & ~mask[8:0]);
                        scissor_y.ymax <= masked_data[24:16] | (scissor_y.ymax & ~mask[24:16]);
                    end

                    default: ;
                endcase
            end
        end

    always_comb begin
        config_o = '0;
        config_o.blend_enable = blend_config[4];
        config_o.blend_alpha = blend_config[3:0];
        config_o.gouraud_shading = draw_config.gouraud_shading;
        config_o.texture_en = draw_config.texture_en;
        config_o.perspective_correct = draw_config.perspective_correct;
        config_o.z_interpolation = draw_config.z_interpolation;
        config_o.scissor_enable = draw_config.scissor_enable;
        config_o.scissor_xmin = scissor_x.xmin;
        config_o.scissor_xmax = scissor_x.xmax;
        config_o.scissor_ymin = scissor_y.ymin;
        config_o.scissor_ymax = scissor_y.ymax;
        config_o.texture_size = texture_config.texture_size;
        config_o.z_test_enable = z_config.z_test_enable;
        config_o.z_write_enable = z_config.z_write_enable;
        config_o.z_compare = z_config.z_compare;
        config_o.z_buffer_address = z_buffer_base;

        config_o.viewport_size = viewport_config.viewport_size;
    end


//====================================================================================
//      DATA READ
//====================================================================================

    /* Unused bits/addresses read as zero. Soft reset preserves configuration.
     * Runtime inputs are live: their reset and counting belong to their owner. */
    always_comb begin
        read_data_o = '0;

        case (read_address)
            RE_CTRL: read_data_o = control_read;
            
            RE_STATUS: read_data_o = status_register;
            
            RE_FRMBUF_BEGIN: read_data_o = framebuffer_base;
            
            RE_FRMBUF_END: read_data_o = framebuffer_end;
            
            RE_CMD_BASE: read_data_o = command_buffer_base;
            
            RE_CMD_END: read_data_o = command_buffer_end;
            
            RE_PRIM_BASE: read_data_o = primitive_buffer_base;

            RE_PRIM_END: read_data_o = primitive_buffer_end;
            
            RE_IRQ_EN: read_data_o = enable_interrupt;

            RE_IRQ_PEND: read_data_o = pending_interrupt;
            
            RE_ZBUF_BASE: read_data_o = z_buffer_base;

            RE_ZBUF_END: read_data_o = z_buffer_end;
            
            RE_DRAW_CFG: read_data_o = draw_config;

            RE_BLEND_CFG: read_data_o = blend_config;

            RE_Z_CFG: read_data_o = z_config;
            
            RE_TEX_CFG: read_data_o = texture_config;

            RE_VP_CFG: read_data_o = viewport_config;
            
            RE_SCISSOR_X: read_data_o = scissor_x;
            
            RE_SCISSOR_Y: read_data_o = scissor_y;
            
            RE_CMD_PTR: read_data_o = command_pointer_i;
            
            RE_PRIM_PTR: read_data_o = primitive_pointer_i;
            
            RE_TRI_INPUT: read_data_o = input_triangle_count_i;
            
            RE_TRI_DONE: read_data_o = done_triangle_count_i;
            
            RE_TRI_DISCARDED: read_data_o = discarded_triangle_count_i;
            
            RE_STALL: read_data_o = stall_cycle_count_i;
            
            RE_PIXEL_OUTPUT: read_data_o = output_pixel_count_i;
            
            RE_PIXEL_Z_REJECT: read_data_o = z_rejected_pixel_count_i;
            
            RE_CYCLES: read_data_o = busy_cycle_count_i;
            
            default: read_data_o = '0;
        endcase
    end

endmodule : raster_engine_registers

`endif
