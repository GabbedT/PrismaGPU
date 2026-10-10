`ifndef GEOMETRY_ENGINE_SV
    `define GEOMETRY_ENGINE_SV

module geometry_engine #(
    parameter integer INPUT_FIFO_DEPTH = 16,
    parameter integer TRIANGLE_DEPTH = 2,
    parameter integer OUTPUT_FIFO_DEPTH = 16
) (
    input logic clk_i,
    input logic rst_n_i,
    output logic interrupt_o,

    /* External memory unit; byte addresses and completed read/write job */
    output logic [31:0] vertex_buffer_base_o,
    output logic [31:0] vertex_buffer_end_o,
    output logic [31:0] primitive_buffer_base_o,
    output logic [31:0] primitive_buffer_end_o,
    input logic done_i,

    /* Input FIFO; writes on full are ignored unless a read makes room */
    input logic write_i,
    input logic [127:0] write_data_i,
    output logic [$clog2(INPUT_FIFO_DEPTH + 1) - 1:0] input_word_count_o,

    /* Output FIFO; synchronous reads, ignored on zero count */
    input logic read_i,
    output logic [127:0] read_data_o,
    output logic [$clog2(OUTPUT_FIFO_DEPTH + 1) - 1:0] output_word_count_o,

    /* Direct raster transfer; receiver accepts every cycle with valid high */
    output logic raster_valid_o,
    output proc_triangle_t raster_triangle_o,

    /* Register write; addresses are word offsets */
    input logic register_write_i,
    input logic [5:0] register_write_address_i,
    input logic [3:0][7:0] register_write_data_i,
    input logic [3:0] register_write_strobe_i,
    output logic register_write_error_o,

    /* Register read */
    input logic register_read_i,
    input logic [5:0] register_read_address_i,
    output logic [31:0] register_read_data_o,
    output logic register_read_error_o
);

    logic enable, soft_reset, enable_pcounters, forward_back, raster_forward;
    logic start_processing, stop_processing, processing;
    logic datapath_rst_n, pipeline_stall, pipeline_input_stall, unpacker_stall, packer_stall;
    logic busy, vertex_valid, triangle_valid, forward_valid;

    input_vertex_t vertex;
    vertex_t forward_vertex;
    proc_triangle_t triangle;
    triangle_error_t error;
    front_face_t front_face;
    cull_mode_t cull_mode;

    logic [3:0][3:0][31:0] coefficient;
    logic [31:0] width_screen, height_screen;
    logic [31:0] input_triangle_count, output_triangle_count;
    logic [31:0] discarded_triangle_count, stall_cycle_count;

//====================================================================================
//      CONTROL
//====================================================================================

    /* Soft reset flushes data and counters, preserving register configuration */
    assign datapath_rst_n = rst_n_i & !soft_reset;
    assign pipeline_stall = !enable | (packer_stall & !raster_forward);
    assign unpacker_stall = !enable | !processing | stop_processing | pipeline_input_stall;

    assign raster_triangle_o = triangle;
    assign raster_valid_o = triangle_valid & enable & raster_forward;

        /* STOP pauses input consumption; triangles already in the pipeline drain */
        always_ff @(posedge clk_i `ifdef ASYNC or negedge rst_n_i `endif) begin
            if (!rst_n_i) begin
                processing <= 1'b0;
            end else if (soft_reset | stop_processing) begin
                processing <= 1'b0;
            end else if (start_processing) begin
                processing <= 1'b1;
            end
        end


//====================================================================================
//      REGISTERS
//====================================================================================

    geometry_engine_registers registers (
        .clk_i        ( clk_i                         ),
        .rst_n_i      ( rst_n_i                       ),
        .stall_i      ( enable & pipeline_input_stall ),
        .soft_reset_o ( soft_reset                    ),
        .interrupt_o  ( interrupt_o                   ),

        .enable_o           ( enable           ),
        .start_processing_o ( start_processing ),
        .stop_processing_o  ( stop_processing  ),
        
        .front_face_o ( front_face ),
        .cull_mode_o  ( cull_mode  ),

        .forward_back_o   ( forward_back   ),
        .raster_forward_o ( raster_forward ),
        .forward_vertex_i ( forward_vertex ),
        .forward_valid_i  ( forward_valid  ),

        .enable_pcounters_o ( enable_pcounters ),

        .vertex_buffer_base_o ( vertex_buffer_base_o ),
        .vertex_buffer_end_o  ( vertex_buffer_end_o  ),

        .primitive_buffer_base_o ( primitive_buffer_base_o ),
        .primitive_buffer_end_o  ( primitive_buffer_end_o  ),

        .coefficient_o ( coefficient ),

        .width_screen_o  ( width_screen  ),
        .height_screen_o ( height_screen ),

        .busy_i  ( busy   ),
        .done_i  ( done_i ),
        .error_i ( error  ),
        
        .input_triangle_count_i     ( input_triangle_count     ),
        .output_triangle_count_i    ( output_triangle_count    ),
        .discarded_triangle_count_i ( discarded_triangle_count ),
        .stall_cycle_count_i        ( stall_cycle_count        ),

        .write_i         ( register_write_i         ),
        .write_address_i ( register_write_address_i ),
        .write_data_i    ( register_write_data_i    ),
        .write_strobe_i  ( register_write_strobe_i  ),
        .write_error_o   ( register_write_error_o   ),

        .read_i          ( register_read_i          ),
        .read_address_i  ( register_read_address_i  ),
        .read_data_o     ( register_read_data_o     ),
        .read_error_o    ( register_read_error_o    )
    );


//====================================================================================
//      UNPACKER
//====================================================================================

    triangle_unpacker #(
        .FIFO_DEPTH ( INPUT_FIFO_DEPTH )
    ) unpacker (
        .clk_i   ( clk_i          ),
        .rst_n_i ( datapath_rst_n ),
        .stall_i ( unpacker_stall ),

        .write_i      ( write_i & datapath_rst_n ),
        .write_data_i ( write_data_i             ),
        .word_count_o ( input_word_count_o       ),

        .vertex_o ( vertex       ),
        .valid_o  ( vertex_valid )
    );


//====================================================================================
//      PIPELINE
//====================================================================================

    geometry_engine_pipeline pipeline (
        .clk_i   ( clk_i                ),
        .rst_n_i ( datapath_rst_n       ),
        .stall_i ( pipeline_stall       ),
        .stall_o ( pipeline_input_stall ),

        .vertex_i ( vertex                         ),
        .valid_i  ( vertex_valid & !unpacker_stall ),

        .coefficient_i ( coefficient ),

        .forward_back_i   ( forward_back   ),
        .forward_vertex_o ( forward_vertex ),
        .forward_valid_o  ( forward_valid  ),

        .width_screen_i  ( width_screen  ),
        .height_screen_i ( height_screen ),

        .front_face_i ( front_face ),
        .cull_mode_i  ( cull_mode  ),

        .triangle_o ( triangle       ),
        .valid_o    ( triangle_valid ),
        .error_o    ( error          ),
        .busy_o     ( busy           ),

        .enable_pcounters_i         ( enable_pcounters            ),
        .input_triangle_count_o     ( input_triangle_count        ),
        .output_triangle_count_o    ( output_triangle_count       ),
        .discarded_triangle_count_o ( discarded_triangle_count    ),
        .stall_cycle_count_o        ( stall_cycle_count           )
    );


//====================================================================================
//      PACKER
//====================================================================================

    triangle_packer #(
        .TRIANGLE_DEPTH ( TRIANGLE_DEPTH    ),
        .FIFO_DEPTH     ( OUTPUT_FIFO_DEPTH )
    ) packer (
        .clk_i   ( clk_i          ),
        .rst_n_i ( datapath_rst_n ),
        .stall_o ( packer_stall   ),

        .triangle_i ( triangle                                  ),
        .valid_i    ( triangle_valid & enable & !raster_forward ),

        .read_i       ( read_i & datapath_rst_n ),
        .read_data_o  ( read_data_o         ),
        .word_count_o ( output_word_count_o )
    );

endmodule : geometry_engine

`endif
