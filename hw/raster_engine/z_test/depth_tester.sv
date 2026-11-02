`ifndef DEPTH_TESTER_SV
    `define DEPTH_TESTER_SV

module depth_tester #(
    parameter integer Z_WIDTH = 16
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic enable_i,
    input logic stall_i,

    input logic test_enable_i,
    input logic write_enable_i,

    /* 0 NEVER, 1 LESS, 2 EQUAL, 3 LEQUAL, 4 GREATER, 5 NOTEQUAL, 6 GEQUAL, 7 ALWAYS. */
    input logic [2:0] compare_i,
    input logic pixel_valid_i,
    output logic pixel_ready_o,
    input logic [9:0] pixel_x_i,
    input logic [Z_WIDTH - 1:0] pixel_z_i,
    input logic pixel_last_i,

    /* One result per accepted pixel, held while stall_i is asserted. */
    output logic result_valid_o,
    output logic pass_o,
    output logic discard_o,
    output logic line_done_o,
    output logic dirty_o,

    /* Z Buffer read */
    output logic z_read_o,
    output logic [9:0] z_read_address_o,
    input logic [Z_WIDTH - 1:0] z_read_data_i,
    input logic z_read_enabled_i,

    /* Z Buffer write */
    output logic z_write_o,
    output logic [9:0] z_write_address_o,
    output logic [Z_WIDTH - 1:0] z_write_data_o
);

//====================================================================================
//      PIXEL REGISTER
//====================================================================================

    logic valid_CRT, last_CRT, test_CRT, write_CRT;
    logic [2:0] compare_CRT;
    logic [9:0] x_CRT;
    logic [Z_WIDTH - 1:0] z_CRT, forward_CRT;
    logic forward_valid_CRT;
    logic accept_pixel, commit_pixel, comparison;
    logic [Z_WIDTH - 1:0] old_z;

    /* Do not accept a pixel for the following span on the final commit edge. */
    assign pixel_ready_o = enable_i & (!valid_CRT | (!stall_i & !last_CRT));
    assign accept_pixel = pixel_valid_i & pixel_ready_o;
    assign commit_pixel = valid_CRT & !stall_i;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                valid_CRT <= 1'b0;
            end else if (accept_pixel) begin
                valid_CRT <= 1'b1;
            end else if (commit_pixel) begin
                valid_CRT <= 1'b0;
            end
        end

        always_ff @(posedge clk_i) begin
            if (accept_pixel) begin
                x_CRT <= pixel_x_i;
                z_CRT <= pixel_z_i;
                last_CRT <= pixel_last_i;
                test_CRT <= test_enable_i;
                write_CRT <= write_enable_i;
                compare_CRT <= compare_i;

                /* BRAM read/write collisions need the just-committed depth. */
                forward_valid_CRT <= z_write_o & (z_write_address_o == pixel_x_i);
                forward_CRT <= z_write_data_o;
            end
        end

//====================================================================================
//      UNSIGNED DEPTH COMPARISON
//====================================================================================

    assign old_z = forward_valid_CRT ? forward_CRT : z_read_data_i;

        always_comb begin
            case (compare_CRT)
                3'd0: comparison = 1'b0;
                3'd1: comparison = (z_CRT < old_z);
                3'd2: comparison = (z_CRT == old_z);
                3'd3: comparison = (z_CRT <= old_z);
                3'd4: comparison = (z_CRT > old_z);
                3'd5: comparison = (z_CRT != old_z);
                3'd6: comparison = (z_CRT >= old_z);
                3'd7: comparison = 1'b1;
                default: comparison = 1'b0;
            endcase
        end

    assign result_valid_o = valid_CRT;
    assign pass_o = result_valid_o & z_read_enabled_i & (!test_CRT | comparison);
    assign discard_o = result_valid_o & !pass_o;
    assign line_done_o = commit_pixel & last_CRT;

    assign z_read_o = accept_pixel;
    assign z_read_address_o = pixel_x_i;

    assign z_write_o = commit_pixel & pass_o & test_CRT & write_CRT;
    assign z_write_address_o = x_CRT;
    assign z_write_data_o = z_CRT;

    assign dirty_o = z_write_o;

endmodule : depth_tester

`endif
