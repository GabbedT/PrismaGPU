`ifndef RASTER_TRIANGLE_BUFFER_SV
    `define RASTER_TRIANGLE_BUFFER_SV

module raster_triangle_buffer (
    input logic clk_i,
    input logic rst_n_i,
    input proc_triangle_t triangle_i,
    input logic valid_i,
    output logic stall_o,
    output proc_triangle_t triangle_o,
    output logic valid_o,
    input logic stall_i
);

    /* Both sides depend only on registered occupancy. In particular, a
     * downstream stall never propagates combinationally into the GE pipeline.
     * Two slots sustain one transfer per clock at occupancy one. A full queue
     * frees space on the next edge, without speculative same-cycle admission. */
    proc_triangle_t [1:0] triangles;
    logic read_CRT, write_CRT;
    logic [1:0] count_CRT;
    logic push, pop;

    assign stall_o = count_CRT == 2;
    assign valid_o = count_CRT != 0;
    assign triangle_o = triangles[read_CRT];
    assign push = valid_i & !stall_o;
    assign pop = valid_o & !stall_i;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            read_CRT <= 1'b0;
            write_CRT <= 1'b0;
            count_CRT <= '0;
        end else begin
            if (push) write_CRT <= !write_CRT;
            
            if (pop) read_CRT <= !read_CRT;

            case ({push, pop})
                2'b10: count_CRT <= count_CRT + 2'd1;

                2'b01: count_CRT <= count_CRT - 2'd1;

                default: begin end
            endcase
        end
    end

    /* Validity guards payload; resetting it would add unnecessary reset load. */
    always_ff @(posedge clk_i) begin
        if (push) triangles[write_CRT] <= triangle_i;
    end

endmodule : raster_triangle_buffer

`endif
