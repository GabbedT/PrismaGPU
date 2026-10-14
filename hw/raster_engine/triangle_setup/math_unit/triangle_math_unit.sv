`ifndef TRIANGLE_MATH_UNIT_SV
    `define TRIANGLE_MATH_UNIT_SV

module triangle_math_unit #(
    parameter int MULTIPLIER_LATENCY = 0
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic ready_i,

    /* Command interface */
    input logic command_valid_i,
    input command_t command_i,
    output logic command_ready_o,

    /* Viewport setup */
    input logic [9:0] viewport_width_i,
    input logic [8:0] viewport_height_i,

    /* Vertex X coordinate */
    input logic signed [18:0] x0_i,
    input logic signed [18:0] x1_i,
    input logic signed [18:0] x2_i,

    /* Vertex Y coordinate */
    input logic signed [17:0] y0_i,
    input logic signed [17:0] y1_i,
    input logic signed [17:0] y2_i,

    /* Bounding Box reference */
    input logic signed [18:0] xref_i,
    input logic signed [17:0] yref_i,

    /* General attribute */
    input logic signed [31:0] a0_i,
    input logic signed [31:0] a1_i,
    input logic signed [31:0] a2_i,

    /* Triangle area */
    input logic signed [37:0] area_i,
    input reciprocal_t recip_area_i,

    /* Slope */
    input logic signed [31:0] sx_i,

    /* Gradient */
    input logic signed [31:0] gx_i,
    input logic signed [31:0] gy_i,

    /* Output interface */
    output logic valid_o,
    output logic [87:0] result_o,
    output status_t status_o,
    output logic busy_o
);

//====================================================================================
//      PARAMETERS AND FUNCTIONS
//====================================================================================

    localparam int EDGE_ALIGN = 12;
    localparam int ATTR_ALIGN = 8;

    localparam int FINAL_SHIFT = 8;
    localparam int GRAD_RECIP_SHIFT = 38;
    localparam int SLOPE_RECIP_SHIFT = 26;


    function automatic logic fits(input logic signed [87:0] value, input int width);
        return ((value >>> (width - 1)) == 0) | ((value >>> (width - 1)) == -88'sd1);
    endfunction

    /* Check if X coordinate is inside viewport */
    function automatic logic valid_x(input logic signed [18:0] value, input logic reference_point);
        return value >= 0 & (reference_point ? value < $signed({1'b0, viewport_width_i, 8'b0}) :
                                                value <= $signed({1'b0, viewport_width_i, 8'b0}));
    endfunction

    /* Check if Y coordinate is inside viewport */
    function automatic logic valid_y(input logic signed [17:0] value, input logic reference_point);
        return value >= 0 & (reference_point ? value < $signed({1'b0, viewport_height_i, 8'b0}) :
                                                value <= $signed({1'b0, viewport_height_i, 8'b0}));
    endfunction


//====================================================================================
//      MICRO PROGRAMS
//====================================================================================

    localparam microinstruction_t PROGRAM_INV_AREA [0:0] = '{
        '{RECIP, SRC_AREA, SRC_UNUSED, DST_OUT, LAST_OP}
    };

    localparam microinstruction_t PROGRAM_SLOPE [0:3] = '{
        '{SUB, SRC_Y1, SRC_Y0, DST_T0, MORE_OPS},
        '{RECIP, SRC_T0, SRC_UNUSED, DST_T1, MORE_OPS},
        '{SUB, SRC_X1, SRC_X0, DST_T0, MORE_OPS},
        '{MUL, SRC_T0, SRC_T1, DST_OUT, LAST_OP}
    };

    localparam microinstruction_t PROGRAM_EDGE_INIT [0:2] = '{
        '{SUB, SRC_YREF, SRC_Y0, DST_T0, MORE_OPS},
        '{MUL, SRC_SX, SRC_T0, DST_T0, MORE_OPS},
        '{ADD, SRC_X0, SRC_T0, DST_OUT, LAST_OP}
    };

    localparam microinstruction_t PROGRAM_GRAD_X [0:7] = '{
        '{SUB, SRC_A1, SRC_A0, DST_T0, MORE_OPS},
        '{SUB, SRC_Y2, SRC_Y0, DST_T1, MORE_OPS},
        '{MUL, SRC_T0, SRC_T1, DST_T2, MORE_OPS},
        '{SUB, SRC_A2, SRC_A0, DST_T0, MORE_OPS},
        '{SUB, SRC_Y1, SRC_Y0, DST_T1, MORE_OPS},
        '{MUL, SRC_T0, SRC_T1, DST_T0, MORE_OPS},
        '{SUB, SRC_T2, SRC_T0, DST_T0, MORE_OPS},
        '{MUL, SRC_T0, SRC_RECIP_AREA, DST_OUT, LAST_OP}
    };

    localparam microinstruction_t PROGRAM_GRAD_Y [0:7] = '{
        '{SUB, SRC_X1, SRC_X0, DST_T0, MORE_OPS},
        '{SUB, SRC_A2, SRC_A0, DST_T1, MORE_OPS},
        '{MUL, SRC_T1, SRC_T0, DST_T2, MORE_OPS},
        '{SUB, SRC_X2, SRC_X0, DST_T0, MORE_OPS},
        '{SUB, SRC_A1, SRC_A0, DST_T1, MORE_OPS},
        '{MUL, SRC_T1, SRC_T0, DST_T0, MORE_OPS},
        '{SUB, SRC_T2, SRC_T0, DST_T0, MORE_OPS},
        '{MUL, SRC_T0, SRC_RECIP_AREA, DST_OUT, LAST_OP}
    };

    localparam microinstruction_t PROGRAM_ATTR_REF [0:5] = '{
        '{SUB, SRC_XREF, SRC_X0, DST_T0, MORE_OPS},
        '{MUL, SRC_GX, SRC_T0, DST_T2, MORE_OPS},
        '{SUB, SRC_YREF, SRC_Y0, DST_T0, MORE_OPS},
        '{MUL, SRC_GY, SRC_T0, DST_T1, MORE_OPS},
        '{ADD, SRC_T2, SRC_T1, DST_T0, MORE_OPS},
        '{ADD, SRC_A0, SRC_T0, DST_OUT, LAST_OP}
    };


//====================================================================================
//      FETCH UNIT
//====================================================================================

    logic signed [87:0] t0, t1, t2, out_data;
    command_t command_reg;
    logic [2:0] micro_pc;
    state_t state_CRT, state_NXT;
    microinstruction_t instruction;
    logic program_valid;

        /* Fetch instruction from micro program ROMs using micro PC */
        always_comb begin
            /* Default Values */
            instruction = '{RECIP, SRC_UNUSED, SRC_UNUSED, DST_OUT, LAST_OP};
            program_valid = 1'b0;

            case (command_reg)
                CALC_INV_AREA: begin
                    if ({1'b0, micro_pc} < 4'd1) begin
                        instruction = PROGRAM_INV_AREA[0];
                        program_valid = 1'b1;
                    end
                end

                CALC_SLOPE: begin
                    if ({1'b0, micro_pc} < 4'd4) begin
                        instruction = PROGRAM_SLOPE[micro_pc[1:0]];
                        program_valid = 1'b1;
                    end
                end

                CALC_EDGE_INIT: begin
                    if ({1'b0, micro_pc} < 4'd3) begin
                        instruction = PROGRAM_EDGE_INIT[micro_pc[1:0]];
                        program_valid = 1'b1;
                    end
                end

                CALC_GRAD_X: begin
                    if ({1'b0, micro_pc} < 4'd8) begin
                        instruction = PROGRAM_GRAD_X[micro_pc];
                        program_valid = 1'b1;
                    end
                end

                CALC_GRAD_Y: begin
                    if ({1'b0, micro_pc} < 4'd8) begin
                        instruction = PROGRAM_GRAD_Y[micro_pc];
                        program_valid = 1'b1;
                    end
                end

                CALC_ATTR_REF: begin
                    if ({1'b0, micro_pc} < 4'd6) begin
                        instruction = PROGRAM_ATTR_REF[micro_pc];
                        program_valid = 1'b1;
                    end
                end
            endcase
        end


//====================================================================================
//      CHECK VALIDITY
//====================================================================================

    logic coordinates_valid;

    always_comb begin
        coordinates_valid = (viewport_width_i > 0) & (viewport_width_i <= 640) &
                            (viewport_height_i > 0) & (viewport_height_i <= 480);

        case (command_i)
            CALC_INV_AREA: coordinates_valid = 1'b1;

            CALC_SLOPE: coordinates_valid &= valid_x(x0_i, 0) & valid_x(x1_i, 0) & valid_y(y0_i, 0) & valid_y(y1_i, 0);

            CALC_EDGE_INIT: coordinates_valid &= valid_x(x0_i, 0) & valid_y(y0_i, 0) & valid_y(yref_i, 1);

            CALC_GRAD_X: coordinates_valid &= valid_y(y0_i, 0) & valid_y(y1_i, 0) & valid_y(y2_i, 0);

            CALC_GRAD_Y: coordinates_valid &= valid_x(x0_i, 0) & valid_x(x1_i, 0) & valid_x(x2_i, 0);

            CALC_ATTR_REF: coordinates_valid &= valid_x(x0_i, 0) & valid_y(y0_i, 0) & valid_x(xref_i, 1) & valid_y(yref_i, 1);

            default: coordinates_valid = 1'b0;
        endcase
    end


//====================================================================================
//      ADD/SUB UNIT
//====================================================================================

    operand_sel_t add_a_sel, add_b_sel;
    logic signed [87:0] add_a, add_b;
    logic signed [88:0] add_result;
    logic subtract;

    assign add_a_sel = instruction.src_a;
    assign add_b_sel = instruction.src_b;
    assign subtract = instruction.op == SUB;

        /* Select register source */
        always_comb begin
            /* Default Value */
            add_a = '0;
            add_b = '0;

            case (add_a_sel)
                SRC_X0: add_a = 88'(x0_i) <<< EDGE_ALIGN;

                SRC_X1: add_a = 88'(x1_i);

                SRC_X2: add_a = 88'(x2_i);

                SRC_Y1: add_a = 88'(y1_i);

                SRC_Y2: add_a = 88'(y2_i);

                SRC_XREF: add_a = 88'(xref_i);

                SRC_YREF: add_a = 88'(yref_i);

                SRC_A0: add_a = 88'(a0_i) <<< ATTR_ALIGN;

                SRC_A1: add_a = 88'(a1_i);

                SRC_A2: add_a = 88'(a2_i);

                SRC_T2: add_a = t2;
            endcase

            case (add_b_sel)
                SRC_X0: add_b = 88'(x0_i);

                SRC_Y0: add_b = 88'(y0_i);

                SRC_A0: add_b = 88'(a0_i);

                SRC_T0: add_b = t0;

                SRC_T1: add_b = t1;
            endcase
        end

    /* One shared carry chain for signed addition and subtraction, with a guard bit */
    assign add_result = {add_a[87], add_a} + ({add_b[87], add_b} ^ {89{subtract}}) + 89'(subtract);


//====================================================================================
//      RECIPROCAL UNIT
//====================================================================================

    operand_sel_t recip_sel;
    reciprocal_t active_reciprocal, recip_result;
    logic signed [87:0] recip_wide;
    logic recip_req_valid, recip_req_ready, recip_resp_valid, recip_resp_ready, recip_div_zero, issue_error;
    denominator_format_t den_format;


    assign den_format = command_reg == CALC_INV_AREA ? DEN_F16 : DEN_F8;

    assign recip_sel = instruction.src_a;

        /* Select register source */
        always_comb begin
            /* Default Values */
            recip_wide = '0;

            case (recip_sel)
                SRC_AREA: recip_wide = 88'(area_i);

                SRC_T0: recip_wide = t0;
            endcase
        end

    triangle_reciprocal reciprocal_unit (
        .clk_i          ( clk_i                ),
        .rst_n_i        ( rst_n_i              ),
        .req_valid_i    ( recip_req_valid      ),
        .req_ready_o    ( recip_req_ready      ),
        .denominator_i  ( recip_wide[37:0]     ),
        .den_format_i   ( den_format           ),
        .resp_valid_o   ( recip_resp_valid     ),
        .resp_ready_i   ( recip_resp_ready     ),
        .result_o       ( recip_result         ),
        .div_zero_o     ( recip_div_zero       )
    );

    assign recip_req_valid = (state_CRT == ISSUE) & (instruction.op == RECIP) & !issue_error;
    assign recip_resp_ready = (state_CRT == WAIT_RESULT) & (instruction.op == RECIP);


//====================================================================================
//      MULTIPLY UNIT
//====================================================================================

    operand_sel_t mul_a_sel, mul_b_sel;
    logic signed [87:0] mul_a_wide, mul_b_wide;
    logic signed [86:0] mul_product;
    logic mul_req_valid, mul_req_ready, mul_resp_valid, mul_resp_ready;

    assign mul_a_sel = instruction.src_a;
    assign mul_b_sel = instruction.src_b;

        /* Select register source */
        always_comb begin
            /* Default Values */
            active_reciprocal = recip_area_i;
            mul_a_wide = '0;
            mul_b_wide = '0;

            if (command_reg == CALC_SLOPE) begin
                active_reciprocal = reciprocal_t'(t1[40:0]);
            end

            case (mul_a_sel)
                SRC_T0: mul_a_wide = t0;

                SRC_T1: mul_a_wide = t1;

                SRC_SX: mul_a_wide = 88'(sx_i);

                SRC_GX: mul_a_wide = 88'(gx_i);

                SRC_GY: mul_a_wide = 88'(gy_i);
            endcase

            case (mul_b_sel)
                SRC_T0: mul_b_wide = t0;

                SRC_T1: begin
                    if (command_reg == CALC_SLOPE) begin
                        mul_b_wide = {56'b0, active_reciprocal.mantissa};
                    end else begin
                        mul_b_wide = t1;
                    end
                end

                SRC_RECIP_AREA: begin
                    mul_b_wide = {56'b0, active_reciprocal.mantissa};
                end
            endcase
        end

    triangle_multiply_unit #(.LATENCY(MULTIPLIER_LATENCY)) multiplier_unit (
        .clk_i   ( clk_i   ),
        .rst_n_i ( rst_n_i ),

        .req_valid_i ( mul_req_valid ),
        .req_ready_o ( mul_req_ready ),

        .operand_a_i ( mul_a_wide[53:0] ),
        .operand_b_i ( mul_b_wide[32:0] ),

        .resp_valid_o ( mul_resp_valid ),
        .resp_ready_i ( mul_resp_ready ),

        .product_o ( mul_product )
    );

    assign mul_req_valid = (state_CRT == ISSUE) & (instruction.op == MUL) & !issue_error;
    assign mul_resp_ready = (state_CRT == WAIT_RESULT) & (instruction.op == MUL);


//====================================================================================
//      ERROR CHECK
//====================================================================================

    always_comb begin
        /* Check that last instruction has OUT as register */
        issue_error = !program_valid | (instruction.last == LAST_OP & instruction.dst != DST_OUT);

        /* Any instruction that is not RECIP needs to have both sources valid */
        if (instruction.op != RECIP & (instruction.src_a == SRC_UNUSED | instruction.src_b == SRC_UNUSED)) begin
            issue_error = 1'b1;
        end

        /* Check bit fit */
        if (instruction.op == MUL & (!fits(mul_a_wide, 54) | !fits(mul_b_wide, 33))) begin
            issue_error = 1'b1;
        end

        if (instruction.op == RECIP & !fits(recip_wide, 38)) begin
            issue_error = 1'b1;
        end
    end


//====================================================================================
//      RESULT MULTIPLEXER
//====================================================================================

    logic signed [87:0] write_data, raw_result, raw_result_next, scaled_result, shifted_result;
    logic signed [88:0] rounded_result, converted_result;
    logic conversion_error, converted_error, guard_bit, sticky_bit;
    logic round_increment;
    status_t raw_status, raw_status_next, write_status;
    logic signed [8:0] shift_count;
    integer output_width;


        always_comb begin
            raw_result_next = '0;
            raw_status_next = STATUS_OK;

            case (instruction.op)
                ADD, SUB: begin
                    raw_result_next = add_result[87:0];

                    if (add_result[88] != add_result[87]) begin
                        raw_status_next = STATUS_OVERFLOW;
                    end
                end

                MUL: raw_result_next = {mul_product[86], mul_product};

                RECIP: begin
                    raw_result_next = {47'b0, recip_result};

                    if (recip_div_zero) begin
                        raw_status_next = STATUS_DIV_ZERO;
                    end
                end
            endcase

            if (instruction.last == LAST_OP &&
                (command_reg == CALC_SLOPE || command_reg == CALC_GRAD_X || command_reg == CALC_GRAD_Y) &&
                active_reciprocal.negative) begin
                raw_result_next = -raw_result_next;
            end
        end

        /* Capture arithmetic before conversion. The instruction stays unchanged
        until WRITEBACK, including while a multicycle unit is busy. */
        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                raw_result <= '0;
                raw_status <= STATUS_OK;
            end else if (state_CRT == ISSUE & !issue_error & (instruction.op == ADD | instruction.op == SUB)) begin
                raw_result <= raw_result_next;
                raw_status <= raw_status_next;
            end else if (state_CRT == WAIT_RESULT &
                        ((instruction.op == MUL & mul_resp_valid) | (instruction.op == RECIP & recip_resp_valid))) begin
                raw_result <= raw_result_next;
                raw_status <= raw_status_next;
            end
        end


//====================================================================================
//      SHIFT
//====================================================================================

    always_comb begin
        /* Default Values */
        shift_count = 0;
        output_width = 88;

        if (instruction.last == LAST_OP) begin
            case (command_reg)
                CALC_SLOPE, CALC_GRAD_X, CALC_GRAD_Y: begin
                    shift_count = (command_reg == CALC_SLOPE ? 9'(SLOPE_RECIP_SHIFT) : 9'(GRAD_RECIP_SHIFT)) - 9'($signed(active_reciprocal.exponent));
                    output_width = 32;
                end

                CALC_EDGE_INIT: begin
                    shift_count = 9'(FINAL_SHIFT);
                    output_width = 24;
                end

                CALC_ATTR_REF: begin
                    shift_count = 9'(FINAL_SHIFT);
                    output_width = 44;
                end
            endcase
        end else if (instruction.op == SUB & instruction.src_b == SRC_X0) begin
            output_width = 19;
        end else if (instruction.op == SUB & instruction.src_b == SRC_Y0) begin
            output_width = 18;
        end else if (instruction.op == SUB & instruction.src_b == SRC_A0) begin
            output_width = 33;
        end
    end


//====================================================================================
//      ROUNDING
//====================================================================================

    /* For right shifts, arithmetic shift rounds toward negative infinity. The
     * guard bit is the first discarded bit; sticky ORs together all lower bits.
     * Incrementing for guard && (sticky || retained_lsb) implements nearest,
     * ties-to-even for positive and negative two's-complement values. */

    always_comb begin
        /* Default Values */
        scaled_result = raw_result;
        conversion_error = 1'b0;
        guard_bit = 1'b0;
        sticky_bit = 1'b0;

        if (shift_count > 0) begin
            if (shift_count < 88) begin
                scaled_result = raw_result >>> shift_count;
                guard_bit = raw_result[shift_count - 1];

                for (int i = 0; i < 87; i++) begin
                    if (shift_count > 9'(i + 1)) begin
                        sticky_bit |= raw_result[i];
                    end
                end
            end else begin
                /* A shift of 88 or more is below half an output LSB for any
                 * signed 88-bit input, so nearest rounding produces zero. */
                scaled_result = '0;
            end
        end else if (shift_count < 0) begin
            if (-shift_count >= 88) begin
                /* Do not let a wide left shift silently discard significant
                   bits. Any nonzero input is outside the 88-bit accumulator. */
                conversion_error = raw_result != 0;
                scaled_result = '0;
            end else begin
                scaled_result = raw_result <<< (-shift_count);
                /* Discarded bits and the new sign bit must match the old sign. */
                for (int i = 0; i < 87; i++) begin
                    if (shift_count <= 9'(i - 87)) begin
                        conversion_error |= raw_result[i] != raw_result[87];
                    end
                end
            end
        end

    end

        always_comb begin
            write_status = raw_status;

            if (converted_error || converted_result[88] != converted_result[87] || !fits(write_data, output_width)) begin
                write_status = STATUS_OVERFLOW;
            end

            if (command_reg == CALC_SLOPE && micro_pc == 0 && write_data < 0) begin
                write_status = STATUS_OVERFLOW;
            end
        end

    /* Round up when discarded bits are above half, or exactly half with an
     * odd retained result. This also selects the even value on negative ties. */
    assign rounded_result = {shifted_result[87], shifted_result} + (round_increment ? 89'd1 : 89'd0);
    assign write_data = converted_result[87:0];

        /* Register the shift and rounding decision before the increment. */
        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                shifted_result <= '0;
                round_increment <= 1'b0;
                converted_result <= '0;
                converted_error <= 1'b0;
            end else if (state_CRT == CONVERT) begin
                shifted_result <= scaled_result;
                round_increment <= guard_bit && (sticky_bit || scaled_result[0]);
                converted_error <= conversion_error;
            end else if (state_CRT == ROUND) begin
                converted_result <= rounded_result;
            end
        end


//====================================================================================
//      FSM STATE_CRT CONTROL
//====================================================================================

    assign command_ready_o = state_CRT == IDLE;
    assign valid_o = state_CRT == RESPONSE;
    assign busy_o = state_CRT != IDLE;
    assign result_o = out_data;

        always_comb begin
            state_NXT = state_CRT;

            case (state_CRT)
                IDLE: begin
                    if (command_valid_i & command_ready_o) begin
                        state_NXT = command_i > CALC_ATTR_REF || !coordinates_valid ? RESPONSE : ISSUE;
                    end
                end

                ISSUE: begin
                    if (issue_error) begin
                        state_NXT = RESPONSE;
                    end else begin
                        case (instruction.op)
                            ADD, SUB: state_NXT = CONVERT;

                            MUL: begin
                                if (mul_req_ready) begin
                                    state_NXT = WAIT_RESULT;
                                end
                            end

                            RECIP: begin
                                if (recip_req_ready) begin
                                    state_NXT = WAIT_RESULT;
                                end
                            end
                        endcase
                    end
                end

                WAIT_RESULT: begin
                    if ((instruction.op == MUL & mul_resp_valid) | (instruction.op == RECIP & recip_resp_valid)) begin
                        state_NXT = CONVERT;
                    end
                end

                CONVERT: state_NXT = ROUND;

                ROUND: state_NXT = WRITEBACK;

                WRITEBACK: begin
                    state_NXT = write_status != STATUS_OK || instruction.last == LAST_OP ? RESPONSE : ISSUE;
                end

                RESPONSE: begin
                    if (ready_i) begin
                        state_NXT = IDLE;
                    end
                end

                default: state_NXT = IDLE;
            endcase
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                state_CRT <= IDLE;
            end else begin
                state_CRT <= state_NXT;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                command_reg <= CALC_INV_AREA;
                micro_pc <= '0;
                status_o <= STATUS_OK;
                out_data <= '0;
            end else begin
                case (state_CRT)
                    IDLE: begin
                        if (command_valid_i & command_ready_o) begin
                            if (command_i > CALC_ATTR_REF) begin
                                /* Invalid command */
                                out_data <= '0;
                                status_o <= STATUS_INVALID_CMD;
                            end else if (!coordinates_valid) begin
                                /* Coordinates too big */
                                out_data <= '0;
                                status_o <= STATUS_OVERFLOW;
                            end else begin
                                command_reg <= command_i;
                                micro_pc <= '0;
                                status_o <= STATUS_OK;
                            end
                        end
                    end

                    ISSUE: begin
                        if (issue_error) begin
                            out_data <= '0;
                            status_o <= program_valid ? STATUS_OVERFLOW : STATUS_INVALID_CMD;
                        end
                    end

                    WRITEBACK: begin
                        if (write_status != STATUS_OK) begin
                            out_data <= '0;
                            status_o <= write_status;
                        end else begin
                            /* Register write */
                            case (instruction.dst)
                                DST_T0: t0 <= write_data;

                                DST_T1: t1 <= write_data;

                                DST_T2: t2 <= write_data;

                                DST_OUT: out_data <= write_data;
                            endcase

                            if (instruction.last == MORE_OPS) begin
                                /* Increment if next instruction is valid */
                                micro_pc <= micro_pc + 1'b1;
                            end
                        end
                    end
                endcase
            end
        end

endmodule : triangle_math_unit

`endif
