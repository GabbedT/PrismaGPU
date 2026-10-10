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
        logic signed [32:0] x, y, z, w;

        x = {vtx_pos.x[31], vtx_pos.x};
        y = {vtx_pos.y[31], vtx_pos.y};
        z = {vtx_pos.z[31], vtx_pos.z};
        w = {vtx_pos.w[31], vtx_pos.w};

        case (plane)
            LEFT_PLANE:   plane_distance = w + x;

            RIGHT_PLANE:  plane_distance = w - x;

            TOP_PLANE:    plane_distance = w - y;

            BOTTOM_PLANE: plane_distance = w + y;

            FAR_PLANE:    plane_distance = w - z;

            NEAR_PLANE:   plane_distance = z;

            default:      plane_distance = '0;
        endcase
    endfunction


    function automatic logic signed [31:0] interpolate_position (
        input logic signed [31:0] start_value,
        input logic signed [31:0] end_value,
        input logic        [16:0] t,
        input logic               round_nearest
    );
        logic signed [32:0] delta;
        logic signed [50:0] product;
        logic [31:0] integral;
        logic integer_lsb, round_up, carry_in;

        delta = {end_value[31], end_value} - {start_value[31], start_value};
        product = delta * $signed({1'b0, t});

        /* Tie parity belongs to the sum, not just the product. */
        integer_lsb = start_value[0] ^ product[16];
        round_up = round_nearest & product[15] & ((|product[14:0]) | integer_lsb);

        /* Fold rounding into bit-zero carry to keep a single position adder. */
        carry_in = (start_value[0] & product[16]) | (integer_lsb & round_up);
        integral = {start_value[31:1], 1'b1} + {product[47:17], carry_in};

        interpolate_position = {integral[31:1], (integer_lsb ^ round_up)};
    endfunction


    function automatic logic [3:0] interpolate_color (
        input logic [3:0] start_value,
        input logic [3:0] end_value,
        input logic [16:0] t
    );
        logic signed [4:0] delta;
        logic signed [22:0] product;

        delta = $signed({1'b0, end_value}) - $signed({1'b0, start_value});
        product = delta * $signed({1'b0, t});

        interpolate_color = start_value + (product >>> 16);
    endfunction


//====================================================================================
//      PLANE DISTANCE
//====================================================================================  

    /* Variables relative to current vertex and next vertex */
    logic signed [32:0] crt_distance, nxt_distance; 
    
    assign crt_distance = plane_distance(plane_i, crt_vertex_i.pos);

    assign nxt_distance = plane_distance(plane_i, nxt_vertex_i.pos);


//====================================================================================
//      INTERPOLATION PARAMETER CALCULATION
//====================================================================================  

    logic [16:0] t, fraction;
    logic valid, invalid_edge, fraction_inexact;

    /* Round t toward the inside endpoint; exact fractions stay unchanged */
    always_ff @(posedge clk_i) begin
        if (!stall_i & valid & !invalid_edge) begin
            t <= fraction + {16'b0, (crt_distance[32] & fraction_inexact)};
        end
    end

    /* Calculate interpolation parameter in iterative division */
    clip_fraction_divider divider (
        .clk_i   ( clk_i   ),
        .rst_n_i ( rst_n_i ),
        .stall_i ( stall_i ),

        .plane_start_i ( crt_distance ),
        .plane_end_i   ( nxt_distance ),

        .data_valid_i ( start_i ),

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

    assign interpolated_position = interpolate_position(crt_pos, nxt_pos, t, round_position);

    assign interpolated_color = interpolate_color(crt_col, nxt_col, t);


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

                    new_vertex_NXT.pos.x = interpolated_position;

                    state_NXT = INTP_Y;
                end

                INTP_Y: begin
                    crt_pos = crt_vertex_i.pos.y;
                    nxt_pos = nxt_vertex_i.pos.y;

                    new_vertex_NXT.pos.y = interpolated_position;

                    state_NXT = INTP_Z;
                end

                INTP_Z: begin
                    crt_pos = crt_vertex_i.pos.z;
                    nxt_pos = nxt_vertex_i.pos.z;

                    new_vertex_NXT.pos.z = interpolated_position;

                    state_NXT = INTP_W;
                end

                INTP_W: begin
                    crt_pos = crt_vertex_i.pos.w;
                    nxt_pos = nxt_vertex_i.pos.w;

                    new_vertex_NXT.pos.w = interpolated_position;

                    state_NXT = INTP_U;
                end

                INTP_U: begin
                    crt_pos = crt_vertex_i.tex.u;
                    nxt_pos = nxt_vertex_i.tex.u;

                    new_vertex_NXT.tex.u = interpolated_position;

                    /* Snap from registered w, in parallel with texture interpolation. */
                    case (plane_i)
                        LEFT_PLANE: new_vertex_NXT.pos.x = -plane_w;

                        RIGHT_PLANE: new_vertex_NXT.pos.x = plane_w;

                        TOP_PLANE: new_vertex_NXT.pos.y = plane_w;

                        BOTTOM_PLANE: new_vertex_NXT.pos.y = -plane_w;

                        FAR_PLANE: new_vertex_NXT.pos.z = plane_w;

                        NEAR_PLANE: new_vertex_NXT.pos.z = '0;
                    endcase

                    state_NXT = INTP_V;
                end

                INTP_V: begin
                    crt_pos = crt_vertex_i.tex.v;
                    nxt_pos = nxt_vertex_i.tex.v;

                    new_vertex_NXT.tex.v = interpolated_position;

                    state_NXT = INTP_R;
                end

                INTP_R: begin
                    crt_col = crt_vertex_i.col.r;
                    nxt_col = nxt_vertex_i.col.r;

                    new_vertex_NXT.col.r = interpolated_color;

                    state_NXT = INTP_G;
                end

                INTP_G: begin
                    crt_col = crt_vertex_i.col.g;
                    nxt_col = nxt_vertex_i.col.g;

                    new_vertex_NXT.col.g = interpolated_color;

                    state_NXT = INTP_B;
                end

                INTP_B: begin
                    crt_col = crt_vertex_i.col.b;
                    nxt_col = nxt_vertex_i.col.b;

                    new_vertex_NXT.col.b = interpolated_color;

                    state_NXT = INTP_A;
                end

                INTP_A: begin
                    crt_col = crt_vertex_i.col.a;
                    nxt_col = nxt_vertex_i.col.a;
                    
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
