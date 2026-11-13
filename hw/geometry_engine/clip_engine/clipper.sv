`ifndef CLIPPER_SV
    `define CLIPPER_SV

module clipper (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Triangle owned by the upstream buffer. Keep stable from start_i until
     * clipping/assembly completes, including every stalled INIT cycle. */
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

//====================================================================================
//      REGISTERS
//====================================================================================

    typedef enum logic [3:0] {
        IDLE, INIT, READ_FIRST, READ_NEXT, CLASSIFY, TEST_INTERSECT,
        INTERPOLATE, PUSH_SECOND, ADVANCE, NEXT_PLANE, COMPLETE, CLEANUP
    } fsm_state_t;

    fsm_state_t state_CRT, state_NXT;

    logic closing_edge_CRT, closing_edge_NXT;
    logic [1:0] init_count_CRT, init_count_NXT;
    logic [2:0] plane_CRT, plane_NXT;
    logic [3:0] source_count_CRT, source_count_NXT, destination_count_CRT, destination_count_NXT, read_count_CRT, read_count_NXT;
    vertex_t first_vertex_CRT, first_vertex_NXT, crt_vertex_CRT, crt_vertex_NXT, nxt_vertex_CRT, nxt_vertex_NXT;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
        end else if (!stall_i) begin
            state_CRT <= state_NXT;
        end
    end

    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
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
    end


//====================================================================================
//      VERTEX INTERPOLATOR
//====================================================================================

    vertex_t intersection_vertex;
    logic intersection_valid, invalid_edge, interpolator_start;
    logic signed [32:0] crt_distance, nxt_distance;

    /* When two point crosses a plane, it produce the intersect point
     * with interpolated data */
    vertex_interpolator interpolator (
        .clk_i   ( clk_i   ),
        .rst_n_i ( rst_n_i ),
        .stall_i ( stall_i ),

        .start_i ( interpolator_start ),

        .crt_vertex_i ( crt_vertex_CRT ),
        .nxt_vertex_i ( nxt_vertex_CRT ),
        .plane_i      ( plane_CRT      ),

        .crt_distance_o ( crt_distance ),
        .nxt_distance_o ( nxt_distance ),

        .intersection_vertex_o ( intersection_vertex ),
        .valid_o               ( intersection_valid  ),
        .invalid_edge_o        ( invalid_edge        )
    );

//====================================================================================
//      CURRENT-PLANE CLASSIFICATION
//====================================================================================

    logic crt_is_inside, nxt_is_inside;
    logic crt_on_plane, nxt_on_plane;

    /* Classify the captured vertices after the FIFO read, before deciding
     * the edge action. Reuse the interpolator's distances for both sign and
     * equality: zero remains inside. The original classification register
     * keeps the FWFT mux out of plane arithmetic/reduction. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            crt_is_inside <= !crt_distance[32];
            nxt_is_inside <= !nxt_distance[32];

            crt_on_plane <= crt_distance == 0;
            nxt_on_plane <= nxt_distance == 0;
        end
    end


//====================================================================================
//      FSM LOGIC
//====================================================================================

    always_comb begin
        /* Default values */
        state_NXT = state_CRT;
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

                init_count_NXT = '0;
                destination_count_NXT = '0;
            end

            INIT: begin
                /* The upstream buffer retains this triangle until done_o;
                 * initialize the polygon directly without a second copy. */
                fifo_write_o = 1'b1;
                case (init_count_CRT)
                    2'd0: fifo_vtx_write_o = triangle_i.vtx[0];
                    2'd1: fifo_vtx_write_o = triangle_i.vtx[1];
                    default: fifo_vtx_write_o = triangle_i.vtx[2];
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
                    state_NXT = CLASSIFY;

                    /* Last iteration to close the loop is on the first vertex */
                    nxt_vertex_NXT = first_vertex_CRT;
                    closing_edge_NXT = 1'b1;
                end else if (!fifo_empty_i) begin
                    state_NXT = CLASSIFY;

                    fifo_read_o = 1'b1;
                    
                    nxt_vertex_NXT = fifo_vtx_read_i;
                    read_count_NXT = read_count_CRT + 1'b1;
                    closing_edge_NXT = 1'b0;
                end
            end

            CLASSIFY: state_NXT = TEST_INTERSECT;

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

        if (stall_i) begin
            fifo_write_o = 1'b0;
            fifo_read_o = 1'b0;
            interpolator_start = 1'b0;
            start_assemble_o = 1'b0;
        end
    end

    assign idle_o = (state_CRT == IDLE);

    assign error_o = invalid_edge;

endmodule : clipper

`endif
