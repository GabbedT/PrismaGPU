`ifndef GEOMETRY_ENGINE_REGISTERS_SV
    `define GEOMETRY_ENGINE_REGISTERS_SV

module geometry_engine_registers (
    input logic clk_i,
    input logic rst_n_i,
    output logic interrupt_o,

    /* Control; command outputs are one-cycle pulses. */
    output logic enable_o,
    output logic start_processing_o,
    output logic stop_processing_o,
    output logic soft_reset_o,
    output front_face_t front_face_o,
    output cull_mode_t cull_mode_o,
    output logic forward_back_o,
    output logic enable_pcounters_o,

    /* Memory unit configuration; full 32-bit byte addresses. */
    output logic [31:0] vertex_buffer_base_o,
    output logic [31:0] vertex_buffer_end_o,
    output logic [31:0] primitive_buffer_base_o,
    output logic [31:0] primitive_buffer_end_o,

    /* Pipeline configuration */
    output logic [3:0][3:0][31:0] coefficient_o,
    output logic [31:0] width_screen_o,
    output logic [31:0] height_screen_o,

    /* Status */
    input logic busy_i,
    input logic done_i,
    input logic stall_i,
    input triangle_error_t error_i,

    /* Forwarded matrix result; RES_0..3 hold x, y, z, w. */
    input vertex_t forward_vertex_i,
    input logic forward_valid_i,

    /* Read-only counters supplied by the pipeline. */
    input logic [31:0] input_triangle_count_i,
    input logic [31:0] output_triangle_count_i,
    input logic [31:0] discarded_triangle_count_i,
    input logic [31:0] stall_cycle_count_i,

    /* Write interface; addresses are word offsets (byte address [7:2]). */
    input logic write_i,
    input logic [5:0] write_address_i,
    input logic [3:0][7:0] write_data_i,
    input logic [3:0] write_strobe_i,
    output logic write_error_o,

    /* Read interface */
    input logic read_i,
    input logic [5:0] read_address_i,
    output logic [31:0] read_data_o,
    output logic read_error_o
);

    ge_registers_t write_address, read_address;
    logic write_register, write_address_valid, read_address_valid;

    assign write_address = ge_registers_t'(write_address_i);
    assign read_address = ge_registers_t'(read_address_i);
    assign write_register = write_i & write_address_valid;

//====================================================================================
//      MASK GENERATION
//====================================================================================

    logic [3:0][7:0] mask;

        always_comb begin
            for (int i = 0; i < 4; ++i) begin
                mask[i] = write_strobe_i[i] ? '1 : '0;
            end
        end


//====================================================================================
//      ERROR CHECK
//====================================================================================

        always_comb begin
            write_address_valid = 1'b0;

            case (write_address)
                GE_CTRL, GE_VTX_BASE, GE_VTX_END, GE_PRIM_BASE, GE_PRIM_END,
                GE_IRQ_EN, GE_IRQ_PEND, GE_VP_WIDTH, GE_VP_HEIGHT: write_address_valid = 1'b1;

                default: write_address_valid = (write_address >= GE_MTX_00) & (write_address <= GE_MTX_33);
            endcase
        end

    assign read_address_valid = (read_address <= GE_VP_HEIGHT) | ((read_address >= GE_TRI_INPUT) & (read_address <= GE_STALL));

    /* Reject writes to RO registers and all accesses to reserved addresses. */
    assign write_error_o = write_i & !write_address_valid;
    assign read_error_o = read_i & !read_address_valid;


//====================================================================================
//      CONTROL REGISTER
//====================================================================================

    ge_control_t control_register, control_read;

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                control_register <= '0;
            end else begin
                control_register.start_processing <= 1'b0;
                control_register.stop_processing <= 1'b0;
                control_register.soft_reset <= 1'b0;

                if (write_register & (write_address == GE_CTRL)) begin
                    if (write_strobe_i[0]) begin
                        control_register.enable           <= write_data_i[0][0];
                        control_register.start_processing <= write_data_i[0][1];
                        control_register.stop_processing  <= write_data_i[0][2];
                        control_register.soft_reset       <= write_data_i[0][3];
                        control_register.front_face       <= front_face_t'(write_data_i[0][4]);
                        control_register.cull_mode        <= cull_mode_t'(write_data_i[0][6:5]);
                        control_register.matrix_forward   <= write_data_i[0][7];
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

    /* Enable GE pipeline */
    assign enable_o = control_register.enable;

    /* Start/stop memory fetching/storing */
    assign start_processing_o = control_register.start_processing;
    assign stop_processing_o = control_register.stop_processing;

    /* Software reset */
    assign soft_reset_o = control_register.soft_reset;

    /* Cull modes */
    assign front_face_o = control_register.front_face;
    assign cull_mode_o = control_register.cull_mode;

    /* Forward back matrix results */
    assign forward_back_o = control_register.matrix_forward;

    /* Enable performance counters */
    assign enable_pcounters_o = control_register.enable_pcounters;


//====================================================================================
//      STATUS REGISTER
//====================================================================================

    ge_status_t status_register;

        always_comb begin
            status_register = '0;
            status_register.busy = busy_i;
            status_register.done = done_i;
            status_register.stall = stall_i;
            status_register.errors = error_i;
        end


//====================================================================================
//      BUFFER REGISTERS
//====================================================================================

    logic [31:0] vertex_buffer_base, vertex_buffer_end;
    logic [31:0] primitive_buffer_base, primitive_buffer_end;

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                vertex_buffer_base <= '0;
                vertex_buffer_end <= '0;

                primitive_buffer_base <= '0;
                primitive_buffer_end <= '0;
            end else if (write_register) begin
                case (write_address)
                    GE_VTX_BASE: vertex_buffer_base <= (write_data_i & mask) | (vertex_buffer_base & ~mask);

                    GE_VTX_END: vertex_buffer_end <= (write_data_i & mask) | (vertex_buffer_end & ~mask);

                    GE_PRIM_BASE: primitive_buffer_base <= (write_data_i & mask) | (primitive_buffer_base & ~mask);

                    GE_PRIM_END: primitive_buffer_end <= (write_data_i & mask) | (primitive_buffer_end & ~mask);
                endcase
            end
        end

    assign vertex_buffer_base_o = vertex_buffer_base;
    assign vertex_buffer_end_o = vertex_buffer_end;

    assign primitive_buffer_base_o = primitive_buffer_base;
    assign primitive_buffer_end_o = primitive_buffer_end;


//====================================================================================
//      INTERRUPT REGISTERS
//====================================================================================

    logic [4:0] enable_interrupt, pending_interrupt;
    logic [4:0] status_previous, event_edge, clear_interrupt;

    /* Latch rising status bits regardless of IRQ_EN; mask only the IRQ output. */
    assign event_edge = status_register & ~status_previous;

    assign clear_interrupt = (write_register & (write_address == GE_IRQ_PEND) & write_strobe_i[0]) ?
                              write_data_i[0][4:0] : 5'b0;

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                enable_interrupt <= '0;
            end else if (write_register & (write_address == GE_IRQ_EN) & write_strobe_i[0]) begin
                enable_interrupt <= write_data_i[0][4:0];
            end
        end

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                status_previous <= '0;
                pending_interrupt <= '0;
            end else if (soft_reset_o) begin
                status_previous <= '0;
                pending_interrupt <= '0;
            end else begin
                status_previous <= status_register;

                /* Write-one-to-clear; a simultaneous new event takes priority. */
                pending_interrupt <= (pending_interrupt & ~clear_interrupt) | event_edge;
            end
        end

    assign interrupt_o = (pending_interrupt & enable_interrupt) != '0;


//====================================================================================
//      MATRIX RESULT REGISTERS
//====================================================================================

    logic [3:0][31:0] matrix_result;

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                matrix_result <= '0;
            end else if (soft_reset_o) begin
                matrix_result <= '0;
            end else if (forward_valid_i) begin
                matrix_result[0] <= forward_vertex_i.pos.x;
                matrix_result[1] <= forward_vertex_i.pos.y;
                matrix_result[2] <= forward_vertex_i.pos.z;
                matrix_result[3] <= forward_vertex_i.pos.w;
            end
        end


//====================================================================================
//      MATRIX COEFFICIENT REGISTERS
//====================================================================================

    /* GE_MTX_rc maps directly to coefficient_o[r][c], without a transpose. */
    genvar row, column;

    generate
        for (row = 0; row < 4; ++row) begin : matrix_row
            for (column = 0; column < 4; ++column) begin : matrix_column
                localparam ge_registers_t ADDRESS = ge_registers_t'(int'(GE_MTX_00) + 4 * row + column);

                always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
                    if (!rst_n_i) begin
                        coefficient_o[row][column] <= '0;
                    end else if (write_register & (write_address == ADDRESS)) begin
                        coefficient_o[row][column] <= (write_data_i & mask) | (coefficient_o[row][column] & ~mask);
                    end
                end
            end
        end
    endgenerate


//====================================================================================
//      VIEWPORT REGISTERS
//====================================================================================

    logic [31:0] viewport_width, viewport_height;

        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                viewport_width <= '0;
                viewport_height <= '0;
            end else if (write_register) begin
                if (write_address == GE_VP_WIDTH) begin
                    viewport_width <= (write_data_i & mask) | (viewport_width & ~mask);
                end

                if (write_address == GE_VP_HEIGHT) begin
                    viewport_height <= (write_data_i & mask) | (viewport_height & ~mask);
                end
            end
        end

    assign width_screen_o = viewport_width;
    assign height_screen_o = viewport_height;


//====================================================================================
//      DATA READ
//====================================================================================

        /* Reserved bits/addresses read as zero. Soft reset preserves configuration. */
        always_comb begin
            read_data_o = '0;

            case (read_address)
                GE_CTRL: read_data_o = {{23{1'b0}}, control_read};

                GE_STATUS: read_data_o = {{27{1'b0}}, status_register};

                GE_VTX_BASE: read_data_o = vertex_buffer_base;
                GE_VTX_END:  read_data_o = vertex_buffer_end;

                GE_PRIM_BASE: read_data_o = primitive_buffer_base;
                GE_PRIM_END:  read_data_o = primitive_buffer_end;

                GE_IRQ_EN:   read_data_o = {{27{1'b0}}, enable_interrupt};
                GE_IRQ_PEND: read_data_o = {{27{1'b0}}, pending_interrupt};

                GE_MTX_RES_0: read_data_o = matrix_result[0];
                GE_MTX_RES_1: read_data_o = matrix_result[1];
                GE_MTX_RES_2: read_data_o = matrix_result[2];
                GE_MTX_RES_3: read_data_o = matrix_result[3];

                GE_MTX_00: read_data_o = coefficient_o[0][0];
                GE_MTX_01: read_data_o = coefficient_o[0][1];
                GE_MTX_02: read_data_o = coefficient_o[0][2];
                GE_MTX_03: read_data_o = coefficient_o[0][3];
                GE_MTX_10: read_data_o = coefficient_o[1][0];
                GE_MTX_11: read_data_o = coefficient_o[1][1];
                GE_MTX_12: read_data_o = coefficient_o[1][2];
                GE_MTX_13: read_data_o = coefficient_o[1][3];
                GE_MTX_20: read_data_o = coefficient_o[2][0];
                GE_MTX_21: read_data_o = coefficient_o[2][1];
                GE_MTX_22: read_data_o = coefficient_o[2][2];
                GE_MTX_23: read_data_o = coefficient_o[2][3];
                GE_MTX_30: read_data_o = coefficient_o[3][0];
                GE_MTX_31: read_data_o = coefficient_o[3][1];
                GE_MTX_32: read_data_o = coefficient_o[3][2];
                GE_MTX_33: read_data_o = coefficient_o[3][3];

                GE_VP_WIDTH:  read_data_o = viewport_width;
                GE_VP_HEIGHT: read_data_o = viewport_height;

                GE_TRI_INPUT:     read_data_o = input_triangle_count_i;
                GE_TRI_OUTPUT:    read_data_o = output_triangle_count_i;
                GE_TRI_DISCARDED: read_data_o = discarded_triangle_count_i;
                GE_STALL:         read_data_o = stall_cycle_count_i;

                default: read_data_o = '0;
            endcase
        end

endmodule : geometry_engine_registers

`endif
