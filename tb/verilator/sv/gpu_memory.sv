/* Simulation-only shared DDR: host, GE feeder/store, and RE read/write channels. */
module gpu_memory #(
    parameter int BYTES = 8 * 1024 * 1024
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic [31:0] latency_i,
    input logic [31:0] gap_i,
    input logic [31:0] seed_i,
    input logic [31:0] ge_read_address_i,
    output logic [127:0] ge_read_data_o,
    input logic ge_write_i,
    input logic [31:0] ge_write_address_i,
    input logic [127:0] ge_write_data_i,
    output logic read_pending_o,
    output logic write_pending_o,
    gpu_ddr_interface.slave rd,
    gpu_ddr_interface.slave wr
);

//====================================================================================
//      STORAGE AND HOST ACCESS
//====================================================================================

    /* verilator tracing_off */
    byte unsigned memory [BYTES];
    /* verilator tracing_on */
    export "DPI-C" function gpu_mem_read;
    export "DPI-C" function gpu_mem_write;

    function int unsigned gpu_mem_read(input int unsigned address);
        assert (address <= BYTES - 4 && address[1:0] == 0)
            else $fatal(1, "Host memory read outside aligned GPU RAM: %h", address);
        return {memory[address+3], memory[address+2], memory[address+1], memory[address]};
    endfunction

    function void gpu_mem_write(input int unsigned address, input int unsigned data,
                               input int unsigned strobe);
        assert (address <= BYTES - 4 && address[1:0] == 0)
            else $fatal(1, "Host memory write outside aligned GPU RAM: %h", address);
        for (int b = 0; b < 4; b++)
            if (strobe[b]) memory[address+b] = data[8*b +: 8];
    endfunction

    always_comb begin
        ge_read_data_o = '0;
        if (ge_read_address_i <= BYTES - 16)
            for (int b = 0; b < 16; b++) ge_read_data_o[8*b +: 8] = memory[ge_read_address_i+b];
    end

//====================================================================================
//      DDR REQUESTS AND DELAYED RESPONSES
//====================================================================================

    logic [31:0] random_state, read_address, write_address;
    logic [31:0] read_delay, write_delay, read_gap, write_gap;
    logic [127:0] write_data;
    logic [15:0] write_mask;
    logic read_fault, write_fault;

    assign rd.ready = rst_n_i && !read_pending_o && read_gap == 0;
    assign wr.ready = rst_n_i && !write_pending_o && write_gap == 0;
    assign rd.write_valid = 1'b0;
    assign rd.write_error = 1'b0;
    assign wr.read_valid = 1'b0;
    assign wr.read_error = 1'b0;
    assign wr.rdata = '0;

    always_ff @(posedge clk_i) begin
        rd.read_valid <= 1'b0;
        wr.write_valid <= 1'b0;
        rd.read_error <= 1'b0;
        wr.write_error <= 1'b0;
        if (!rst_n_i) begin
            random_state <= seed_i == 0 ? 32'd1 : seed_i;
            read_pending_o <= 1'b0;
            write_pending_o <= 1'b0;
            read_gap <= '0;
            write_gap <= '0;
            rd.rdata <= '0;
        end else begin
            random_state <= {random_state[30:0], random_state[31] ^ random_state[21] ^ random_state[1] ^ random_state[0]};
            if (read_gap != 0) read_gap <= read_gap - 1;
            if (write_gap != 0) write_gap <= write_gap - 1;
            if (ge_write_i) begin
                assert (ge_write_address_i <= BYTES - 16 && ge_write_address_i[3:0] == 0)
                    else $fatal(1, "GE store outside GPU RAM");
                for (int b = 0; b < 16; b++) memory[ge_write_address_i+b] <= ge_write_data_i[8*b +: 8];
            end
            if (rd.trx_req && rd.ready) begin
                read_pending_o <= 1'b1;
                read_address <= rd.trx_addr;
                read_delay <= latency_i + {29'b0, random_state[2:0]};
                read_fault <= rd.trx_type || rd.trx_addr[3:0] != 0 || rd.trx_addr > BYTES - 16;
            end
            if (wr.trx_req && wr.ready) begin
                write_pending_o <= 1'b1;
                write_address <= wr.trx_addr;
                write_data <= wr.wdata;
                write_mask <= wr.wstrobe;
                write_delay <= latency_i + {29'b0, random_state[5:3]};
                write_fault <= !wr.trx_type || wr.trx_addr[3:0] != 0 || wr.trx_addr > BYTES - 16;
            end
            if (read_pending_o) begin
                if (read_delay != 0) read_delay <= read_delay - 1;
                else begin
                    read_pending_o <= 1'b0;
                    rd.read_valid <= 1'b1;
                    rd.read_error <= read_fault;
                    read_gap <= gap_i;
                    if (!read_fault)
                        for (int b = 0; b < 16; b++) rd.rdata[8*b +: 8] <= memory[read_address+b];
                end
            end
            if (write_pending_o) begin
                if (write_delay != 0) write_delay <= write_delay - 1;
                else begin
                    write_pending_o <= 1'b0;
                    wr.write_valid <= 1'b1;
                    wr.write_error <= write_fault;
                    write_gap <= gap_i;
                    if (!write_fault) begin
                        assert (!(ge_write_i && ge_write_address_i == write_address))
                            else $fatal(1, "GE and RE write collision");
                        for (int b = 0; b < 16; b++)
                            if (write_mask[b]) memory[write_address+b] <= write_data[8*b +: 8];
                    end
                end
            end
        end
    end

    assert property (@(posedge clk_i) disable iff (!rst_n_i)
        rd.trx_req && !rd.ready |=> rd.trx_req && $stable({rd.trx_addr, rd.trx_type}));
    assert property (@(posedge clk_i) disable iff (!rst_n_i)
        wr.trx_req && !wr.ready |=> wr.trx_req && $stable({wr.trx_addr, wr.trx_type, wr.wdata, wr.wstrobe}));

endmodule : gpu_memory
