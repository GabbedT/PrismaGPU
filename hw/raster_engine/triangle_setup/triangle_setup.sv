`ifndef TRIANGLE_SETUP_SV
    `define TRIANGLE_SETUP_SV

module triangle_setup #(
    parameter bit REGISTER_MATH_INPUTS = 1'b0,
    parameter int MULTIPLIER_LATENCY = 0
) (
    input logic clk_i,
    input logic rst_n_i,

    /* Triangle input */
    input logic triangle_valid_i,
    output logic triangle_ready_o,
    input proc_triangle_t triangle_i,

    /* Interpolation */
    input logic gouraud_shading_i,
    input logic texture_i,
    input logic perspective_correct_i,
    input logic z_interpolation_i,

    /* Viewport setup */
    input logic [9:0] viewport_width_i,
    input logic [8:0] viewport_height_i,

    /* Scissor */
    input logic scissor_enable_i,
    input logic [9:0] scissor_xmin_i,
    input logic [9:0] scissor_xmax_i,
    input logic [8:0] scissor_ymin_i,
    input logic [8:0] scissor_ymax_i,


    /* Output interface */
    output logic setup_valid_o,
    input logic setup_ready_i,

    /* Bounding box */
    output logic [9:0] bb_x_start_o,
    output logic [9:0] bb_x_end_o,
    output logic [8:0] bb_y_start_o,
    output logic [8:0] bb_y_end_o,

    /* Edges */
    output setup_edge_t edge_tm_o,
    output setup_edge_t edge_tb_o,
    output setup_edge_t edge_mb_o,

    /* Attribute planes */
    output setup_attribute_t [3:0] attr_o,
    output setup_color_plane_t [2:0] color_o,
    output logic [6:0] attr_valid_o,

    /* Original colors */
    output logic [2:0][3:0] alpha_o,
    output logic [3:0] flat_r_o,
    output logic [3:0] flat_g_o,
    output logic [3:0] flat_b_o,

    /* Rendering */
    output logic gouraud_shading_o,
    output logic texture_o,
    output logic perspective_correct_o,

    /* Status */
    output setup_status_t setup_status_o,
    output status_t math_status_o,
    output logic setup_error_o,
    output logic setup_discard_o,
    output logic busy_o
);


//====================================================================================
//      PARAMETERS AND FUNCTIONS
//====================================================================================

    localparam logic [1:0] VERTEX_0 = 0, VERTEX_1 = 1, VERTEX_2 = 2;
    localparam logic [1:0] EDGE_TM = 0, EDGE_TB = 1, EDGE_MB = 2;
    localparam int COLOR_SHIFT = 4;

    typedef enum logic [3:0] {
        IDLE, VALIDATE, MIN_MAX_ORDER, BBOX, EDGE_PREP, NEXT_EDGE,
        ATTR_SELECT, MATH_PREP, MATH_REQUEST, MATH_WAIT, OUTPUT
    } setup_state_t;

    /* Coordinates have F8; the half-pixel boundary belongs to the lower row */
    function automatic logic signed [9:0] ceil_y(input logic signed [17:0] value);
        return 10'(value >>> 8) + 10'(value[7:0] > 8'h80);
    endfunction

    /* Decode positive 1/w to F16; retain 48 bits to check overflow before narrowing */
    function automatic logic [47:0] decode_w(input inv_w_t value);
        logic [47:0] result;
        logic guard_bit, sticky_bit;
        integer shift_count;

        /* Default Values */
        result = {30'b0, value.mantissa};
        guard_bit = 1'b0;
        sticky_bit = 1'b0;
        shift_count = 1 - int'($signed(value.exponent));

        if (shift_count > 0) begin
            result = result >> shift_count;
            if (shift_count <= 18) begin
                guard_bit = value.mantissa[shift_count - 1];
                for (int i = 0; i < 18; i++) begin
                    if (i < shift_count - 1) begin
                        sticky_bit |= value.mantissa[i];
                    end
                end
            end
            result = result + ((guard_bit && (sticky_bit || result[0])) ? 48'd1 : 48'd0);
        end else begin
            result = result << (-shift_count);
        end

        return result;
    endfunction

    function automatic logic signed [31:0] attribute_value(input proc_vertex_t vertex_data, input logic [31:0] inv_w, input logic [2:0] slot);
        case (int'(slot))
            ATTR_Z: return {15'b0, vertex_data.pos.z};

            ATTR_R: return {12'b0, vertex_data.col.r, 16'b0};

            ATTR_G: return {12'b0, vertex_data.col.g, 16'b0};

            ATTR_B: return {12'b0, vertex_data.col.b, 16'b0};

            ATTR_TEX_U: return $signed(vertex_data.tex.u);

            ATTR_TEX_V: return $signed(vertex_data.tex.v);

            ATTR_INV_W: return $signed(inv_w[31:0]);

            default: return '0;
        endcase
    endfunction


//====================================================================================
//      TRANSACTION REGISTERS AND VALIDATION
//====================================================================================

    setup_state_t state_CRT, state_NXT;
    setup_status_t setup_status_CRT, setup_status_NXT;

    status_t math_status_CRT, math_status_NXT;
    command_t math_command_CRT, math_command_NXT;

    proc_triangle_t triangle_CRT, triangle_NXT;

    logic [9:0] viewport_width_CRT, viewport_width_NXT;
    logic [8:0] viewport_height_CRT, viewport_height_NXT;

    logic scissor_enable_CRT, scissor_enable_NXT;
    logic [9:0] scissor_xmin_CRT, scissor_xmin_NXT;
    logic [9:0] scissor_xmax_CRT, scissor_xmax_NXT;
    logic [8:0] scissor_ymin_CRT, scissor_ymin_NXT;
    logic [8:0] scissor_ymax_CRT, scissor_ymax_NXT;

    setup_edge_t [2:0] edge_CRT, edge_NXT;
    logic [1:0] edge_idx_CRT, edge_idx_NXT;
    logic [2:0][1:0] order_CRT, order_NXT;
    reciprocal_t recip_area_CRT, recip_area_NXT;
    logic parity_CRT, parity_NXT;

    logic gouraud_shading_CRT, gouraud_shading_NXT;
    logic texture_CRT, texture_NXT;
    logic perspective_correct_CRT, perspective_correct_NXT;

    logic config_max_valid;
    logic [2:0] config_valid, inv_w_invalid, inv_w_range;
    logic [2:0][47:0] decoded_w;

    /* Check validity withing max viewport coordinates */
    assign config_max_valid = (viewport_width_CRT > 0) & (viewport_width_CRT <= 640) &
                              (viewport_height_CRT > 0) & (viewport_height_CRT <= 480) & 
                             !(texture_o & !perspective_correct_o);

    always_comb begin
        /* Default Values */
        inv_w_invalid = 3'b0;
        inv_w_range = 3'b0;

        for (int i = 0; i < 3; i++) begin
            /* Convert to F16 format */
            decoded_w[i] = decode_w(triangle_CRT.vtx[i].pos.w);

            /* Check coordinates validity against current viewport */
            config_valid[i] = (triangle_CRT.vtx[i].pos.x >= 0) & (triangle_CRT.vtx[i].pos.x <= $signed({1'b0, viewport_width_CRT, 8'b0})) &
                              (triangle_CRT.vtx[i].pos.y >= 0) & (triangle_CRT.vtx[i].pos.y <= $signed({1'b0, viewport_height_CRT, 8'b0}));
            
            /* Check W validity */
            if (texture_o & perspective_correct_o) begin
                inv_w_invalid[i] = triangle_CRT.vtx[i].pos.w.mantissa == 0;
                inv_w_range[i] = (decoded_w[i] == 0) | (decoded_w[i] > 48'h7fffffff);
            end
        end
    end


//====================================================================================
//      MIN/MAX AND VERTEX ORDER
//====================================================================================

    logic [2:0][1:0] order_next;
    logic [2:0] y_order;
    logic parity_next;
    logic signed [18:0] xmin_next, xmax_next;

    logic signed [18:0] xmin_CRT, xmin_NXT;
    logic signed [18:0] xmax_CRT, xmax_NXT;
    logic signed [17:0] ymin_CRT, ymin_NXT;
    logic signed [17:0] ymax_CRT, ymax_NXT;


    /* Strict comparisons preserve the original vertex order on equal Y */
    assign y_order[2] = triangle_CRT.vtx[0].pos.y > triangle_CRT.vtx[1].pos.y;
    assign y_order[1] = triangle_CRT.vtx[0].pos.y > triangle_CRT.vtx[2].pos.y;
    assign y_order[0] = triangle_CRT.vtx[1].pos.y > triangle_CRT.vtx[2].pos.y;

    /* Each inversion changes the permutation parity */
    assign parity_next = ^y_order;

        always_comb begin
            /* Packed order is {BOTTOM, MIDDLE, TOP} */
            case (y_order)
                3'b000: order_next = {VERTEX_2, VERTEX_1, VERTEX_0};

                3'b001: order_next = {VERTEX_1, VERTEX_2, VERTEX_0};

                3'b011: order_next = {VERTEX_1, VERTEX_0, VERTEX_2};

                3'b100: order_next = {VERTEX_2, VERTEX_0, VERTEX_1};

                3'b110: order_next = {VERTEX_0, VERTEX_2, VERTEX_1};

                3'b111: order_next = {VERTEX_0, VERTEX_1, VERTEX_2};

                default: order_next = {VERTEX_2, VERTEX_1, VERTEX_0};
            endcase
        end

    always_comb begin
        /* Default Values */
        xmin_next = triangle_CRT.vtx[0].pos.x;
        xmax_next = triangle_CRT.vtx[0].pos.x;

        for (int i = 1; i < 3; i++) begin
            if (triangle_CRT.vtx[i].pos.x < xmin_next) begin
                xmin_next = triangle_CRT.vtx[i].pos.x;
            end

            if (triangle_CRT.vtx[i].pos.x > xmax_next) begin
                xmax_next = triangle_CRT.vtx[i].pos.x;
            end
        end
    end


//====================================================================================
//      BOUNDING BOX AND EDGE GEOMETRY
//====================================================================================

    logic signed [10:0] bb_x_start, bb_x_end;
    logic signed [9:0] bb_y_start, bb_y_end, edge_start, edge_end;
    logic [1:0] vertex_a, vertex_b;
    setup_edge_t edge_next;

        always_comb begin
            /* Xmin for start of bounding box, round up if the number has fractional part greater than 0.5 */
            bb_x_start = 11'(xmin_CRT >>> 8) + 11'(xmin_CRT[7:0] > 8'h80);

            /* Xmax for end of bounding box, round down if the number has fractional part less than 0.5 */
            bb_x_end = 11'(xmax_CRT >>> 8) - 11'(xmax_CRT[7:0] < 8'h80);

            /* Ymin for start of bounding box considering Y grow from top to bottom, round up if 
             * the number has fractional part greater than 0.5 */
            bb_y_start = 10'(ymin_CRT >>> 8) + 10'(ymin_CRT[7:0] > 8'h80);

            /* Ymax for end of bounding box, round down if the number has fractional part less than 0.5 */
            bb_y_end = 10'(ymax_CRT >>> 8) - 10'(ymax_CRT[7:0] < 8'h80);


            /* Negative number clamping */
            if (bb_x_start < 0) begin
                bb_x_start = 0;
            end

            if (bb_y_start < 0) begin
                bb_y_start = 0;
            end

            /* Clamping to viewport */
            if (bb_x_end >= $signed({1'b0, viewport_width_CRT})) begin
                bb_x_end = $signed({1'b0, viewport_width_CRT}) - 11'sd1;
            end

            if (bb_y_end >= $signed({1'b0, viewport_height_CRT})) begin
                bb_y_end = $signed({1'b0, viewport_height_CRT}) - 10'sd1;
            end

            /* Clamping to scissor */
            if (scissor_enable_CRT) begin
                if (bb_x_start < $signed({1'b0, scissor_xmin_CRT})) begin
                    bb_x_start = $signed({1'b0, scissor_xmin_CRT});
                end

                if (bb_x_end > $signed({1'b0, scissor_xmax_CRT})) begin
                    bb_x_end = $signed({1'b0, scissor_xmax_CRT});
                end

                if (bb_y_start < $signed({1'b0, scissor_ymin_CRT})) begin
                    bb_y_start = $signed({1'b0, scissor_ymin_CRT});
                end

                if (bb_y_end > $signed({1'b0, scissor_ymax_CRT})) begin
                    bb_y_end = $signed({1'b0, scissor_ymax_CRT});
                end
            end
        end

    /* Vertex A (top one) is the: Middle (index 1) if current edge is MID-BOT or Top edge (index 0) 
     * if current edge is TOP-BOT or TOP-MID */
    assign vertex_a = edge_idx_CRT == EDGE_MB ? order_CRT[1] : order_CRT[0];

    /* Vertex B (bottom one) is the: Middle (index 1) if current edge is TOP-MID or Bottom edge (index 0) 
     * if current edge is TOP-BOT or MID-BOT */
    assign vertex_b = edge_idx_CRT == EDGE_TM ? order_CRT[1] : order_CRT[2];

    /* Build edge info */
    assign edge_next.xa = triangle_CRT.vtx[vertex_a].pos.x;
    assign edge_next.ya = triangle_CRT.vtx[vertex_a].pos.y;
    assign edge_next.xb = triangle_CRT.vtx[vertex_b].pos.x;
    assign edge_next.yb = triangle_CRT.vtx[vertex_b].pos.y;
    assign edge_next.valid = edge_next.ya < edge_next.yb & edge_start <= edge_end;
    assign edge_next.j_start = edge_start[8:0];
    assign edge_next.j_end = edge_end[8:0];
    assign edge_next.is_left = (triangle_CRT.area[37] ^ parity_CRT) ^ (edge_idx_CRT == EDGE_TB);

        always_comb begin
            edge_start = ceil_y(edge_next.ya);
            edge_end = ceil_y(edge_next.yb) - 10'sd1;

            if (edge_start < $signed({1'b0, bb_y_start_o})) begin
                edge_start = $signed({1'b0, bb_y_start_o});
            end

            if (edge_end > $signed({1'b0, bb_y_end_o})) begin
                edge_end = $signed({1'b0, bb_y_end_o});
            end
        end



//====================================================================================
//      MATH OPERAND MULTIPLEXER
//====================================================================================

    logic [6:0] attr_mask_CRT, attr_mask_NXT;
    logic [2:0] attr_idx_CRT, attr_idx_NXT;
    setup_attribute_t [3:0] attr_CRT, attr_NXT;

    logic color_selected;
    logic [1:0] plane_idx, color_idx;
    logic signed [31:0] math_a0, math_a1, math_a2, math_sx, math_gx, math_gy;
    logic signed [31:0] selected_a0, selected_a1, selected_a2, selected_sx, selected_gx, selected_gy;
    logic signed [17:0] math_y0, math_y1, math_y2, math_yref;
    logic signed [17:0] selected_y0, selected_y1, selected_y2, selected_yref;
    logic signed [18:0] math_x0, math_x1, math_x2, math_xref;
    logic signed [18:0] selected_x0, selected_x1, selected_x2, selected_xref;
    logic signed [37:0] math_area, selected_area;
    reciprocal_t math_recip_area, selected_recip_area;

    assign color_selected = (attr_idx_CRT >= ATTR_R) & (attr_idx_CRT <= ATTR_B);
    assign color_idx = attr_idx_CRT - ATTR_R;
    assign plane_idx = (attr_idx_CRT == ATTR_Z) ? 2'd0 : (attr_idx_CRT - ATTR_TEX_U + 3'd1);

        /* Original vertices serve the attribute commands; edges select two endpoints */
        always_comb begin
            /* Default Values */
            selected_x0 = triangle_CRT.vtx[0].pos.x;
            selected_x1 = triangle_CRT.vtx[1].pos.x;
            selected_x2 = triangle_CRT.vtx[2].pos.x;
            selected_y0 = triangle_CRT.vtx[0].pos.y;
            selected_y1 = triangle_CRT.vtx[1].pos.y;
            selected_y2 = triangle_CRT.vtx[2].pos.y;
            selected_xref = $signed({1'b0, bb_x_start_o, 8'h80});
            selected_yref = $signed({1'b0, bb_y_start_o, 8'h80});

            if (math_command_CRT == CALC_SLOPE | math_command_CRT == CALC_EDGE_INIT) begin
                selected_x0 = edge_CRT[edge_idx_CRT].xa;
                selected_x1 = edge_CRT[edge_idx_CRT].xb;
                selected_y0 = edge_CRT[edge_idx_CRT].ya;
                selected_y1 = edge_CRT[edge_idx_CRT].yb;
                selected_yref = $signed({1'b0, edge_CRT[edge_idx_CRT].j_start, 8'h80});
            end
        end

    /* Multiplex the attribute based on attribute index */
    assign selected_a0 = attribute_value(triangle_CRT.vtx[0], decoded_w[0][31:0], attr_idx_CRT);
    assign selected_a1 = attribute_value(triangle_CRT.vtx[1], decoded_w[1][31:0], attr_idx_CRT);
    assign selected_a2 = attribute_value(triangle_CRT.vtx[2], decoded_w[2][31:0], attr_idx_CRT);
    assign selected_area = triangle_CRT.area;
    assign selected_recip_area = recip_area_CRT;
    assign selected_sx = edge_CRT[edge_idx_CRT].sx;

        /* Present the saved F12 color gradients as F16 for the reference */
        always_comb begin
            if (color_selected) begin
                selected_gx = 32'(color_o[color_idx].gx) <<< COLOR_SHIFT;
                selected_gy = 32'(color_o[color_idx].gy) <<< COLOR_SHIFT;
            end else begin
                selected_gx = attr_o[plane_idx].gx;
                selected_gy = attr_o[plane_idx].gy;
            end
        end

    generate
        if (REGISTER_MATH_INPUTS) begin : gen_registered_inputs
            /* PREP precedes REQUEST; the math unit never samples the old bundle */
            always_ff @(posedge clk_i) begin
                if (state_CRT == MATH_PREP) begin
                    math_x0 <= selected_x0;
                    math_x1 <= selected_x1;
                    math_x2 <= selected_x2;
                    math_y0 <= selected_y0;
                    math_y1 <= selected_y1;
                    math_y2 <= selected_y2;
                    math_a0 <= selected_a0;
                    math_a1 <= selected_a1;
                    math_a2 <= selected_a2;
                    math_xref <= selected_xref;
                    math_yref <= selected_yref;
                    math_area <= selected_area;
                    math_recip_area <= selected_recip_area;
                    math_sx <= selected_sx;
                    math_gx <= selected_gx;
                    math_gy <= selected_gy;
                end
            end
        end else begin : gen_direct_inputs
            assign math_x0 = selected_x0;
            assign math_x1 = selected_x1;
            assign math_x2 = selected_x2;
            assign math_y0 = selected_y0;
            assign math_y1 = selected_y1;
            assign math_y2 = selected_y2;
            assign math_a0 = selected_a0;
            assign math_a1 = selected_a1;
            assign math_a2 = selected_a2;
            assign math_xref = selected_xref;
            assign math_yref = selected_yref;
            assign math_area = selected_area;
            assign math_recip_area = selected_recip_area;
            assign math_sx = selected_sx;
            assign math_gx = selected_gx;
            assign math_gy = selected_gy;
        end
    endgenerate


//====================================================================================
//      SHARED MATH UNIT AND COLOR CONVERSION
//====================================================================================

    logic math_req_valid, math_req_ready, math_resp_valid, math_resp_ready;
    logic [87:0] math_result;
    status_t math_status;
    logic signed [44:0] color_rounded;
    logic color_overflow;

    triangle_math_unit #(.MULTIPLIER_LATENCY(MULTIPLIER_LATENCY)) math_unit (
        .clk_i   ( clk_i           ),
        .rst_n_i ( rst_n_i         ),
        .ready_i ( math_resp_ready ),

        .command_valid_i ( math_req_valid   ),
        .command_i       ( math_command_CRT ),
        .command_ready_o ( math_req_ready   ),

        .viewport_width_i  ( viewport_width_CRT  ),
        .viewport_height_i ( viewport_height_CRT ),

        .x0_i ( math_x0 ),
        .x1_i ( math_x1 ),
        .x2_i ( math_x2 ),
        .y0_i ( math_y0 ),
        .y1_i ( math_y1 ),
        .y2_i ( math_y2 ),

        .a0_i ( math_a0 ),
        .a1_i ( math_a1 ),
        .a2_i ( math_a2 ),

        .xref_i ( math_xref ),
        .yref_i ( math_yref ),

        .area_i       ( math_area       ),
        .recip_area_i ( math_recip_area ),

        .sx_i ( math_sx ),
        .gx_i ( math_gx ),
        .gy_i ( math_gy ),

        .valid_o  ( math_resp_valid ),
        .result_o ( math_result     ),
        .status_o ( math_status     ),
        .busy_o   (                 )
    );

    assign math_req_valid = state_CRT == MATH_REQUEST;
    assign math_resp_ready = state_CRT == MATH_WAIT;

        /* F16 to F12, nearest ties-to-even; check signed range before narrowing */
        always_comb begin
            color_rounded = (($signed(math_result[43:0])) >>> COLOR_SHIFT) +
                            ((math_result[3] & ((math_result[2:0] != '0) | math_result[4])) ? 45'sd1 : 45'sd0);

            if (math_command_CRT == CALC_ATTR_REF) begin
                color_overflow = color_rounded != 45'($signed(color_rounded[35:0]));
            end else begin
                color_overflow = color_rounded != 45'($signed(color_rounded[23:0]));
            end
            
            color_overflow &= color_selected & (math_command_CRT == CALC_GRAD_X | math_command_CRT == CALC_GRAD_Y | math_command_CRT == CALC_ATTR_REF);
        end


//====================================================================================
//      REGISTERS
//====================================================================================

    setup_color_plane_t [2:0] color_CRT, color_NXT;
    logic [2:0][3:0] alpha_CRT, alpha_NXT;
    logic [3:0] flat_r_CRT, flat_r_NXT;
    logic [3:0] flat_g_CRT, flat_g_NXT;
    logic [3:0] flat_b_CRT, flat_b_NXT;

    logic [9:0] bb_x_start_CRT, bb_x_start_NXT;
    logic [9:0] bb_x_end_CRT, bb_x_end_NXT;
    logic [8:0] bb_y_start_CRT, bb_y_start_NXT;
    logic [8:0] bb_y_end_CRT, bb_y_end_NXT;


        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                state_CRT <= IDLE;
                setup_status_CRT <= SETUP_OK;
                math_status_CRT <= STATUS_OK;
            end else begin
                state_CRT <= state_NXT;
                setup_status_CRT <= setup_status_NXT;
                math_status_CRT <= math_status_NXT;
            end
        end

        always_ff @(posedge clk_i) begin
            if (rst_n_i) begin
                math_command_CRT <= math_command_NXT;
                triangle_CRT <= triangle_NXT;

                viewport_width_CRT <= viewport_width_NXT;
                viewport_height_CRT <= viewport_height_NXT;

                scissor_enable_CRT <= scissor_enable_NXT;
                scissor_xmin_CRT <= scissor_xmin_NXT;
                scissor_xmax_CRT <= scissor_xmax_NXT;
                scissor_ymin_CRT <= scissor_ymin_NXT;
                scissor_ymax_CRT <= scissor_ymax_NXT;
                
                attr_mask_CRT <= attr_mask_NXT;
                edge_CRT <= edge_NXT;
                recip_area_CRT <= recip_area_NXT;
                edge_idx_CRT <= edge_idx_NXT;
                attr_idx_CRT <= attr_idx_NXT;
                order_CRT <= order_NXT;
                parity_CRT <= parity_NXT;

                xmin_CRT <= xmin_NXT;
                xmax_CRT <= xmax_NXT;
                ymin_CRT <= ymin_NXT;
                ymax_CRT <= ymax_NXT;

                bb_x_start_CRT <= bb_x_start_NXT;
                bb_x_end_CRT <= bb_x_end_NXT;
                bb_y_start_CRT <= bb_y_start_NXT;
                bb_y_end_CRT <= bb_y_end_NXT;

                attr_CRT <= attr_NXT;
                color_CRT <= color_NXT;
                alpha_CRT <= alpha_NXT;

                flat_r_CRT <= flat_r_NXT;
                flat_g_CRT <= flat_g_NXT;
                flat_b_CRT <= flat_b_NXT;

                gouraud_shading_CRT <= gouraud_shading_NXT;
                texture_CRT <= texture_NXT;
                perspective_correct_CRT <= perspective_correct_NXT;
            end
        end


//====================================================================================
//      FSM LOGIC
//====================================================================================

    always_comb begin
        state_NXT = state_CRT;
        setup_status_NXT = setup_status_CRT;
        math_status_NXT = math_status_CRT;
        math_command_NXT = math_command_CRT;
        triangle_NXT = triangle_CRT;
        viewport_width_NXT = viewport_width_CRT;
        viewport_height_NXT = viewport_height_CRT;
        scissor_enable_NXT = scissor_enable_CRT;
        scissor_xmin_NXT = scissor_xmin_CRT;
        scissor_xmax_NXT = scissor_xmax_CRT;
        scissor_ymin_NXT = scissor_ymin_CRT;
        scissor_ymax_NXT = scissor_ymax_CRT;
        attr_mask_NXT = attr_mask_CRT;
        edge_NXT = edge_CRT;
        recip_area_NXT = recip_area_CRT;
        edge_idx_NXT = edge_idx_CRT;
        attr_idx_NXT = attr_idx_CRT;
        order_NXT = order_CRT;
        parity_NXT = parity_CRT;
        xmin_NXT = xmin_CRT;
        xmax_NXT = xmax_CRT;
        ymin_NXT = ymin_CRT;
        ymax_NXT = ymax_CRT;
        bb_x_start_NXT = bb_x_start_CRT;
        bb_x_end_NXT = bb_x_end_CRT;
        bb_y_start_NXT = bb_y_start_CRT;
        bb_y_end_NXT = bb_y_end_CRT;
        attr_NXT = attr_CRT;
        color_NXT = color_CRT;
        alpha_NXT = alpha_CRT;
        flat_r_NXT = flat_r_CRT;
        flat_g_NXT = flat_g_CRT;
        flat_b_NXT = flat_b_CRT;
        gouraud_shading_NXT = gouraud_shading_CRT;
        texture_NXT = texture_CRT;
        perspective_correct_NXT = perspective_correct_CRT;

        case (state_CRT)
            IDLE: begin
                if (triangle_valid_i & triangle_ready_o) begin
                    /* Start processing */
                    state_NXT = VALIDATE;
                end
                
                /* Initialize registers */
                triangle_NXT = triangle_i;
                attr_idx_NXT = 3'(ATTR_Z);
                
                viewport_width_NXT = viewport_width_i;
                viewport_height_NXT = viewport_height_i;
                
                scissor_enable_NXT = scissor_enable_i;
                scissor_xmin_NXT = scissor_xmin_i;
                scissor_xmax_NXT = scissor_xmax_i;
                scissor_ymin_NXT = scissor_ymin_i;
                scissor_ymax_NXT = scissor_ymax_i;
                
                gouraud_shading_NXT = gouraud_shading_i;
                texture_NXT = texture_i;
                perspective_correct_NXT = texture_i & perspective_correct_i;

                flat_r_NXT = triangle_i.vtx[0].col.r;
                flat_g_NXT = triangle_i.vtx[0].col.g;
                flat_b_NXT = triangle_i.vtx[0].col.b;

                attr_mask_NXT = { {3{texture_i & perspective_correct_i}}, {3{gouraud_shading_i}}, z_interpolation_i };

                setup_status_NXT = SETUP_OK;
                math_status_NXT = STATUS_OK;

                for (int i = 0; i < 3; i++) begin
                    alpha_NXT[i] = triangle_i.vtx[i].col.a;
                    edge_NXT[i] = '0;
                    color_NXT[i] = '0;
                end

                for (int i = 0; i < 4; i++) begin
                    attr_NXT[i] = '0;
                end
            end

            VALIDATE: begin
                /* Validate configuration and data */
                if ((config_valid != '1) | !config_max_valid | (inv_w_invalid != '0)) begin
                    state_NXT = OUTPUT;

                    setup_status_NXT = SETUP_INVALID_CONFIG;
                end else if (inv_w_range != '0) begin
                    state_NXT = OUTPUT;

                    setup_status_NXT = SETUP_MATH_ERROR;
                    math_status_NXT = STATUS_OVERFLOW;
                end else if (triangle_CRT.area == 0) begin
                    state_NXT = OUTPUT;

                    setup_status_NXT = SETUP_DEGENERATE;
                end else begin
                    state_NXT = MIN_MAX_ORDER;
                end
            end

            MIN_MAX_ORDER: begin
                /* Take result from min/max and ordering logic */
                state_NXT = BBOX;

                order_NXT = order_next;
                parity_NXT = parity_next;

                xmin_NXT = xmin_next;
                xmax_NXT = xmax_next;

                ymin_NXT = triangle_CRT.vtx[order_next[0]].pos.y;
                ymax_NXT = triangle_CRT.vtx[order_next[2]].pos.y;
            end

            BBOX: begin
                if (bb_x_start > bb_x_end | bb_y_start > bb_y_end) begin
                    /* Invalid bounding box */
                    state_NXT = OUTPUT;

                    setup_status_NXT = SETUP_EMPTY;
                end else begin
                    /* Prepare edges */
                    state_NXT = EDGE_PREP;

                    bb_x_start_NXT = bb_x_start[9:0];
                    bb_x_end_NXT = bb_x_end[9:0];
                    bb_y_start_NXT = bb_y_start[8:0];
                    bb_y_end_NXT = bb_y_end[8:0];

                    edge_idx_NXT = EDGE_TM;
                end
            end

            EDGE_PREP: begin
                /* Process the edge */
                state_NXT = edge_next.valid ? MATH_PREP : NEXT_EDGE;

                edge_NXT[edge_idx_CRT] = edge_next;
                math_command_NXT = CALC_SLOPE;
            end

            NEXT_EDGE: begin
                if (edge_idx_CRT == EDGE_MB) begin
                    /* Last edge */
                    if ({edge_CRT[0].valid, edge_CRT[1].valid, edge_CRT[2].valid} == '0) begin
                        /* If every edge had beed examined finish */
                        state_NXT = OUTPUT;

                        setup_status_NXT = SETUP_EMPTY;
                    end else begin
                        /* If no attributes needs to be interpolated, exit */
                        state_NXT = attr_mask_CRT == 0 ? OUTPUT : MATH_PREP;

                        /* Valid if need interpolation */
                        math_command_NXT = CALC_INV_AREA;
                    end
                end else begin
                    /* Prepare edge, increment index to pass to the next edge */
                    state_NXT = EDGE_PREP;

                    edge_idx_NXT = edge_idx_CRT + 1'b1;
                end
            end

            ATTR_SELECT: begin
                if (attr_idx_CRT == ATTR_COUNT) begin
                    /* All attributes has been processed */
                    state_NXT = OUTPUT;
                end else if (attr_mask_CRT[attr_idx_CRT]) begin
                    /* Prepare starting by X gradient */
                    state_NXT = MATH_PREP;

                    math_command_NXT = CALC_GRAD_X;
                end else begin
                    attr_idx_NXT = attr_idx_CRT + 1'b1;
                end
            end

            MATH_PREP: state_NXT = MATH_REQUEST;

            MATH_REQUEST: begin
                /* Request to math unit */
                if (math_req_valid & math_req_ready) begin
                    state_NXT = MATH_WAIT;
                end
            end

            MATH_WAIT: begin
                if (math_resp_valid & math_resp_ready) begin
                    if (math_status != STATUS_OK | color_overflow) begin
                        /* Finish if an error occured */
                        state_NXT = OUTPUT;

                        math_status_NXT = math_status != STATUS_OK ? math_status : STATUS_OVERFLOW;
                        setup_status_NXT = SETUP_MATH_ERROR;
                    end else begin
                        case (math_command_CRT)
                            CALC_SLOPE: begin
                                state_NXT = MATH_PREP;

                                edge_NXT[edge_idx_CRT].sx = math_result[31:0];
                                math_command_NXT = CALC_EDGE_INIT;
                            end


                            CALC_EDGE_INIT: begin
                                state_NXT = NEXT_EDGE;

                                edge_NXT[edge_idx_CRT].x_initial = math_result[23:0];
                            end

                            CALC_INV_AREA: begin
                                state_NXT = ATTR_SELECT;

                                recip_area_NXT = reciprocal_t'(math_result[40:0]);
                                attr_idx_NXT = 3'(ATTR_Z);
                            end

                            CALC_GRAD_X: begin
                                if (color_selected) begin
                                    color_NXT[color_idx].gx = color_rounded[23:0];
                                end else begin
                                    attr_NXT[plane_idx].gx = math_result[31:0];
                                end

                                state_NXT = MATH_PREP;

                                math_command_NXT = CALC_GRAD_Y;
                            end

                            CALC_GRAD_Y: begin
                                if (color_selected) begin
                                    color_NXT[color_idx].gy = color_rounded[23:0];
                                end else begin
                                    attr_NXT[plane_idx].gy = math_result[31:0];
                                end

                                state_NXT = MATH_PREP;

                                math_command_NXT = CALC_ATTR_REF;
                            end

                            CALC_ATTR_REF: begin
                                if (color_selected) begin
                                    color_NXT[color_idx].aref = color_rounded[35:0];
                                end else begin
                                    attr_NXT[plane_idx].aref = math_result[43:0];
                                end
                                
                                state_NXT = ATTR_SELECT;
                                
                                attr_idx_NXT = attr_idx_CRT + 1'b1;
                            end

                            default: begin
                                math_status_NXT = STATUS_INVALID_CMD;
                                setup_status_NXT = SETUP_MATH_ERROR;
                                state_NXT = OUTPUT;
                            end
                        endcase
                    end
                end
            end

            OUTPUT: begin
                if (setup_valid_o & setup_ready_i) begin
                    state_NXT = IDLE;
                end
            end

            default: state_NXT = IDLE;
        endcase
    end


//====================================================================================
//      OUTPUT INTERFACE
//====================================================================================

    assign bb_x_start_o = bb_x_start_CRT;
    assign bb_x_end_o = bb_x_end_CRT;
    assign bb_y_start_o = bb_y_start_CRT;
    assign bb_y_end_o = bb_y_end_CRT;
    assign attr_o = attr_CRT;
    assign color_o = color_CRT;
    assign alpha_o = alpha_CRT;
    assign flat_r_o = flat_r_CRT;
    assign flat_g_o = flat_g_CRT;
    assign flat_b_o = flat_b_CRT;
    assign gouraud_shading_o = gouraud_shading_CRT;
    assign texture_o = texture_CRT;
    assign perspective_correct_o = perspective_correct_CRT;

    assign triangle_ready_o = state_CRT == IDLE;
    assign setup_valid_o = state_CRT == OUTPUT;
    assign busy_o = state_CRT != IDLE;
    assign setup_status_o = setup_status_CRT;
    assign math_status_o = math_status_CRT;
    assign attr_valid_o = setup_discard_o ? '0 : attr_mask_CRT;

        always_comb begin
            setup_error_o = 1'b0;
            setup_discard_o = 1'b0;
            case (setup_status_CRT)
                SETUP_OK: begin end

                SETUP_EMPTY, SETUP_DEGENERATE: setup_discard_o = 1'b1;

                default: begin
                    setup_error_o = 1'b1;
                    setup_discard_o = 1'b1;
                end
            endcase

            edge_tm_o = edge_CRT[EDGE_TM];
            edge_tb_o = edge_CRT[EDGE_TB];
            edge_mb_o = edge_CRT[EDGE_MB];

            if (setup_discard_o) begin
                edge_tm_o.valid = 1'b0;
                edge_tb_o.valid = 1'b0;
                edge_mb_o.valid = 1'b0;
            end
        end

endmodule : triangle_setup

`endif
