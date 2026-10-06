`ifndef TRIANGLE_UNPACKER_SV
    `define TRIANGLE_UNPACKER_SV

module triangle_unpacker #(
    parameter integer FIFO_DEPTH = 16
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Writes on full are ignored unless a simultaneous read makes room,
     * external writer must take track of the size */
    input logic write_i,
    input logic [127:0] write_data_i,
    /* Words still in RAM; excludes the registered word being unpacked. */
    output logic [$clog2(FIFO_DEPTH + 1) - 1:0] word_count_o,

    /* Output transfer */
    output vertex_t vertex_o,
    output logic valid_o
);

//====================================================================================
//      FIFO
//====================================================================================

    localparam logic [1:0] PULL_OPERATION = 2'b01;
    localparam logic [1:0] PUSH_OPERATION = 2'b10;

    localparam integer PTR_SIZE = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam integer COUNT_SIZE = $clog2(FIFO_DEPTH + 1);

    logic [127:0] buffer_memory [FIFO_DEPTH - 1:0];
    logic [127:0] fifo_data;
    logic [PTR_SIZE - 1:0] write_ptr, read_ptr, inc_write_ptr, inc_read_ptr;
    logic fifo_empty, fifo_full, fifo_valid, write_enable, read_enable;

    assign fifo_empty = (word_count_o == '0);
    assign fifo_full = (word_count_o == COUNT_SIZE'(FIFO_DEPTH));

    /* Read the next word while the unpacker consumes the registered word */
    assign read_enable = !stall_i & !fifo_empty;
    assign write_enable = write_i & (!fifo_full | read_enable);

        always_ff @(posedge clk_i) begin
            if (write_enable) begin
                buffer_memory[write_ptr] <= write_data_i;
            end

            if (read_enable) begin
                fifo_data <= buffer_memory[read_ptr];
            end
        end

        always_comb begin
            if (write_ptr == PTR_SIZE'(FIFO_DEPTH - 1)) begin
                inc_write_ptr = '0;
            end else begin
                inc_write_ptr = write_ptr + 1'b1;
            end

            if (read_ptr == PTR_SIZE'(FIFO_DEPTH - 1)) begin
                inc_read_ptr = '0;
            end else begin
                inc_read_ptr = read_ptr + 1'b1;
            end
        end

        always_ff @(posedge clk_i or negedge rst_n_i) begin
            if (!rst_n_i) begin
                write_ptr <= '0;
                read_ptr <= '0;
                word_count_o <= '0;
                fifo_valid <= 1'b0;
            end else begin
                if (write_enable) begin
                    write_ptr <= inc_write_ptr;
                end

                if (read_enable) begin
                    read_ptr <= inc_read_ptr;
                end

                /* Retain an unread output word during a stall */
                if (!stall_i) begin
                    fifo_valid <= read_enable;
                end

                case ({write_enable, read_enable})
                    PULL_OPERATION: begin
                        word_count_o <= word_count_o - 1'b1;
                    end

                    PUSH_OPERATION: begin
                        word_count_o <= word_count_o + 1'b1;
                    end

                    default: begin
                        word_count_o <= word_count_o;
                    end
                endcase
            end
        end


//====================================================================================
//      UNPACKER
//====================================================================================

    typedef enum logic [2:0] {
        WORD0, WORD1, WORD2, WORD3, WORD4
    } fsm_state_t;

    fsm_state_t state_CRT, state_NXT;
    logic [175:0] data_CRT, data_NXT;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                state_CRT <= WORD0;
            end else if (!stall_i) begin
                state_CRT <= state_NXT;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                data_CRT <= data_NXT;
            end
        end

    /* Five words per triangle, low bits first; word 4[127:112] is padding */
    always_comb begin : fsm_logic
        state_NXT = state_CRT;
        data_NXT = data_CRT;

        vertex_o = '0;
        valid_o = 1'b0;

        /* The last registered word remains valid even when the FIFO is empty */
        if (fifo_valid) begin
            case (state_CRT)
                WORD0: begin
                    data_NXT[127:0] = fifo_data;
                    state_NXT = WORD1;
                end

                WORD1: begin
                    vertex_o = {fifo_data[79:0], data_CRT[127:0]};
                    valid_o = 1'b1;

                    /* Keep the first 48 bits of vertex 1 */
                    data_NXT[47:0] = fifo_data[127:80];
                    state_NXT = WORD2;
                end

                WORD2: begin
                    data_NXT[175:48] = fifo_data;
                    state_NXT = WORD3;
                end

                WORD3: begin
                    vertex_o = {fifo_data[31:0], data_CRT};
                    valid_o = 1'b1;

                    /* Keep the first 96 bits of vertex 2 */
                    data_NXT[95:0] = fifo_data[127:32];
                    state_NXT = WORD4;
                end

                WORD4: begin
                    vertex_o = {fifo_data[111:0], data_CRT[95:0]};
                    valid_o = 1'b1;

                    /* Discard the final 16 padding bits */
                    state_NXT = WORD0;
                end

                default: state_NXT = WORD0;
            endcase
        end
    end

endmodule : triangle_unpacker

`endif
