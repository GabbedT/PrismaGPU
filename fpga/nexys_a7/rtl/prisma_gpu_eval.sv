// Wiring-only OOC boundary; no registers, protocol adapters, or tied inputs.
module prisma_gpu_eval #(
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

    /* Fixed one-clock MMIO response implemented inside prismaGPU. */
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
    output logic read_ddr_trx_req_o,
    output logic read_ddr_trx_type_o,
    output logic [31:0] read_ddr_trx_addr_o,
    input logic read_ddr_ready_i,
    output logic [15:0] read_ddr_wstrobe_o,
    output logic [127:0] read_ddr_wdata_o,
    input logic read_ddr_read_valid_i,
    input logic read_ddr_read_error_i,
    input logic [127:0] read_ddr_rdata_i,
    input logic read_ddr_write_valid_i,
    input logic read_ddr_write_error_i,
    output logic write_ddr_trx_req_o,
    output logic write_ddr_trx_type_o,
    output logic [31:0] write_ddr_trx_addr_o,
    input logic write_ddr_ready_i,
    output logic [15:0] write_ddr_wstrobe_o,
    output logic [127:0] write_ddr_wdata_o,
    input logic write_ddr_read_valid_i,
    input logic write_ddr_read_error_i,
    input logic [127:0] write_ddr_rdata_i,
    input logic write_ddr_write_valid_i,
    input logic write_ddr_write_error_i
);

    gpu_ddr_interface read_ddr();
    gpu_ddr_interface write_ddr();

    assign read_ddr_trx_req_o = read_ddr.trx_req;
    assign read_ddr_trx_type_o = read_ddr.trx_type;
    assign read_ddr_trx_addr_o = read_ddr.trx_addr;
    assign read_ddr_wstrobe_o = read_ddr.wstrobe;
    assign read_ddr_wdata_o = read_ddr.wdata;
    assign read_ddr.ready = read_ddr_ready_i;
    assign read_ddr.read_valid = read_ddr_read_valid_i;
    assign read_ddr.read_error = read_ddr_read_error_i;
    assign read_ddr.rdata = read_ddr_rdata_i;
    assign read_ddr.write_valid = read_ddr_write_valid_i;
    assign read_ddr.write_error = read_ddr_write_error_i;
    assign write_ddr_trx_req_o = write_ddr.trx_req;
    assign write_ddr_trx_type_o = write_ddr.trx_type;
    assign write_ddr_trx_addr_o = write_ddr.trx_addr;
    assign write_ddr_wstrobe_o = write_ddr.wstrobe;
    assign write_ddr_wdata_o = write_ddr.wdata;
    assign write_ddr.ready = write_ddr_ready_i;
    assign write_ddr.read_valid = write_ddr_read_valid_i;
    assign write_ddr.read_error = write_ddr_read_error_i;
    assign write_ddr.rdata = write_ddr_rdata_i;
    assign write_ddr.write_valid = write_ddr_write_valid_i;
    assign write_ddr.write_error = write_ddr_write_error_i;

    prismaGPU #(
        .INPUT_FIFO_DEPTH(INPUT_FIFO_DEPTH),
        .TRIANGLE_DEPTH(TRIANGLE_DEPTH),
        .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH),
        .MULTIPLIER_LATENCY(MULTIPLIER_LATENCY)
    ) gpu (.*);

endmodule : prisma_gpu_eval
