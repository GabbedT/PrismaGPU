`ifndef CLIP_VERTEX_FIFO_SV
    `define CLIP_VERTEX_FIFO_SV

module clip_vertex_fifo (
    input logic clk_i,
    input logic rst_n_i,

    /* Reads on empty and writes on full are ignored. */
    input logic write_i,
    input logic read_i,

    output logic empty_o,
    output logic full_o,

    input vertex_t write_data_i,
    output vertex_t read_data_o
);

//====================================================================================
//      MEMORY LOGIC
//====================================================================================

    localparam integer BUFFER_DEPTH = 9;
    localparam integer PTR_SIZE = $clog2(BUFFER_DEPTH);

    vertex_t buffer_memory [BUFFER_DEPTH - 1:0];
    logic [PTR_SIZE - 1:0] write_ptr, read_ptr;
    logic write_enable, read_enable;

    /* A read makes room for a simultaneous write, even when full. */
    assign read_enable = rst_n_i & read_i & !empty_o;
    assign write_enable = rst_n_i & write_i & (!full_o | read_enable);

    always_ff @(posedge clk_i) begin
        if (write_enable) begin
            buffer_memory[write_ptr] <= write_data_i;
        end
    end

    /* FWFT: the head is valid whenever empty_o is low. */
    assign read_data_o = buffer_memory[read_ptr];


//====================================================================================
//      POINTERS LOGIC
//====================================================================================

    logic [PTR_SIZE - 1:0] inc_write_ptr, inc_read_ptr;

    always_comb begin
        if (write_ptr == PTR_SIZE'(BUFFER_DEPTH - 1)) begin
            inc_write_ptr = '0;
        end else begin
            inc_write_ptr = write_ptr + 1'b1;
        end

        if (read_ptr == PTR_SIZE'(BUFFER_DEPTH - 1)) begin
            inc_read_ptr = '0;
        end else begin
            inc_read_ptr = read_ptr + 1'b1;
        end
    end

    /* Match the asynchronous control reset of the clipping engine. */
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            write_ptr <= '0;
            read_ptr <= '0;
        end else begin
            if (write_enable) begin
                write_ptr <= inc_write_ptr;
            end

            if (read_enable) begin
                read_ptr <= inc_read_ptr;
            end
        end
    end


//====================================================================================
//      FIFO STATUS LOGIC
//====================================================================================

    localparam logic [1:0] PULL_OPERATION = 2'b01;
    localparam logic [1:0] PUSH_OPERATION = 2'b10;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            full_o <= 1'b0;
            empty_o <= 1'b1;
        end else begin
            case ({write_enable, read_enable})
                PULL_OPERATION: begin
                    full_o <= 1'b0;
                    empty_o <= (write_ptr == inc_read_ptr);
                end

                PUSH_OPERATION: begin
                    full_o <= (read_ptr == inc_write_ptr);
                    empty_o <= 1'b0;
                end

                default: begin
                    full_o <= full_o;
                    empty_o <= empty_o;
                end
            endcase
        end
    end

endmodule : clip_vertex_fifo

`endif
