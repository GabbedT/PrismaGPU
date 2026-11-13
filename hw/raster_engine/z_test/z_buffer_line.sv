`ifndef Z_BUFFER_LINE_SV
    `define Z_BUFFER_LINE_SV

module z_buffer_line #(
    parameter integer Z_WIDTH = 16
) (
    input logic clk_i,
    input logic rst_n_i,

    /* To compare X coordinate */
    input re_viewport_size_t viewport_size_i,

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

    /* DDR interface. Pixel and DDR accesses must use different physical banks
     * when active together; bank selection alone does not constitute access. */
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
    logic [1:0][127:0] read_word;
    logic [Z_WIDTH - 1:0] pixel_read_data, pixel_hold;
    logic [127:0] ddr_read_data, ddr_hold;
    logic [15:0] ddr_mask;
    logic pixel_read_enable, pixel_write_enable, ddr_address_valid;
    logic [9:0] viewport_width;

    always_comb begin
        viewport_width = 10'd640;

        if (viewport_size_i == RE_VIEWPORT_320_240) begin
            viewport_width = 10'd320;
        end
    end

    assign pixel_read_enable = z_read_i & (z_read_address_i < viewport_width);
    assign pixel_write_enable = z_write_i & (z_write_address_i < viewport_width);
    assign ddr_address_valid = (ddr_address_i < viewport_width) & (ddr_address_i[LANE_BITS - 1:0] == '0);

    /* Fixed widths contain whole DDR words; span masks still select lanes. */
    always_comb begin
        ddr_mask = '0;
        
        if (ddr_address_valid) begin
            ddr_mask = ddr_mask_i;
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

    /* Each bank has one 128-bit synchronous read port and one byte-write port.
     * The front bank reads a word and selects one pixel; its independent write
     * address and byte mask update only that pixel's slot. The other bank uses
     * the same ports for wide DDR transfers. This exposes simple dual-port RAM
     * packing instead of separate shallow true dual-port RAMs for every lane.
     * No reset on RAM data or data outputs, to preserve BRAM inference. */
    for (genvar bank = 0; bank < 2; bank++) begin : banks
        (* ram_style = "block" *) logic [127:0] memory [0:WORDS - 1];
        logic pixel_read, pixel_write, dma_enable, read_enable;
        logic [WORD_BITS - 1:0] read_address, write_address;
        logic [SLOT_WIDTH - 1:0] pixel_slot;
        logic [127:0] write_data;
        logic [15:0] write_mask;

        assign pixel_read = pixel_read_enable & (buffer_select_i == bank[0]);
        assign pixel_write = pixel_write_enable & (buffer_select_i == bank[0]);
        assign dma_enable = ddr_address_valid & (ddr_buffer_select_i == bank[0]);
        assign read_enable = pixel_read | (dma_enable & ddr_read_i);
        assign read_address = pixel_read ? z_read_address_i[9:LANE_BITS] : ddr_address_i[9:LANE_BITS];
        assign write_address = pixel_write ? z_write_address_i[9:LANE_BITS] : ddr_address_i[9:LANE_BITS];
        assign pixel_slot = {{(SLOT_WIDTH - Z_WIDTH){1'b0}}, z_write_data_i};
        assign write_data = pixel_write ? {LANES{pixel_slot}} : ddr_write_data_i;

        always_comb begin
            write_mask = (dma_enable & ddr_write_i) ? ddr_mask : '0;
            if (pixel_write) begin
                write_mask = '0;
                write_mask[z_write_address_i[LANE_BITS - 1:0] * SLOT_BYTES +: SLOT_BYTES] = '1;
            end
        end

        always_ff @(posedge clk_i) begin
            if (read_enable) begin
                read_word[bank] <= memory[read_address];
            end
        end

        always_ff @(posedge clk_i) begin
            for (int byte_index = 0; byte_index < 16; byte_index++) begin
                if (write_mask[byte_index]) begin
                    memory[write_address][byte_index * 8 +: 8] <= write_data[byte_index * 8 +: 8];
                end
            end
        end
    end

    /* The RAM word is available on the read-response cycle. Save that response
     * on the following edge, before another interface can overwrite its bank's
     * read register. Each interface then holds its own data across bank swaps
     * and unrelated reads without adding a cycle to either response. */
    assign pixel_read_data = read_word[pixel_bank_CRT][pixel_lane_CRT * SLOT_WIDTH +: Z_WIDTH];
    assign ddr_read_data = ddr_read_valid_o ? read_word[ddr_bank_CRT] : ddr_hold;
    assign z_read_data_o = z_read_enabled_o ? (z_read_valid_o ? pixel_read_data : pixel_hold) : '0;

    always_ff @(posedge clk_i) begin
        if (z_read_valid_o) pixel_hold <= pixel_read_data;
        if (ddr_read_valid_o) ddr_hold <= read_word[ddr_bank_CRT];
    end

        always_comb begin
            ddr_read_data_o = '0;
            for (int byte_index = 0; byte_index < 16; byte_index++) begin
                if (ddr_read_mask_o[byte_index]) begin
                    ddr_read_data_o[byte_index * 8 +: 8] = ddr_read_data[byte_index * 8 +: 8];
                end
            end
        end

    initial begin
        assert ((Z_WIDTH > 0) & (Z_WIDTH <= 32)) else $fatal(1, "Z_WIDTH must be 1..32");
    end

    // synthesis translate_off
    always_ff @(posedge clk_i) begin
        if (rst_n_i) begin
            assert (!((pixel_read_enable | pixel_write_enable) & ddr_address_valid &
                      (ddr_read_i | ddr_write_i) & (buffer_select_i == ddr_buffer_select_i)))
                else $fatal(1, "Pixel and DDR accesses must use different Z banks");
        end
    end
    // synthesis translate_on

endmodule : z_buffer_line

`endif
