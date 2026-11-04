`ifndef PRISMA_GPU_SV
    `define PRISMA_GPU_SV

module prismaGPU #(
    parameter integer INPUT_FIFO_DEPTH = 16,
    parameter integer TRIANGLE_DEPTH = 2,
    parameter integer OUTPUT_FIFO_DEPTH = 16
) (
    input logic clk_i,
    input logic rst_n_i,
    output logic interrupt_o,
    output logic busy_o,
    output logic done_o,

    /* Shared register bus: word bit 6 selects RE (byte base 0x100), otherwise GE. */
    input logic register_write_i,
    input logic [6:0] register_write_address_i,
    input logic [3:0][7:0] register_write_data_i,
    input logic [3:0] register_write_strobe_i,
    output logic register_write_error_o,
    input logic register_read_i,
    input logic [6:0] register_read_address_i,
    output logic [31:0] register_read_data_o,
    output logic register_read_error_o,

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

    logic ge_interrupt, re_interrupt, ge_idle, re_busy;
    logic ge_write_error, re_write_error, ge_read_error, re_read_error;
    logic [31:0] ge_read_data, re_read_data;
    proc_triangle_t raster_triangle;
    logic raster_valid, raster_stall;

    assign interrupt_o = ge_interrupt | re_interrupt;
    assign busy_o = !ge_idle | re_busy;
    assign register_write_error_o = ge_write_error | re_write_error;
    assign register_read_error_o = ge_read_error | re_read_error;
    assign register_read_data_o = register_read_address_i[6] ? re_read_data : ge_read_data;

    geometry_engine #(
        .INPUT_FIFO_DEPTH(INPUT_FIFO_DEPTH),
        .TRIANGLE_DEPTH(TRIANGLE_DEPTH),
        .OUTPUT_FIFO_DEPTH(OUTPUT_FIFO_DEPTH)
    ) ge (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .interrupt_o(ge_interrupt),
        .vertex_buffer_base_o(vertex_buffer_base_o),
        .vertex_buffer_end_o(vertex_buffer_end_o),
        .primitive_buffer_base_o(primitive_buffer_base_o),
        .primitive_buffer_end_o(primitive_buffer_end_o),
        .done_i(ge_done_i),
        .write_i(write_i),
        .write_data_i(write_data_i),
        .input_word_count_o(input_word_count_o),
        .read_i(read_i),
        .read_data_o(read_data_o),
        .output_word_count_o(output_word_count_o),
        .idle_o(ge_idle),
        .raster_triangle_o(raster_triangle),
        .raster_valid_o(raster_valid),
        .raster_stall_i(raster_stall),
        .register_write_i(register_write_i & !register_write_address_i[6]),
        .register_write_address_i(register_write_address_i[5:0]),
        .register_write_data_i(register_write_data_i),
        .register_write_strobe_i(register_write_strobe_i),
        .register_write_error_o(ge_write_error),
        .register_read_i(register_read_i & !register_read_address_i[6]),
        .register_read_address_i(register_read_address_i[5:0]),
        .register_read_data_o(ge_read_data),
        .register_read_error_o(ge_read_error)
    );

    raster_engine re (
        .clk_i(clk_i),
        .rst_n_i(rst_n_i),
        .interrupt_o(re_interrupt),
        .busy_o(re_busy),
        .done_o(done_o),
        .raster_triangle_i(raster_triangle),
        .raster_valid_i(raster_valid),
        .raster_stall_o(raster_stall),
        .stream_end_i(stream_end_i & ge_idle),
        .register_write_i(register_write_i & register_write_address_i[6]),
        .register_write_address_i(register_write_address_i[5:0]),
        .register_write_data_i(register_write_data_i),
        .register_write_strobe_i(register_write_strobe_i),
        .register_write_error_o(re_write_error),
        .register_read_i(register_read_i & register_read_address_i[6]),
        .register_read_address_i(register_read_address_i[5:0]),
        .register_read_data_o(re_read_data),
        .register_read_error_o(re_read_error),
        .read_ddr(read_ddr),
        .write_ddr(write_ddr)
    );

endmodule : prismaGPU

`endif
