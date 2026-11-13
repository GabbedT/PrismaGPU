`ifndef PRISMA_GPU_SV
    `define PRISMA_GPU_SV

module prismaGPU #(
    parameter integer INPUT_FIFO_DEPTH  = 16,
    parameter integer TRIANGLE_DEPTH    = 2,
    parameter integer OUTPUT_FIFO_DEPTH = 16,
    
    // Match triangle_multiply_ip PipeStages when building with _VIVADO_.
    parameter integer MULTIPLIER_LATENCY = 0
) (
    input logic clk_i,
    input logic rst_n_i,
    output logic interrupt_o,
    output logic busy_o,
    output logic done_o,

    /* Shared register bus: word bit 6 selects RE (byte base 0x100), otherwise GE. */
    input logic reg_write_i,
    input logic [6:0] reg_write_address_i,
    input logic [3:0][7:0] reg_write_data_i,
    input logic [3:0] reg_write_strobe_i,
    output logic reg_write_error_o,

    /* A request is sampled on each rising edge. Read data/errors and the
     * write error describe that edge's access during the following cycle.
     * Reads may be issued every clock; simultaneous read/write returns old data. */
    input logic reg_read_i,
    input logic [6:0] reg_read_address_i,
    output logic [31:0] reg_read_data_o,
    output logic reg_read_error_o,

    /* Existing GE memory interface; the external feeder observes FIFO capacity. */
    output logic [31:0] vertex_buffer_base_o,
    output logic [31:0] vertex_buffer_end_o,
    output logic [31:0] primitive_buffer_base_o,
    output logic [31:0] primitive_buffer_end_o,
    input logic ge_done_i,
    input logic write_i,
    input logic [127:0] write_data_i,
    output logic [$clog2(INPUT_FIFO_DEPTH + 1) - 1:0] input_word_count_o,
    input logic read_i,
    output logic [127:0] read_data_o,
    output logic [$clog2(OUTPUT_FIFO_DEPTH + 1) - 1:0] output_word_count_o,

    /* Assert after the last input word (or with it), hold until done_o.
     * Deassert before starting the next stream. An input gap is not an end.
     * GE must finish every queued/partially unpacked triangle before RE drains. */
    input logic stream_end_i,
    gpu_ddr_interface.master read_ddr,
    gpu_ddr_interface.master write_ddr
);

//====================================================================================
//      INTERNAL SIGNALS
//====================================================================================

    logic ge_interrupt, re_interrupt, ge_idle, re_busy;
    logic ge_write_error, re_write_error, ge_read_error, re_read_error;
    logic [31:0] ge_read_data, re_read_data;
    logic [31:0] ge_read_data_CRT, re_read_data_CRT;
    logic read_bank_CRT, read_valid_CRT, read_error_CRT;
    proc_triangle_t raster_triangle;
    logic raster_valid, raster_stall;

//====================================================================================
//      STATUS AND REGISTER BUS
//====================================================================================

    assign interrupt_o        = ge_interrupt | re_interrupt;
    assign busy_o             = !ge_idle | re_busy;

    /* Register both inputs of the final bank mux. Capturing its selector and
     * error on the same edge keeps consecutive GE/RE requests aligned and
     * removes the combinational input-address to output-data path. */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            read_valid_CRT <= 1'b0;
            reg_write_error_o <= 1'b0;
        end else begin
            read_valid_CRT <= reg_read_i;
            reg_write_error_o <= ge_write_error | re_write_error;
        end
    end

    /* Payload has no reset: read_valid_CRT guards it after reset and bubbles. */
    always_ff @(posedge clk_i) begin
        if (reg_read_i) begin
            ge_read_data_CRT <= ge_read_data;
            re_read_data_CRT <= re_read_data;
            read_bank_CRT <= reg_read_address_i[6];
            read_error_CRT <= ge_read_error | re_read_error;
        end
    end

    assign reg_read_error_o = read_valid_CRT & read_error_CRT;
    assign reg_read_data_o = read_valid_CRT ? (read_bank_CRT ? re_read_data_CRT : ge_read_data_CRT) : '0;


//====================================================================================
//      GEOMETRY ENGINE
//====================================================================================

    geometry_engine #(
        .INPUT_FIFO_DEPTH  ( INPUT_FIFO_DEPTH  ),
        .TRIANGLE_DEPTH    ( TRIANGLE_DEPTH    ),
        .OUTPUT_FIFO_DEPTH ( OUTPUT_FIFO_DEPTH )
    ) ge (
        .clk_i                    ( clk_i                                 ),
        .rst_n_i                  ( rst_n_i                               ),
        .interrupt_o              ( ge_interrupt                          ),

        .vertex_buffer_base_o     ( vertex_buffer_base_o                  ),
        .vertex_buffer_end_o      ( vertex_buffer_end_o                   ),
        .primitive_buffer_base_o  ( primitive_buffer_base_o               ),
        .primitive_buffer_end_o   ( primitive_buffer_end_o                ),
        .done_i                   ( ge_done_i                             ),
        .write_i                  ( write_i                               ),
        .write_data_i             ( write_data_i                          ),
        .input_word_count_o       ( input_word_count_o                    ),
        .read_i                   ( read_i                                ),
        .read_data_o              ( read_data_o                           ),
        .output_word_count_o      ( output_word_count_o                   ),

        .idle_o                   ( ge_idle                               ),
        .raster_triangle_o        ( raster_triangle                       ),
        .raster_valid_o           ( raster_valid                          ),
        .raster_stall_i           ( raster_stall                          ),

        .register_write_i         ( reg_write_i & !reg_write_address_i[6] ),
        .register_write_address_i ( reg_write_address_i[5:0]              ),
        .register_write_data_i    ( reg_write_data_i                      ),
        .register_write_strobe_i  ( reg_write_strobe_i                    ),
        .register_write_error_o   ( ge_write_error                        ),

        .register_read_i          ( reg_read_i & !reg_read_address_i[6]   ),
        .register_read_address_i  ( reg_read_address_i[5:0]               ),
        .register_read_data_o     ( ge_read_data                          ),
        .register_read_error_o    ( ge_read_error                         )
    );


//====================================================================================
//      RASTER ENGINE
//====================================================================================

    raster_engine #(.MULTIPLIER_LATENCY(MULTIPLIER_LATENCY)) re (
        .clk_i                    ( clk_i                                ),
        .rst_n_i                  ( rst_n_i                              ),
        .interrupt_o              ( re_interrupt                         ),
        .busy_o                   ( re_busy                              ),
        .done_o                   ( done_o                               ),

        .raster_triangle_i        ( raster_triangle                      ),
        .raster_valid_i           ( raster_valid                         ),
        .raster_stall_o           ( raster_stall                         ),
        .stream_end_i             ( stream_end_i & ge_idle               ),

        .register_write_i         ( reg_write_i & reg_write_address_i[6] ),
        .register_write_address_i ( reg_write_address_i[5:0]             ),
        .register_write_data_i    ( reg_write_data_i                     ),
        .register_write_strobe_i  ( reg_write_strobe_i                   ),
        .register_write_error_o   ( re_write_error                       ),

        .register_read_i          ( reg_read_i & reg_read_address_i[6]   ),
        .register_read_address_i  ( reg_read_address_i[5:0]              ),
        .register_read_data_o     ( re_read_data                         ),
        .register_read_error_o    ( re_read_error                        ),

        .read_ddr                 ( read_ddr                             ),
        .write_ddr                ( write_ddr                            )
    );

endmodule : prismaGPU

`endif
