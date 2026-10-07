/* One GPU memory, shared by the software port and the timed agent.
 * Timing and pending requests belong to the wrapper, not to this storage. */
module memory (
    input logic clk_i,

    /* Byte strobes allow software to access fields smaller than a GPU word. */
    input  logic sw_write_i,
    input  logic [15:0] sw_address_i,
    input  logic [127:0] sw_data_i,
    input  logic [15:0] sw_strobe_i,
    output logic [127:0] sw_data_o,

    input  logic agent_write_i,
    input  logic [15:0] agent_address_i,
    input  logic [127:0] agent_data_i,
    output logic [127:0] agent_data_o
);

    logic [127:0] words [4096];

    assign sw_data_o    = words[sw_address_i[15:4]];
    assign agent_data_o = words[agent_address_i[15:4]];


    always_ff @(posedge clk_i) begin
        if (agent_write_i) begin
            words[agent_address_i[15:4]] <= agent_data_i;
        end

        if (sw_write_i) begin
            for (int byte_index = 0; byte_index < 16; ++byte_index) begin
                if (sw_strobe_i[byte_index]) begin
                    words[sw_address_i[15:4]][byte_index * 8 +: 8] <= sw_data_i[byte_index * 8 +: 8];
                end
            end
        end

        assert (!(agent_write_i && sw_write_i && agent_address_i[15:4] == sw_address_i[15:4]))
            else $fatal(1, "GPU memory write collision");
    end

endmodule : memory
