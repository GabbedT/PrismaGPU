`ifndef TEXEL_MEMORY_SV
    `define TEXEL_MEMORY_SV

module texel_memory (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* 512 words of eight RGBA4444 texels; lowest texel occupies bits [15:0]. */
    input logic write_en_i,
    input logic [8:0] write_address_i,
    input logic [127:0] write_data_i,

    /* Fixed 64-texel row stride: address = {v[5:0], u[5:0]}. */
    input logic read_en_i,
    input logic [11:0] read_address_i,
    output logic [15:0] texel_o,
    output logic read_valid_o
);

    (* ram_style = "block" *) logic [127:0] memory [0:511];
    logic [127:0] read_word;
    logic [2:0] read_lane;
    logic word_valid;

    /* Loading is independent of fragment stalls. Reset preserves the RAM.
     * A simultaneous read/write of one word returns its old contents. */
    always_ff @(posedge clk_i) begin
        if (write_en_i) begin
            memory[write_address_i] <= write_data_i;
        end
        
        if (!stall_i & read_en_i) begin
            read_word <= memory[read_address_i[11:3]];
        end
    end

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            word_valid <= 1'b0;
            read_valid_o <= 1'b0;
        end else if (!stall_i) begin
            word_valid <= read_en_i;
            read_valid_o <= word_valid;
        end
    end

    /* Register the lane selector with the RAM read, then select one texel. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            if (read_en_i) begin
                read_lane <= read_address_i[2:0];
            end
            if (word_valid) begin
                texel_o <= read_word[16 * read_lane +: 16];
            end
        end
    end

endmodule : texel_memory

`endif
