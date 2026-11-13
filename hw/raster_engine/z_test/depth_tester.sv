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

    /* Read and result stages each hold one pixel. result_load_o advances
     * matching attributes into the result stage, including rejected pixels. */
    output logic result_load_o,
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
//      ELASTIC READ AND RESULT STAGES
//====================================================================================

    /* The read stage matches the synchronous BRAM output. The result stage
     * registers the comparison before it can drive writeback or completion.
     * Both stages can advance together, preserving one pixel per clock. */
    logic read_valid_CRT, read_last_CRT, read_test_CRT, read_write_CRT;
    logic [2:0] read_compare_CRT;
    logic [9:0] read_x_CRT;
    logic [Z_WIDTH - 1:0] read_z_CRT, collision_z_CRT;
    logic collision_valid_CRT;
    logic result_valid_CRT, result_pass_CRT, result_write_CRT, result_last_CRT;
    logic [9:0] result_x_CRT;
    logic [Z_WIDTH - 1:0] result_z_CRT;
    logic accept_pixel, commit_pixel, result_ready, comparison;
    logic pending_write, sample_pass;
    logic [Z_WIDTH - 1:0] old_z;

    assign result_ready = !result_valid_CRT | !stall_i;
    assign result_load_o = read_valid_CRT & result_ready;

    /* A final pixel blocks admission until it commits, so its bank cannot
     * be reused while either stage still contains work from the old span. */
    assign pixel_ready_o = enable_i & (!read_valid_CRT | result_ready) &
                           !(read_valid_CRT & read_last_CRT) & !(result_valid_CRT & result_last_CRT);
    assign accept_pixel = pixel_valid_i & pixel_ready_o;
    assign commit_pixel = result_valid_CRT & !stall_i;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            read_valid_CRT <= 1'b0;
            result_valid_CRT <= 1'b0;
        end else begin
            if (accept_pixel) read_valid_CRT <= 1'b1;
            else if (result_load_o) read_valid_CRT <= 1'b0;

            if (result_ready) result_valid_CRT <= read_valid_CRT;
        end
    end

    /* Payload needs no reset; the corresponding stage-valid bit guards it. */
    always_ff @(posedge clk_i) begin
        if (accept_pixel) begin
            read_x_CRT <= pixel_x_i;
            read_z_CRT <= pixel_z_i;
            read_last_CRT <= pixel_last_i;
            read_test_CRT <= test_enable_i;
            read_write_CRT <= write_enable_i;
            read_compare_CRT <= compare_i;

            /* Preserve a write colliding with this synchronous BRAM read. */
            collision_valid_CRT <= z_write_o & (z_write_address_o == pixel_x_i);
            collision_z_CRT <= z_write_data_o;
        end

        if (result_load_o) begin
            result_pass_CRT <= sample_pass;
            result_write_CRT <= sample_pass & read_test_CRT & read_write_CRT;
            result_x_CRT <= read_x_CRT;
            result_z_CRT <= read_z_CRT;
            result_last_CRT <= read_last_CRT;
        end
    end

//====================================================================================
//      UNSIGNED DEPTH COMPARISON
//====================================================================================

    /* The older result may not have reached RAM when the new read occurred.
     * Its pending write is newer than the captured read/write collision, so
     * it wins on repeated X coordinates. In-order retirement makes it safe
     * to forward even while the older result is stalled. */
    assign pending_write = result_valid_CRT & result_write_CRT;
    assign old_z = (pending_write & (result_x_CRT == read_x_CRT)) ? result_z_CRT :
                   collision_valid_CRT ? collision_z_CRT : z_read_data_i;
    assign sample_pass = z_read_enabled_i & (!read_test_CRT | comparison);

    always_comb begin
        case (read_compare_CRT)
            3'd0: comparison = 1'b0;
            3'd1: comparison = (read_z_CRT < old_z);
            3'd2: comparison = (read_z_CRT == old_z);
            3'd3: comparison = (read_z_CRT <= old_z);
            3'd4: comparison = (read_z_CRT > old_z);
            3'd5: comparison = (read_z_CRT != old_z);
            3'd6: comparison = (read_z_CRT >= old_z);
            3'd7: comparison = 1'b1;
            default: comparison = 1'b0;
        endcase
    end

    assign result_valid_o = result_valid_CRT;
    assign pass_o = result_valid_CRT & result_pass_CRT;
    assign discard_o = result_valid_o & !pass_o;
    assign line_done_o = commit_pixel & result_last_CRT;

    assign z_read_o = accept_pixel;
    assign z_read_address_o = pixel_x_i;

    assign z_write_o = commit_pixel & result_write_CRT;
    assign z_write_address_o = result_x_CRT;
    assign z_write_data_o = result_z_CRT;

    assign dirty_o = z_write_o;

endmodule : depth_tester

`endif
