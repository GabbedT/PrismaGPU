`ifndef Z_BUFFER_LINE_SV
    `define Z_BUFFER_LINE_SV

module z_buffer_line #(
    parameter integer Z_WIDTH = 16
) (
    input logic clk_i,
    input logic rst_n_i,

    /* To compare X coordinate */
    input logic [9:0] viewport_width_i,

    /* Select between front/back buffer */
    input logic buffer_select_i,

    /* Independent pixel read/write addresses on the selected front bank. */
    input logic z_read_i,
    input logic [9:0] z_read_address_i,
    output logic [Z_WIDTH - 1:0] z_read_data_o,
    output logic z_read_valid_o,
    output logic z_read_enabled_o,
    input logic z_write_i,
    input logic [9:0] z_write_address_i,
    input logic [Z_WIDTH - 1:0] z_write_data_i,

    /* DDR interface */
    input logic ddr_buffer_select_i,
    input logic ddr_read_i,
    input logic ddr_write_i,
    input logic [9:0] ddr_address_i,
    input logic [127:0] ddr_write_data_i,
    input logic [15:0] ddr_mask_i,
    output logic [127:0] ddr_read_data_o,
    output logic [15:0] ddr_read_mask_o,
    output logic ddr_read_valid_o
);

//====================================================================================
//      PARAMETERS AND REGISTERS
//====================================================================================

    /* Unsigned Z, zero padded in 16-bit or 32-bit DDR slots. */
    localparam integer SLOT_WIDTH = (Z_WIDTH <= 16) ? 16 : 32;
    localparam integer SLOT_BYTES = SLOT_WIDTH / 8;
    localparam integer LANES = 128 / SLOT_WIDTH;
    localparam integer LANE_BITS = $clog2(LANES);
    localparam integer WORDS = 640 / LANES;
    localparam integer WORD_BITS = $clog2(WORDS);

    logic pixel_bank_CRT, ddr_bank_CRT;
    logic [LANE_BITS - 1:0] pixel_lane_CRT;
    logic [1:0][LANES - 1:0][SLOT_WIDTH - 1:0] pixel_data, ddr_data;
    logic [1:0][127:0] ddr_word;
    logic [15:0] ddr_mask;
    logic pixel_read_enable, pixel_write_enable, ddr_address_valid;

    assign pixel_read_enable = rst_n_i & z_read_i & (z_read_address_i < 640) & (z_read_address_i < viewport_width_i);
    assign pixel_write_enable = rst_n_i & z_write_i & (z_write_address_i < 640) & (z_write_address_i < viewport_width_i);
    assign ddr_address_valid = (ddr_address_i < 640) & (ddr_address_i[LANE_BITS - 1:0] == '0);
    assign ddr_word = ddr_data;

        always_comb begin
            ddr_mask = '0;

            for (int lane = 0; lane < LANES; lane++) begin
                if (ddr_address_valid & ((int'(ddr_address_i) + lane) < int'(viewport_width_i))) begin
                    ddr_mask[lane * SLOT_BYTES +: SLOT_BYTES] = ddr_mask_i[lane * SLOT_BYTES +: SLOT_BYTES];
                end
            end
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                z_read_valid_o <= 1'b0;
                z_read_enabled_o <= 1'b0;
                ddr_read_valid_o <= 1'b0;
                ddr_read_mask_o <= '0;
                pixel_bank_CRT <= 1'b0;
                ddr_bank_CRT <= 1'b0;
                pixel_lane_CRT <= '0;
            end else begin
                z_read_valid_o <= z_read_i;
                ddr_read_valid_o <= ddr_read_i;

                /* Hold data and its enable during a stalled depth comparison. */
                if (z_read_i) begin
                    z_read_enabled_o <= pixel_read_enable;
                    pixel_bank_CRT <= buffer_select_i;
                    pixel_lane_CRT <= z_read_address_i[LANE_BITS - 1:0];
                end

                if (ddr_read_i) begin
                    ddr_bank_CRT <= ddr_buffer_select_i;
                    ddr_read_mask_o <= ddr_mask;
                end
            end
        end

//====================================================================================
//      BANKED BLOCK RAM
//====================================================================================

    /* Each lane has a synchronous read port and a read/write port.
     * Front: pixel read + pixel write. Back: wide DDR read or byte write.
     * No reset on RAM data or data outputs, to preserve BRAM inference. */
    for (genvar bank = 0; bank < 2; bank++) begin : banks
        for (genvar lane = 0; lane < LANES; lane++) begin : lanes
            (* ram_style = "block" *) logic [SLOT_WIDTH - 1:0] memory [0:WORDS - 1];
            
            logic pixel_write, dma_enable;
            logic [WORD_BITS - 1:0] port_address;
            logic [SLOT_WIDTH - 1:0] port_data;
            logic [SLOT_BYTES - 1:0] port_mask;

            assign pixel_write = pixel_write_enable & (buffer_select_i == 1'(bank)) & (z_write_address_i[LANE_BITS - 1:0] == LANE_BITS'(lane));
            
            assign dma_enable = rst_n_i & ddr_address_valid & (ddr_buffer_select_i == 1'(bank));
            
            assign port_address = pixel_write ? WORD_BITS'(z_write_address_i >> LANE_BITS) : WORD_BITS'(ddr_address_i >> LANE_BITS);
            assign port_data = pixel_write ? SLOT_WIDTH'(z_write_data_i) : ddr_write_data_i[lane * SLOT_WIDTH +: SLOT_WIDTH];
            assign port_mask = pixel_write ? {SLOT_BYTES{1'b1}} : ((dma_enable & ddr_write_i) ? ddr_mask[lane * SLOT_BYTES +: SLOT_BYTES] : '0);

                always_ff @(posedge clk_i) begin
                    if (pixel_read_enable & (buffer_select_i == 1'(bank)) &
                        (z_read_address_i[LANE_BITS - 1:0] == LANE_BITS'(lane))) begin
                        pixel_data[bank][lane] <= memory[WORD_BITS'(z_read_address_i >> LANE_BITS)];
                    end
                end

                always_ff @(posedge clk_i) begin
                    for (int byte_index = 0; byte_index < SLOT_BYTES; byte_index++) begin
                        if (port_mask[byte_index]) begin
                            memory[port_address][byte_index * 8 +: 8] <= port_data[byte_index * 8 +: 8];
                        end
                    end

                    if (dma_enable & ddr_read_i) begin
                        ddr_data[bank][lane] <= memory[port_address];
                    end
                end
        end
    end

    assign z_read_data_o = z_read_enabled_o ? Z_WIDTH'(pixel_data[pixel_bank_CRT][pixel_lane_CRT]) : '0;

        always_comb begin
            ddr_read_data_o = '0;
            for (int byte_index = 0; byte_index < 16; byte_index++) begin
                if (ddr_read_mask_o[byte_index]) begin
                    ddr_read_data_o[byte_index * 8 +: 8] = ddr_word[ddr_bank_CRT][byte_index * 8 +: 8];
                end
            end
        end

    initial begin
        assert ((Z_WIDTH > 0) & (Z_WIDTH <= 32)) else $fatal(1, "Z_WIDTH must be 1..32");
    end

endmodule : z_buffer_line

`endif
