`ifndef TRIANGLE_MATH_PKG_SV
    `define TRIANGLE_MATH_PKG_SV

package triangle_math_pkg;

    /* Command sent from triangle setup unit */
    typedef enum logic [2:0] {
        CALC_INV_AREA, CALC_SLOPE, CALC_EDGE_INIT,
        CALC_GRAD_X, CALC_GRAD_Y, CALC_ATTR_REF
    } command_t;

    /* Operation opcode */
    typedef enum logic [1:0] {ADD, SUB, MUL, RECIP} uop_opcode_t;

    /* Source operand */
    typedef enum logic [4:0] {
        SRC_X0, SRC_X1, SRC_X2, SRC_Y0, SRC_Y1, SRC_Y2,
        SRC_A0, SRC_A1, SRC_A2, SRC_XREF, SRC_YREF,
        SRC_AREA, SRC_RECIP_AREA, SRC_SX, SRC_GX, SRC_GY,
        SRC_T0, SRC_T1, SRC_T2, SRC_UNUSED
    } operand_sel_t;

    /* Destination operand */
    typedef enum logic [1:0] {DST_T0, DST_T1, DST_T2, DST_OUT} destination_t;

    /* Terminate microprogram */
    typedef enum logic {MORE_OPS, LAST_OP} last_op_t;

    typedef struct packed {
        uop_opcode_t op;
        operand_sel_t src_a;
        operand_sel_t src_b;
        destination_t dst;
        last_op_t last;
    } microinstruction_t;

    typedef struct packed {
        logic negative;
        logic signed [7:0] exponent;
        logic [31:0] mantissa;
    } reciprocal_t;

    typedef enum logic {DEN_F8, DEN_F16} denominator_format_t;

    typedef enum logic [1:0] {
        STATUS_OK, STATUS_DIV_ZERO, STATUS_OVERFLOW, STATUS_INVALID_CMD
    } status_t;

    typedef enum logic [2:0] {IDLE, ISSUE, WAIT_RESULT, WRITEBACK, RESPONSE} state_t;

endpackage : triangle_math_pkg

`endif
