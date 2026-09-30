`ifndef CLIPPER_SV
    `define CLIPPER_SV

import triangle_pkg::*;
module clipper (
    input logic clk_i,
    input logic rst_n_i,

    /* Triangle coming from triangle buffer */
    input triangle_t triangle_i,
    input logic start_i,

    /* External 9-vertex FWFT FIFO */
    input vertex_t fifo_vtx_read_i,
    input logic fifo_empty_i,
    output vertex_t fifo_vtx_write_o,
    output logic fifo_write_o,
    output logic fifo_read_o,

    /* Triangle assembler start */
    output logic start_assemble_o,

    /* Status */
    output logic idle_o,
    output logic error_o
);

//====================================================================================
//      PARAMETERS AND FUNCTIONS
//====================================================================================

    localparam logic [2:0] LEFT_PLANE = 3'd0;
    localparam logic [2:0] NEAR_PLANE = 3'd5;

    function automatic logic on_plane (input logic [2:0] plane, input position_t pos);
        logic signed [32:0] x, y, z, w;

        x = {pos.x[31], pos.x};
        y = {pos.y[31], pos.y};
        z = {pos.z[31], pos.z};
        w = {pos.w[31], pos.w};

        case (plane)
            3'd0: on_plane = (w + x) == 0;
            3'd1: on_plane = (w - x) == 0;
            3'd2: on_plane = (w - y) == 0;
            3'd3: on_plane = (w + y) == 0;
            3'd4: on_plane = (w - z) == 0;
            3'd5: on_plane = z == 0;
            default: on_plane = 1'b0;
        endcase
    endfunction

//====================================================================================
//      REGISTERS
//====================================================================================

    typedef enum logic [3:0] {
        IDLE, INIT, READ_FIRST, READ_NEXT, TEST_INTERSECT,
        INTERPOLATE, PUSH_SECOND, ADVANCE, NEXT_PLANE, COMPLETE, CLEANUP
    } fsm_state_t;

    fsm_state_t state_CRT, state_NXT;

    triangle_t triangle_CRT, triangle_NXT;
    logic closing_edge_CRT, closing_edge_NXT;
    logic [1:0] init_count_CRT, init_count_NXT;
    logic [2:0] plane_CRT, plane_NXT;
    logic [3:0] source_count_CRT, source_count_NXT, destination_count_CRT, destination_count_NXT, read_count_CRT, read_count_NXT;
    vertex_t first_vertex_CRT, first_vertex_NXT, crt_vertex_CRT, crt_vertex_NXT, nxt_vertex_CRT, nxt_vertex_NXT;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
        end else begin
            state_CRT <= state_NXT;
        end
    end

    always_ff @(posedge clk_i) begin
        triangle_CRT <= triangle_NXT;
        plane_CRT <= plane_NXT;
        closing_edge_CRT <= closing_edge_NXT;
        source_count_CRT <= source_count_NXT;
        destination_count_CRT <= destination_count_NXT;
        read_count_CRT <= read_count_NXT;
        init_count_CRT <= init_count_NXT;
        first_vertex_CRT <= first_vertex_NXT;
        crt_vertex_CRT <= crt_vertex_NXT;
        nxt_vertex_CRT <= nxt_vertex_NXT;
    end


//====================================================================================
//      VERTEX INTERPOLATOR
//====================================================================================

    vertex_t intersection_vertex;
    logic intersection_valid, invalid_edge, interpolator_start;

    /* When two point crosses a plane, it produce the intersect point
     * with interpolated data */
    vertex_interpolator interpolator (
        .clk_i   ( clk_i   ),
        .rst_n_i ( rst_n_i ),

        .start_i ( interpolator_start ),

        .crt_vertex_i ( crt_vertex_CRT ),
        .nxt_vertex_i ( nxt_vertex_CRT ),
        .plane_i      ( plane_CRT      ),

        .intersection_vertex_o ( intersection_vertex ),
        .valid_o               ( intersection_valid  ),
        .invalid_edge_o        ( invalid_edge        )
    );

//====================================================================================
//      CLIP TESTER
//====================================================================================

    logic [5:0] crt_clip_code, nxt_clip_code;
    logic crt_is_inside, nxt_is_inside;
    logic crt_on_plane, nxt_on_plane;

    clip_tester crt_tester (
        .x_i ( crt_vertex_NXT.pos.x ),
        .y_i ( crt_vertex_NXT.pos.y ),
        .z_i ( crt_vertex_NXT.pos.z ),
        .w_i ( crt_vertex_NXT.pos.w ),

        .clip_code_o ( crt_clip_code )
    );

    clip_tester nxt_tester (
        .x_i ( nxt_vertex_NXT.pos.x ),
        .y_i ( nxt_vertex_NXT.pos.y ),
        .z_i ( nxt_vertex_NXT.pos.z ),
        .w_i ( nxt_vertex_NXT.pos.w ),

        .clip_code_o ( nxt_clip_code )
    );

    /* Classify alongside the vertex registers, before FIFO write control. */
    always_ff @(posedge clk_i) begin
        crt_is_inside <= !crt_clip_code[plane_NXT];
        nxt_is_inside <= !nxt_clip_code[plane_NXT];
        
        crt_on_plane <= on_plane(plane_NXT, crt_vertex_NXT.pos);
        nxt_on_plane <= on_plane(plane_NXT, nxt_vertex_NXT.pos);
    end


//====================================================================================
//      FSM LOGIC
//====================================================================================

    always_comb begin
        /* Default values */
        state_NXT = state_CRT;
        triangle_NXT = triangle_CRT;
        plane_NXT = plane_CRT;
        closing_edge_NXT = closing_edge_CRT;
        source_count_NXT = source_count_CRT;
        destination_count_NXT = destination_count_CRT;
        read_count_NXT = read_count_CRT;
        init_count_NXT = init_count_CRT;
        first_vertex_NXT = first_vertex_CRT;
        crt_vertex_NXT = crt_vertex_CRT;
        nxt_vertex_NXT = nxt_vertex_CRT;

        fifo_vtx_write_o = '0;
        fifo_write_o = 1'b0;
        fifo_read_o = 1'b0;
        interpolator_start = 1'b0;
        start_assemble_o = 1'b0;

        case (state_CRT)
            IDLE: begin
                if (start_i & fifo_empty_i) begin
                    state_NXT = INIT;
                end

                /* Start with left plane */
                plane_NXT = LEFT_PLANE;

                triangle_NXT = triangle_i;
                init_count_NXT = '0;
                destination_count_NXT = '0;
            end

            INIT: begin
                /* Write the first three vertices in fifo */
                fifo_write_o = 1'b1;
                case (init_count_CRT)
                    2'd0: fifo_vtx_write_o = triangle_CRT.vtx[0];
                    2'd1: fifo_vtx_write_o = triangle_CRT.vtx[1];
                    default: fifo_vtx_write_o = triangle_CRT.vtx[2];
                endcase

                if (init_count_CRT == 2'd2) begin
                    state_NXT = READ_FIRST;

                    source_count_NXT = 4'd3;
                    read_count_NXT = '0;
                end else begin
                    init_count_NXT = init_count_CRT + 1'b1;
                end
            end

            READ_FIRST: begin
                if (!fifo_empty_i) begin
                    state_NXT = READ_NEXT;

                    fifo_read_o = 1'b1;
                end

                /* First vertex would be the last one to close the loop */
                first_vertex_NXT = fifo_vtx_read_i;
                crt_vertex_NXT = fifo_vtx_read_i;
                read_count_NXT = 4'd1;
            end

            READ_NEXT: begin
                if (read_count_CRT == source_count_CRT) begin
                    state_NXT = TEST_INTERSECT;

                    /* Last iteration to close the loop is on the first vertex */
                    nxt_vertex_NXT = first_vertex_CRT;
                    closing_edge_NXT = 1'b1;
                end else if (!fifo_empty_i) begin
                    state_NXT = TEST_INTERSECT;

                    fifo_read_o = 1'b1;
                    
                    nxt_vertex_NXT = fifo_vtx_read_i;
                    read_count_NXT = read_count_CRT + 1'b1;
                    closing_edge_NXT = 1'b0;
                end
            end

            TEST_INTERSECT: begin
                if (crt_is_inside & !nxt_is_inside & crt_on_plane) begin
                    /* Next point is outside, current is on plane. Do not do anything
                     * just discard to avoid pushing two identical vertex */
                    state_NXT = ADVANCE;
                end else if (!crt_is_inside & nxt_is_inside & nxt_on_plane) begin
                    /* Vertex is laying on the plane, just push it for the next iteration */
                    state_NXT = ADVANCE;

                    fifo_write_o = 1'b1;
                    fifo_vtx_write_o = nxt_vertex_CRT;
                    
                    destination_count_NXT = destination_count_CRT + 1'b1;
                end else if (crt_is_inside != nxt_is_inside) begin
                    /* The edge is crossing the plane, interpolate to find the intersection
                     * point with interpolated coordinates */
                    state_NXT = INTERPOLATE;

                    interpolator_start = 1'b1;
                end else if (nxt_is_inside & crt_is_inside) begin
                    /* Both inside, just push the next vertex */
                    state_NXT = ADVANCE;

                    fifo_write_o = 1'b1;
                    fifo_vtx_write_o = nxt_vertex_CRT;
                    destination_count_NXT = destination_count_CRT + 1'b1;
                end else begin
                    state_NXT = ADVANCE;
                end
            end

            INTERPOLATE: begin
                if (invalid_edge) begin
                    /* Error recovery */
                    state_NXT = CLEANUP;
                end else if (intersection_valid) begin
                    /* If next vertex is inside we need to push the interpolated
                     * vertex and the next one */
                    if (nxt_is_inside) begin
                        state_NXT = PUSH_SECOND;
                    end else begin
                        state_NXT = ADVANCE;
                    end

                    fifo_write_o = 1'b1;
                    fifo_vtx_write_o = intersection_vertex;
                    destination_count_NXT = destination_count_CRT + 1'b1;
                end
            end

            PUSH_SECOND: begin
                state_NXT = ADVANCE;

                fifo_write_o = 1'b1;
                fifo_vtx_write_o = nxt_vertex_CRT;
                destination_count_NXT = destination_count_CRT + 1'b1;
            end

            ADVANCE: begin
                if (closing_edge_CRT) begin
                    state_NXT = NEXT_PLANE;
                end else begin
                    state_NXT = READ_NEXT;

                    /* Swap vertex */
                    crt_vertex_NXT = nxt_vertex_CRT;
                end
            end

            NEXT_PLANE: begin
                /* Reset counters */
                source_count_NXT = destination_count_CRT;
                destination_count_NXT = '0;
                read_count_NXT = '0;
                closing_edge_NXT = 1'b0;

                if (destination_count_CRT < 4'd3) begin
                    state_NXT = CLEANUP;
                end else if (plane_CRT == NEAR_PLANE) begin
                    state_NXT = COMPLETE;
                end else begin
                    state_NXT = READ_FIRST;

                    plane_NXT = plane_CRT + 1'b1;
                end
            end

            COMPLETE: begin
                start_assemble_o = 1'b1;
                state_NXT = IDLE;
            end

            CLEANUP: begin
                if (!fifo_empty_i) begin
                    /* Empty the fifo */
                    fifo_read_o = 1'b1;
                end else begin
                    state_NXT = IDLE;
                end
            end

            default: state_NXT = IDLE;
        endcase
    end

    assign idle_o = (state_CRT == IDLE);

    assign error_o = invalid_edge;

endmodule : clipper

`endif
