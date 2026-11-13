`ifndef VERTEX_INTERPOLATOR_SV
    `define VERTEX_INTERPOLATOR_SV

module vertex_interpolator (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Start to interpolate */
    input logic start_i,

    /* Vertex to interpolate */
    input vertex_t crt_vertex_i,
    input vertex_t nxt_vertex_i,

    /* Plane to calculate distance */
    input logic [2:0] plane_i,

    /* Combinational signed F16 distances, shared with edge classification.
     * They follow the held endpoints/plane and are not gated by start_i. */
    output logic signed [32:0] crt_distance_o,
    output logic signed [32:0] nxt_distance_o,

    output vertex_t intersection_vertex_o,
    output logic valid_o,
    output logic invalid_edge_o
);

//====================================================================================
//      PARAMETERS AND FUNCTIONS
//====================================================================================  

    localparam LEFT_PLANE = 0;
    localparam RIGHT_PLANE = 1;

    localparam TOP_PLANE = 2;
    localparam BOTTOM_PLANE = 3;

    localparam FAR_PLANE = 4;
    localparam NEAR_PLANE = 5;


    function automatic logic signed [32:0] plane_distance (input logic [2:0] plane, input position_t vtx_pos);
        logic signed [32:0] base, coordinate;
        logic subtract;

        /* Select before arithmetic: one guarded add/sub per endpoint rather
         * than computing all plane distances and selecting their results.
         * Extending before subtraction preserves the full signed-32 range. */
        base = {vtx_pos.w[31], vtx_pos.w};
        coordinate = '0;
        subtract = 1'b0;

        case (plane)
            LEFT_PLANE, RIGHT_PLANE: begin
                coordinate = {vtx_pos.x[31], vtx_pos.x};
                subtract = plane == RIGHT_PLANE;
            end
            TOP_PLANE, BOTTOM_PLANE: begin
                coordinate = {vtx_pos.y[31], vtx_pos.y};
                subtract = plane == TOP_PLANE;
            end
            FAR_PLANE: begin
                coordinate = {vtx_pos.z[31], vtx_pos.z};
                subtract = 1'b1;
            end
            NEAR_PLANE: begin
                base = '0;
                coordinate = {vtx_pos.z[31], vtx_pos.z};
            end
            default: base = '0;
        endcase

        return base + (coordinate ^ {33{subtract}}) + subtract;
    endfunction


//====================================================================================
//      PLANE DISTANCE
//====================================================================================  

    /* Variables relative to current vertex and next vertex */
    logic signed [32:0] crt_distance_ff, nxt_distance_ff;
    logic divider_start_ff;
    
    assign crt_distance_o = plane_distance(plane_i, crt_vertex_i.pos);

    assign nxt_distance_o = plane_distance(plane_i, nxt_vertex_i.pos);

    /* Keep plane selection/addition before a register, and magnitude/division
     * after it. The delayed start and both distances freeze together on stall.
     * This adds one advancing cycle per intersection; no arithmetic changes. */
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            divider_start_ff <= 1'b0;
        end else if (!stall_i) begin
            divider_start_ff <= start_i;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!stall_i & start_i) begin
            crt_distance_ff <= crt_distance_o;
            nxt_distance_ff <= nxt_distance_o;
        end
    end


//====================================================================================
//      INTERPOLATION PARAMETER CALCULATION
//====================================================================================  

    logic [16:0] t, fraction;
    logic valid, invalid_edge, fraction_inexact;

    /* Round t toward the inside endpoint; exact fractions stay unchanged */
    always_ff @(posedge clk_i) begin
        if (!stall_i & valid & !invalid_edge) begin
            t <= fraction + {16'b0, (crt_distance_ff[32] & fraction_inexact)};
        end
    end

    /* Calculate interpolation parameter in iterative division */
    clip_fraction_divider divider (
        .clk_i   ( clk_i   ),
        .rst_n_i ( rst_n_i ),
        .stall_i ( stall_i ),

        .plane_start_i ( crt_distance_ff ),
        .plane_end_i   ( nxt_distance_ff ),

        .data_valid_i ( divider_start_ff ),

        .fraction_o         ( fraction         ),
        .fraction_inexact_o ( fraction_inexact ),
        .data_valid_o       ( valid            ),

        .invalid_edge_o ( invalid_edge ),
        .idle_o         (              )
    );


//====================================================================================
//      INTERPOLATION
//==================================================================================== 

    logic signed [31:0] crt_pos, nxt_pos; logic [3:0] crt_col, nxt_col;
    logic signed [31:0] interpolated_position; logic [3:0] interpolated_color;
    logic round_position;

    logic signed [32:0] position_delta, position_delta_ff;
    logic signed [50:0] position_product, position_product_ff;
    logic signed [31:0] start_position_delta_ff, start_position_ff;
    logic round_position_delta_ff, round_position_ff;
    logic [31:0] position_integral;
    logic integer_lsb, round_up, carry_in;
    logic signed [4:0] color_delta_ff;
    logic [3:0] color_start_ff;
    logic signed [22:0] color_product;

    /* First stage: subtract, retaining the matching start value and rounding. */
    assign position_delta = {nxt_pos[31], nxt_pos} - {crt_pos[31], crt_pos};

    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            position_delta_ff <= position_delta;
            start_position_delta_ff <= crt_pos;
            round_position_delta_ff <= round_position;
        end
    end

    /* Second stage: multiply the registered delta; t is stable for the vertex. */
    assign position_product = position_delta_ff * $signed({1'b0, t});

    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            position_product_ff <= position_product;
            start_position_ff <= start_position_delta_ff;
            round_position_ff <= round_position_delta_ff;
        end
    end

    /* Final stage: tie parity belongs to the sum, not just the product. */
    assign integer_lsb = start_position_ff[0] ^ position_product_ff[16];
    assign round_up = round_position_ff & position_product_ff[15] & ((|position_product_ff[14:0]) | integer_lsb);

    /* Fold rounding into bit-zero carry to keep a single position adder. */
    assign carry_in = (start_position_ff[0] & position_product_ff[16]) | (integer_lsb & round_up);
    assign position_integral = {start_position_ff[31:1], 1'b1} + {position_product_ff[47:17], carry_in};

    /* Final interpolated position */
    assign interpolated_position = {position_integral[31:1], (integer_lsb ^ round_up)};

    /* Select each color one cycle before its writeback, starting in INTP_V.
     * Register the signed nibble delta and matching start value before the
     * 5x18 multiply. Preserve floor/truncation and four-bit wrapping; t and
     * both endpoints remain stable through valid_o. All stages freeze on
     * stall, and no additional intersection cycle is needed. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            color_delta_ff <= $signed({1'b0, nxt_col}) - $signed({1'b0, crt_col});
            color_start_ff <= crt_col;
        end
    end

    assign color_product = color_delta_ff * $signed({1'b0, t});
    assign interpolated_color = color_start_ff + (color_product >>> 16);


//====================================================================================
//      NEW VERTEX CALCULATION
//==================================================================================== 

    typedef enum logic [3:0] { 
        IDLE, INTP_X, INTP_Y, INTP_Z, INTP_W, INTP_U, 
        INTP_V, INTP_R, INTP_G, INTP_B, INTP_A 
    } fsm_state_t;

    fsm_state_t state_CRT, state_NXT;
    vertex_t new_vertex_CRT, new_vertex_NXT;
    logic valid_CRT, valid_NXT;
    logic signed [31:0] plane_w;

    assign plane_w = new_vertex_CRT.pos.w;

    /* Reuse the position multiplier; texture coordinates retain truncation. */
    assign round_position = (state_CRT == INTP_X) | (state_CRT == INTP_Y) | (state_CRT == INTP_Z) | (state_CRT == INTP_W);

        always_ff @(posedge clk_i or negedge rst_n_i) begin
            if (!rst_n_i) begin
                state_CRT <= IDLE;
                valid_CRT <= 1'b0;
            end else if (!stall_i) begin
                state_CRT <= state_NXT;
                valid_CRT <= valid_NXT;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                new_vertex_CRT <= new_vertex_NXT;
            end
        end

        always_comb begin
            state_NXT = state_CRT;
            new_vertex_NXT = new_vertex_CRT;
            valid_NXT = 1'b0;

            crt_pos = '0;
            nxt_pos = '0;
            crt_col = '0;
            nxt_col = '0;

            /* To save multipliers we use just two of them (one for xyzw and uv and one for rgba),
             * then interpolate each coordinate sequentially instead of in parallel */
            case (state_CRT)
                IDLE: begin
                    if (valid & !invalid_edge) begin
                        state_NXT = INTP_X;
                    end
                end

                INTP_X: begin
                    crt_pos = crt_vertex_i.pos.x;
                    nxt_pos = nxt_vertex_i.pos.x;

                    state_NXT = INTP_Y;
                end

                INTP_Y: begin
                    crt_pos = crt_vertex_i.pos.y;
                    nxt_pos = nxt_vertex_i.pos.y;

                    state_NXT = INTP_Z;
                end

                INTP_Z: begin
                    crt_pos = crt_vertex_i.pos.z;
                    nxt_pos = nxt_vertex_i.pos.z;

                    /* Due to the two stages for interpolation, FSM 
                     * register the result two clock cycles later */
                    new_vertex_NXT.pos.x = interpolated_position;

                    state_NXT = INTP_W;
                end

                INTP_W: begin
                    crt_pos = crt_vertex_i.pos.w;
                    nxt_pos = nxt_vertex_i.pos.w;

                    new_vertex_NXT.pos.y = interpolated_position;

                    state_NXT = INTP_U;
                end

                INTP_U: begin
                    crt_pos = crt_vertex_i.tex.u;
                    nxt_pos = nxt_vertex_i.tex.u;

                    new_vertex_NXT.pos.z = interpolated_position;

                    state_NXT = INTP_V;
                end

                INTP_V: begin
                    crt_pos = crt_vertex_i.tex.v;
                    nxt_pos = nxt_vertex_i.tex.v;
                    crt_col = crt_vertex_i.col.r;
                    nxt_col = nxt_vertex_i.col.r;

                    new_vertex_NXT.pos.w = interpolated_position;

                    state_NXT = INTP_R;
                end

                INTP_R: begin
                    crt_col = crt_vertex_i.col.g;
                    nxt_col = nxt_vertex_i.col.g;

                    new_vertex_NXT.tex.u = interpolated_position;
                    new_vertex_NXT.col.r = interpolated_color;

                    /* Snap from registered w, in parallel with texture interpolation. */
                    case (plane_i)
                        LEFT_PLANE: new_vertex_NXT.pos.x = -plane_w;

                        RIGHT_PLANE: new_vertex_NXT.pos.x = plane_w;

                        TOP_PLANE: new_vertex_NXT.pos.y = plane_w;

                        BOTTOM_PLANE: new_vertex_NXT.pos.y = -plane_w;

                        FAR_PLANE: new_vertex_NXT.pos.z = plane_w;

                        NEAR_PLANE: new_vertex_NXT.pos.z = '0;
                    endcase

                    state_NXT = INTP_G;
                end

                INTP_G: begin
                    crt_col = crt_vertex_i.col.b;
                    nxt_col = nxt_vertex_i.col.b;

                    new_vertex_NXT.tex.v = interpolated_position;
                    new_vertex_NXT.col.g = interpolated_color;

                    state_NXT = INTP_B;
                end

                INTP_B: begin
                    crt_col = crt_vertex_i.col.a;
                    nxt_col = nxt_vertex_i.col.a;

                    new_vertex_NXT.col.b = interpolated_color;

                    state_NXT = INTP_A;
                end

                INTP_A: begin
                    new_vertex_NXT.col.a = interpolated_color;

                    valid_NXT = 1'b1;
                    state_NXT = IDLE;
                end

                default: state_NXT = IDLE;
            endcase
        end

    assign intersection_vertex_o = new_vertex_CRT;
    assign valid_o = valid_CRT;

    assign invalid_edge_o = invalid_edge;

endmodule : vertex_interpolator

`endif
