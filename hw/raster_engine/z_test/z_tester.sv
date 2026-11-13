`ifndef Z_TESTER_SV
    `define Z_TESTER_SV

module z_tester #(
    parameter integer Z_WIDTH = 16,
    parameter integer ADDRESS_WIDTH = 32
) (
    input logic clk_i,
    input logic rst_n_i,
    input re_viewport_size_t viewport_size_i,

    input logic start_i,
    output logic request_o,
    input logic [ADDRESS_WIDTH - 1:0] line_address_i,
    input logic [9:0] x_start_i,
    input logic [9:0] x_end_i,
    input logic last_line_i,

    input logic next_valid_i,
    output logic next_ready_o,
    input logic [ADDRESS_WIDTH - 1:0] next_line_address_i,
    input logic [9:0] next_x_start_i,
    input logic [9:0] next_x_end_i,
    input logic next_last_line_i,

    output logic new_line_o,
    output logic [9:0] active_x_start_o,
    output logic [9:0] active_x_end_o,
    output logic done_o,

    /* Hold input while stall_o is high. Read and result stages are elastic;
     * result_load_o advances matching attributes into the result stage. */
    input logic pixel_valid_i,
    input logic [9:0] pixel_x_i,
    input logic [Z_WIDTH - 1:0] pixel_z_i,
    input logic test_enable_i,
    input logic write_enable_i,
    input logic [2:0] compare_i,
    output logic stall_o,
    input logic stall_i,
    output logic result_load_o,
    output logic result_valid_o,
    output logic pixel_valid_o,
    output logic discard_o,

    /* Exclusive clear service, accepted only with the scanline engine idle. */
    input logic clear_valid_i,
    output logic clear_ready_o,
    output logic clear_done_o,
    input logic [Z_WIDTH - 1:0] clear_depth_i,
    input logic [ADDRESS_WIDTH - 1:0] clear_base_i,

    /* DDR Interface */
    output logic ddr_request_o,
    input logic ddr_ready_i,
    output logic ddr_write_o,
    output logic [ADDRESS_WIDTH - 1:0] ddr_address_o,
    output logic [127:0] ddr_write_data_o,
    output logic [15:0] ddr_mask_o,
    input logic ddr_response_valid_i,
    input logic [127:0] ddr_read_data_i
);

//====================================================================================
//      INTERNAL INTERFACES
//====================================================================================

    logic buffer_select, line_ready, line_done, dirty, pixel_ready, pixel_in_span;
    logic z_read, z_write, z_read_enabled;
    logic [9:0] z_read_address, z_write_address;
    logic [Z_WIDTH - 1:0] z_read_data, z_write_data;
    logic buffer_ddr_select, buffer_ddr_read, buffer_ddr_write, buffer_ddr_read_valid;
    logic [9:0] buffer_ddr_address;
    logic [127:0] buffer_ddr_write_data, buffer_ddr_read_data;
    logic [15:0] buffer_ddr_mask, buffer_ddr_read_mask;

    assign pixel_in_span = (pixel_x_i >= active_x_start_o) && (pixel_x_i <= active_x_end_o);
    assign stall_o = !pixel_ready || (pixel_valid_i && !pixel_in_span);

//====================================================================================
//      DOUBLE BUFFER CONTROLLER
//====================================================================================


//====================================================================================
//      CLEAR AND SCANLINE DDR ARBITRATION
//====================================================================================

    logic clear_busy, clear_request;
    logic [ADDRESS_WIDTH - 1:0] clear_address;
    logic [127:0] clear_data;
    logic [15:0] clear_mask;
    logic normal_request, normal_write, normal_idle;
    logic [ADDRESS_WIDTH - 1:0] normal_address;
    logic [127:0] normal_data;
    logic [15:0] normal_mask;
    assign clear_ready_o = normal_idle && !clear_busy && !start_i;
    assign request_o = normal_idle && !clear_busy;
    assign ddr_request_o = clear_busy ? clear_request : normal_request;
    assign ddr_write_o = clear_busy ? 1'b1 : normal_write;
    assign ddr_address_o = clear_busy ? clear_address : normal_address;
    assign ddr_write_data_o = clear_busy ? clear_data : normal_data;
    assign ddr_mask_o = clear_busy ? clear_mask : normal_mask;

    z_clear #(
        .Z_WIDTH       ( Z_WIDTH       ),
        .ADDRESS_WIDTH ( ADDRESS_WIDTH )
    ) clear_engine (
        .clk_i           ( clk_i                             ),
        .rst_n_i         ( rst_n_i                           ),
        .start_i         ( clear_valid_i && clear_ready_o    ),
        .depth_i         ( clear_depth_i                     ),
        .base_i          ( clear_base_i                      ),
        .viewport_size_i ( viewport_size_i                   ),
        .busy_o          ( clear_busy                        ),
        .done_o          ( clear_done_o                      ),
        .request_o       ( clear_request                     ),
        .ready_i         ( ddr_ready_i && clear_busy         ),
        .response_i      ( ddr_response_valid_i && clear_busy ),
        .address_o       ( clear_address                     ),
        .data_o          ( clear_data                        ),
        .mask_o          ( clear_mask                        )
    );

    z_buffer_controller #(
        .Z_WIDTH       ( Z_WIDTH       ),
        .ADDRESS_WIDTH ( ADDRESS_WIDTH )
    ) controller (
        .clk_i                   ( clk_i                               ),
        .rst_n_i                 ( rst_n_i && !clear_busy              ),
        .start_i                 ( start_i && !clear_busy              ),
        .request_o               ( normal_idle                         ),
        .line_address_i          ( line_address_i                      ),
        .x_start_i               ( x_start_i                           ),
        .x_end_i                 ( x_end_i                             ),
        .last_line_i             ( last_line_i                         ),
        .next_valid_i            ( next_valid_i                        ),
        .next_ready_o            ( next_ready_o                        ),
        .next_line_address_i     ( next_line_address_i                 ),
        .next_x_start_i          ( next_x_start_i                      ),
        .next_x_end_i            ( next_x_end_i                        ),
        .next_last_line_i        ( next_last_line_i                    ),
        .buffer_select_o         ( buffer_select                       ),
        .line_ready_o            ( line_ready                          ),
        .new_line_o              ( new_line_o                          ),
        .active_x_start_o        ( active_x_start_o                    ),
        .active_x_end_o          ( active_x_end_o                      ),
        .line_done_i             ( line_done                           ),
        .dirty_i                 ( dirty                               ),
        .done_o                  ( done_o                              ),
        .buffer_ddr_select_o     ( buffer_ddr_select                   ),
        .buffer_ddr_read_o       ( buffer_ddr_read                     ),
        .buffer_ddr_write_o      ( buffer_ddr_write                    ),
        .buffer_ddr_address_o    ( buffer_ddr_address                  ),
        .buffer_ddr_write_data_o ( buffer_ddr_write_data               ),
        .buffer_ddr_mask_o       ( buffer_ddr_mask                     ),
        .buffer_ddr_read_data_i  ( buffer_ddr_read_data                ),
        .buffer_ddr_read_mask_i  ( buffer_ddr_read_mask                ),
        .buffer_ddr_read_valid_i ( buffer_ddr_read_valid               ),
        .ddr_request_o           ( normal_request                      ),
        .ddr_ready_i             ( ddr_ready_i && !clear_busy          ),
        .ddr_write_o             ( normal_write                        ),
        .ddr_address_o           ( normal_address                      ),
        .ddr_write_data_o        ( normal_data                         ),
        .ddr_mask_o              ( normal_mask                         ),
        .ddr_response_valid_i    ( ddr_response_valid_i && !clear_busy ),
        .ddr_read_data_i         ( ddr_read_data_i                     )
    );

//====================================================================================
//      PIXEL DEPTH TEST
//====================================================================================

    depth_tester #(
        .Z_WIDTH ( Z_WIDTH )
    ) tester (
        .clk_i             ( clk_i                          ),
        .rst_n_i           ( rst_n_i                        ),
        .enable_i          ( line_ready                     ),
        .stall_i           ( stall_i                        ),
        .test_enable_i     ( test_enable_i                  ),
        .write_enable_i    ( write_enable_i                 ),
        .compare_i         ( compare_i                      ),
        .pixel_valid_i     ( pixel_valid_i && pixel_in_span ),
        .pixel_ready_o     ( pixel_ready                    ),
        .pixel_x_i         ( pixel_x_i                      ),
        .pixel_z_i         ( pixel_z_i                      ),
        .pixel_last_i      ( pixel_x_i == active_x_end_o    ),
        .result_load_o     ( result_load_o                 ),
        .result_valid_o    ( result_valid_o                 ),
        .pass_o            ( pixel_valid_o                  ),
        .discard_o         ( discard_o                      ),
        .line_done_o       ( line_done                      ),
        .dirty_o           ( dirty                          ),
        .z_read_o          ( z_read                         ),
        .z_read_address_o  ( z_read_address                 ),
        .z_read_data_i     ( z_read_data                    ),
        .z_read_enabled_i  ( z_read_enabled                 ),
        .z_write_o         ( z_write                        ),
        .z_write_address_o ( z_write_address                ),
        .z_write_data_o    ( z_write_data                   )
    );

//====================================================================================
//      TWO SCANLINE BANKS
//====================================================================================

    z_buffer_line #(
        .Z_WIDTH ( Z_WIDTH )
    ) line_buffer (
        .clk_i               ( clk_i                 ),
        .rst_n_i             ( rst_n_i               ),
        .viewport_size_i     ( viewport_size_i       ),
        .buffer_select_i     ( buffer_select         ),
        .z_read_i            ( z_read                ),
        .z_read_address_i    ( z_read_address        ),
        .z_read_data_o       ( z_read_data           ),
        .z_read_valid_o      (                       ),
        .z_read_enabled_o    ( z_read_enabled        ),
        .z_write_i           ( z_write               ),
        .z_write_address_i   ( z_write_address       ),
        .z_write_data_i      ( z_write_data          ),
        .ddr_buffer_select_i ( buffer_ddr_select     ),
        .ddr_read_i          ( buffer_ddr_read       ),
        .ddr_write_i         ( buffer_ddr_write      ),
        .ddr_address_i       ( buffer_ddr_address    ),
        .ddr_write_data_i    ( buffer_ddr_write_data ),
        .ddr_mask_i          ( buffer_ddr_mask       ),
        .ddr_read_data_o     ( buffer_ddr_read_data  ),
        .ddr_read_mask_o     ( buffer_ddr_read_mask  ),
        .ddr_read_valid_o    ( buffer_ddr_read_valid )
    );

endmodule : z_tester

`endif
