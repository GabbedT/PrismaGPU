/* Instrument the hardware modules, not the simulation wrapper. */
/* verilator coverage_off */
module tb_top (
    input logic clk_i,
    input logic rst_n_i,

    /* GE buffer interface */
    input  logic done_i,
    output logic interrupt_o,
    output logic [31:0] vertex_buffer_base_o,
    output logic [31:0] vertex_buffer_end_o,
    output logic [31:0] primitive_buffer_base_o,
    output logic [31:0] primitive_buffer_end_o,

    input  logic write_i,
    input  logic read_i,
    input  logic [127:0] write_data_i,
    output logic [127:0] read_data_o,
    output logic [4:0] input_word_count_o,
    output logic [4:0] output_word_count_o,

    /* MMIO register interface */
    input  logic register_write_i,
    input  logic register_read_i,
    input  logic [5:0] register_write_address_i,
    input  logic [5:0] register_read_address_i,
    input  logic [31:0] register_write_data_i,
    input  logic [3:0] register_write_strobe_i,
    output logic register_write_error_o,
    output logic register_read_error_o,
    output logic [31:0] register_read_data_o,

    /* Software access to GPU memory */
    input  logic sw_write_i,
    input  logic [15:0] sw_address_i,
    input  logic [127:0] sw_data_i,
    input  logic [15:0] sw_strobe_i,
    output logic [127:0] sw_data_o,

    /* Timed agent access to the same GPU memory */
    input  logic agent_write_i,
    input  logic [15:0] agent_address_i,
    input  logic [127:0] agent_data_i,
    output logic [127:0] agent_data_o,

    /* Passive pipeline monitors */
    output logic idle_o,
    output logic input_blocked_o,
    output logic output_blocked_o,
    output logic [1:0] error_o,
    output logic [6:0] stage_valid_o,
    output logic [6:0][623:0] stage_data_o
);

    /* The GE already contains its input and output FIFOs (synchronous read). */
    geometry_engine dut (.*, .raster_valid_o(), .raster_triangle_o());
    memory mem (.*);

    assign idle_o = !dut.busy
                 && input_word_count_o == 0
                 && !dut.unpacker.fifo_valid
                 && output_word_count_o == 0
                 && dut.packer.triangle_count == 0
                 && !dut.packer.triangle_valid;

    assign error_o = dut.error;
    assign input_blocked_o = input_word_count_o == 16;
    assign output_blocked_o = dut.packer_stall;


    assign stage_valid_o = {
        dut.packer.write_enable,
        dut.pipeline.valid_o && !dut.pipeline_stall,
        dut.pipeline.viewport_valid && !dut.pipeline.viewport_stall,
        dut.pipeline.perspective_valid && !dut.pipeline.perspective_stall,
        dut.pipeline.clip_valid && !dut.pipeline.clip_stall,
        dut.pipeline.matrix_valid && !dut.pipeline.stall_o,
        dut.vertex_valid && !dut.unpacker_stall
    };

    assign stage_data_o[0] = 624'(dut.vertex);
    assign stage_data_o[1] = 624'(dut.pipeline.matrix_vertex);
    assign stage_data_o[2] = 624'(dut.pipeline.clip_vertex);
    assign stage_data_o[3] = 624'(dut.pipeline.perspective_vertex);
    assign stage_data_o[4] = 624'(dut.pipeline.viewport_vertex);
    assign stage_data_o[5] = 624'(dut.triangle);
    assign stage_data_o[6] = 624'(dut.packer.write_data);


    initial begin
        assert ($bits(input_vertex_t) == 170 && $bits(vertex_t) == 208 && $bits(triangle_t) == 624)
            else $fatal(1, "Input record layout changed; update the software codec");

        assert ($bits(proc_vertex_t) == 158 && $bits(proc_triangle_t) == 512)
            else $fatal(1, "Output record layout changed; update the software codec");
    end

    input_fifo_space: assert property (
        @(posedge clk_i) disable iff (!rst_n_i)
        write_i |-> input_word_count_o < 16
    );

    output_fifo_data: assert property (
        @(posedge clk_i) disable iff (!rst_n_i)
        read_i |-> output_word_count_o != 0
    );

    done_after_drain: assert property (
        @(posedge clk_i) disable iff (!rst_n_i)
        done_i |-> idle_o
    );

    unpacker_stall_holds: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        dut.unpacker_stall
        |=> $stable({dut.unpacker.state_CRT, dut.unpacker.fifo_valid, dut.unpacker.fifo_data})
    );

    no_duplicate_pack: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        dut.pipeline_stall |-> !dut.packer.triangle_write
    );

    clip_read_nonempty: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        dut.pipeline.clip_transform.buffer_read |-> !dut.pipeline.clip_transform.buffer_empty
    );

    clip_write_space: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        dut.pipeline.clip_transform.buffer_write |-> !dut.pipeline.clip_transform.buffer_full
    );

    clip_stall_holds: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        dut.pipeline.clip_stall |=> $stable(dut.pipeline.clip_transform.triangle_clipper.state_CRT)
    );

    /* Counters change only when the corresponding transfer is accepted. */
    input_counter_accept: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        !(dut.enable_pcounters && dut.pipeline.clip_done) |=> $stable(dut.input_triangle_count)
    );

    output_counter_accept: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        !(dut.enable_pcounters && dut.pipeline.output_triangle_accept)
        |=> $stable(dut.output_triangle_count)
    );

    clip_input_stable: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        dut.pipeline.triangle_valid && !dut.pipeline.clip_done
        |=> $stable(dut.pipeline.buffered_triangle)
    );

    input_fifo_count: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        !(dut.unpacker.write_enable ^ dut.unpacker.read_enable) |=> $stable(input_word_count_o)
    );

    output_fifo_count: assert property (
        @(posedge clk_i) disable iff (!dut.datapath_rst_n)
        !(dut.packer.write_enable ^ dut.packer.read_enable) |=> $stable(output_word_count_o)
    );

endmodule : tb_top
/* verilator coverage_on */
