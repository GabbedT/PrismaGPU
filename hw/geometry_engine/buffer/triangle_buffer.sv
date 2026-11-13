`ifndef TRIANGLE_BUFFER_SV
    `define TRIANGLE_BUFFER_SV

module triangle_buffer (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    input logic accept_i,
    input logic valid_i,
    input vertex_t vertex_i,

    output logic full_o,
    output logic valid_o,
    output triangle_t triangle_o
);

        always_ff @(posedge clk_i) begin
            if (!stall_i & valid_i & !full_o) begin
                triangle_o <= {vertex_i, triangle_o.vtx[2:1]};
            end
        end


    logic [2:0] fill_valid;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                fill_valid <= '0;
            end else if (!stall_i) begin
                if ((fill_valid == '1) & accept_i) begin
                    /* The producer is still stalled on this edge. Its held
                     * vertex can enter on the following cycle, after clear. */
                    fill_valid <= '0;
                end else if (valid_i & !full_o) begin
                    fill_valid <= {1'b1, fill_valid[2:1]};
                end
            end
        end

    assign valid_o = fill_valid == '1;

    /* Occupancy alone drives upstream backpressure. Do not send the clip
     * engine's geometry-dependent completion back to the matrix DSP enables.
     * Reusing this slot takes one cycle after triangle acceptance. */
    assign full_o = fill_valid == '1;

endmodule : triangle_buffer

`endif
