`ifndef CLIP_ENGINE_SV
    `define CLIP_ENGINE_SV

import triangle_pkg::*;

module clip_engine (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Input transfer: valid_i && !stall_o. Hold data while stalled. */
    input triangle_t triangle_i,
    input logic valid_i,
    output logic stall_o,

    /* Output transfer: valid_o && !stall_i */
    output vertex_t vertex_overtex_o,
    output logic valid_o,

    /* One completion per input, including discarded triangles */
    output logic done_o,
    output logic error_o
);

//====================================================================================
//      TRANSACTION CONTROL
//====================================================================================

    typedef enum logic [1:0] { IDLE, CLIPPING, ASSEMBLING } fsm_state_t;

    fsm_state_t state_CRT, state_NXT;
    logic input_accept;
    logic error_CRT;

    /* Keep FIFO ownership until the entire polygon has been consumed. */
    assign stall_o = !rst_n_i | (state_CRT != IDLE) | stall_i;
    assign input_accept = valid_i & !stall_o;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            error_CRT <= 1'b0;
        end else begin
            state_CRT <= state_NXT;

            if (state_CRT == IDLE) begin
                error_CRT <= 1'b0;
            end else begin
                error_CRT <= error_CRT | clipper_error | assembler_error;
            end
        end
    end

    always_comb begin
        state_NXT = state_CRT;
        done_o = 1'b0;

        case (state_CRT)
            IDLE: begin
                if (input_accept) begin
                    if (triangle_clip) begin
                        state_NXT = CLIPPING;
                    end else begin
                        done_o = 1'b1;
                    end
                end
            end

            CLIPPING: begin
                if (clipper_start_assemble) begin
                    state_NXT = ASSEMBLING;
                end else if (clipper_idle) begin
                    /* Cleanup also completes empty or degenerate polygons. */
                    state_NXT = IDLE;
                    done_o = rst_n_i;
                end
            end

            ASSEMBLING: begin
                if (assembler_done) begin
                    state_NXT = IDLE;
                    done_o = rst_n_i;
                end
            end

            default: begin
                state_NXT = IDLE;
            end
        endcase
    end


//====================================================================================
//      CLIP TESTER
//====================================================================================

    logic [5:0] vtx0_clip_code, vtx1_clip_code, vtx2_clip_code;

    clip_tester vtx0_tester (
        .x_i         ( triangle_i.vtx[0].pos.x ),
        .y_i         ( triangle_i.vtx[0].pos.y ),
        .z_i         ( triangle_i.vtx[0].pos.z ),
        .w_i         ( triangle_i.vtx[0].pos.w ),
        .clip_code_o ( vtx0_clip_code          )
    );

    clip_tester vtx1_tester (
        .x_i         ( triangle_i.vtx[1].pos.x ),
        .y_i         ( triangle_i.vtx[1].pos.y ),
        .z_i         ( triangle_i.vtx[1].pos.z ),
        .w_i         ( triangle_i.vtx[1].pos.w ),
        .clip_code_o ( vtx1_clip_code          )
    );

    clip_tester vtx2_tester (
        .x_i         ( triangle_i.vtx[2].pos.x ),
        .y_i         ( triangle_i.vtx[2].pos.y ),
        .z_i         ( triangle_i.vtx[2].pos.z ),
        .w_i         ( triangle_i.vtx[2].pos.w ),
        .clip_code_o ( vtx2_clip_code          )
    );

    logic triangle_inside, triangle_outside, triangle_clip, direct_valid;

    /* Trivial accept and reject tests */
    assign triangle_inside  = (vtx0_clip_code | vtx1_clip_code | vtx2_clip_code) == '0;
    assign triangle_outside = (vtx0_clip_code & vtx1_clip_code & vtx2_clip_code) != '0;
    assign triangle_clip    = !triangle_inside & !triangle_outside;

    assign direct_valid = (state_CRT == IDLE) & valid_i & triangle_inside;


//====================================================================================
//      VERTEX BUFFER
//====================================================================================

    localparam integer BUFFER_DEPTH = 9;

    logic buffer_empty, buffer_full, buffer_write, buffer_read;
    vertex_t fifo_vtx_read, fifo_vtx_write;

    clip_vertex_fifo vertex_buffer (
        .clk_i        ( clk_i              ),
        .rst_n_i      ( rst_n_i            ),
        .write_i      ( buffer_write       ),
        .read_i       ( buffer_read        ),
        .empty_o      ( buffer_empty       ),
        .full_o       ( buffer_full        ),
        .write_data_i ( fifo_vtx_write     ),
        .read_data_o  ( fifo_vtx_read      )
    );


//====================================================================================
//      CLIPPER
//====================================================================================

    logic clipper_start, clipper_fifo_write, clipper_fifo_read;
    logic clipper_start_assemble, clipper_idle, clipper_error;

    assign clipper_start = input_accept & triangle_clip;

    clipper triangle_clipper (
        .clk_i            ( clk_i                  ),
        .rst_n_i          ( rst_n_i                ),
        .triangle_i       ( triangle_i             ),
        .start_i          ( clipper_start          ),
        .fifo_vtx_read_i  ( fifo_vtx_read          ),
        .fifo_empty_i     ( buffer_empty           ),
        .fifo_vtx_write_o ( fifo_vtx_write         ),
        .fifo_write_o     ( clipper_fifo_write     ),
        .fifo_read_o      ( clipper_fifo_read      ),
        .start_assemble_o ( clipper_start_assemble ),
        .idle_o           ( clipper_idle           ),
        .error_o          ( clipper_error          )
    );


//====================================================================================
//      TRIANGLE ASSEMBLER
//====================================================================================

    vertex_t assembled_vertex;
    logic assembled_valid, assembler_fifo_read, assembler_done, assembler_error;

    triangle_assembler assembler (
        .clk_i        ( clk_i                  ),
        .rst_n_i      ( rst_n_i                ),
        .stall_i      ( stall_i                ),
        .start_i      ( clipper_start_assemble ),
        .fifo_vtx_i   ( fifo_vtx_read          ),
        .fifo_empty_i ( buffer_empty           ),
        .fifo_read_o  ( assembler_fifo_read    ),
        .vertex_o     ( assembled_vertex       ),
        .valid_o      ( assembled_valid        ),
        .done_o       ( assembler_done         ),
        .error_o      ( assembler_error        )
    );


//====================================================================================
//      BUFFER CONTROL
//====================================================================================

    /* Downstream stall stops only the assembler; clipping can finish. */
    assign buffer_write = clipper_fifo_write & (state_CRT == CLIPPING);

        always_comb begin
            buffer_read = 1'b0;

            if (state_CRT == CLIPPING) begin
                buffer_read = clipper_fifo_read;
            end else if (state_CRT == ASSEMBLING) begin
                buffer_read = assembler_fifo_read;
            end
        end


//====================================================================================
//      OUTPUT MUX
//====================================================================================

    typedef enum logic [1:0] {VTX0, VTX1, VXT2} select_state_t;

    select_state_t select_state_CRT, select_state_NXT;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                select_state_CRT <= VTX0;
            end else if (!stall_i) begin
                select_state_CRT <= select_state_NXT;
            end
        end


    logic vtx_valid;

        always_comb begin
            /* Default Value */
            select_state_NXT = select_state_CRT;

            vtx_valid = 1'b0;

            case (select_state_CRT)
                VTX0: begin
                    if (direct_valid) begin
                        state_NXT = VTX1;

                        vtx_valid = 1'b1;
                    end
                end

                VTX1: begin
                    state_NXT = VTX2;

                    vtx_valid = 1'b1;
                end

                VTX2: begin
                    state_NXT = VTX0;

                    vtx_valid = 1'b1;
                end
            endcase
        end

        always_comb begin
            /* Fan order is (v0, v1, v2), (v0, v2, v3), ... */
            if (state_CRT == ASSEMBLING) begin
                vertex_o = assembled_vertex;
            end else begin
                vertex_o = triangle_i[select_state_CRT];
            end
        end

    assign valid_o = vtx_valid | ((state_CRT == ASSEMBLING) & assembled_valid);
    assign error_o = (state_CRT != IDLE) & (error_CRT | clipper_error | assembler_error);

endmodule : clip_engine

`endif
