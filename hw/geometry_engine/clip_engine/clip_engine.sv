`ifndef CLIP_ENGINE_SV
    `define CLIP_ENGINE_SV

import triangle_pkg::*;

module clip_engine (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Triangle coming from triangle assembler */
    input triangle_t triangle_i,
    input logic valid_i,

    /* Triangle after clipping */
    output triangle_t triangle_o,
    output logic valid_o,

    /* Status */
    output logic done_o,
    output logic error_o
);

//====================================================================================
//      CLIP TESTER
//====================================================================================

    logic [5:0] vtx0_clip_code;
    logic [5:0] vtx1_clip_code;
    logic [5:0] vtx2_clip_code;

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

    logic triangle_inside;
    logic triangle_outside;
    logic triangle_clip;
    logic direct_valid;

    /* Trivial accept and reject tests */
    assign triangle_inside  = (vtx0_clip_code | vtx1_clip_code | vtx2_clip_code) == '0;
    assign triangle_outside =  (vtx0_clip_code & vtx1_clip_code & vtx2_clip_code) != '0;
    assign triangle_clip    = !triangle_inside & !triangle_outside;
    assign direct_valid     = valid_i & triangle_inside;


//====================================================================================
//      VERTEX BUFFER
//====================================================================================

    localparam integer VERTEX_WIDTH = $bits(vertex_t);

    logic buffer_empty;
    logic buffer_full;
    logic buffer_write;
    logic buffer_read;
    logic [VERTEX_WIDTH - 1:0] buffer_write_data;
    logic [VERTEX_WIDTH - 1:0] buffer_read_data;

    vertex_t fifo_vtx_read;
    vertex_t fifo_vtx_write;

    assign fifo_vtx_read = buffer_read_data;
    assign buffer_write_data = fifo_vtx_write;

    synchronous_buffer #(
        .BUFFER_DEPTH           ( 9            ),
        .DATA_WIDTH             ( VERTEX_WIDTH ),
        .FIRST_WORD_FALL_TROUGH ( 1            )
    ) vertex_buffer (
        .clk_i        ( clk_i              ),
        .rst_n_i      ( rst_n_i            ),
        .write_i      ( buffer_write       ),
        .read_i       ( buffer_read        ),
        .empty_o      ( buffer_empty       ),
        .full_o       ( buffer_full        ),
        .write_data_i ( buffer_write_data  ),
        .read_data_o  ( buffer_read_data   )
    );


//====================================================================================
//      CLIPPER
//====================================================================================

    logic clipper_start;
    logic clipper_fifo_write;
    logic clipper_fifo_read;
    logic clipper_start_assemble;
    logic clipper_idle;
    logic clipper_error;

    assign clipper_start = valid_i & triangle_clip & clipper_idle;

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

    triangle_t assembled_triangle;
    logic assembled_valid;
    logic assembler_fifo_read;
    logic assembler_done;
    logic assembler_error;

    triangle_assembler assembler (
        .clk_i        ( clk_i                  ),
        .rst_n_i      ( rst_n_i                ),
        .stall_i      ( stall_i                ),
        .start_i      ( clipper_start_assemble ),
        .fifo_vtx_i   ( fifo_vtx_read          ),
        .fifo_empty_i ( buffer_empty           ),
        .fifo_read_o  ( assembler_fifo_read    ),
        .triangle_o   ( assembled_triangle     ),
        .valid_o      ( assembled_valid       ),
        .done_o       ( assembler_done         ),
        .error_o      ( assembler_error        )
    );


//====================================================================================
//      BUFFER CONTROL
//====================================================================================

    /* Clipper and assembler never read the buffer at the same time */
    assign buffer_write = clipper_fifo_write;
    assign buffer_read  = clipper_fifo_read | assembler_fifo_read;


//====================================================================================
//      OUTPUT MUX
//====================================================================================

    always_comb begin
        /* The assembler triangle has priority while clipping is active */
        if (assembled_valid) begin
            triangle_o = assembled_triangle;
        end else begin
            triangle_o = triangle_i;
        end
    end

    assign valid_o = direct_valid | assembled_valid;
    assign done_o = assembler_done | direct_valid | (valid_i & triangle_outside);
    assign error_o = clipper_error | assembler_error;

endmodule : clip_engine

`endif
