`ifndef TRIANGLE_PACKER_SV
    `define TRIANGLE_PACKER_SV

module triangle_packer #(
    parameter integer TRIANGLE_DEPTH = 2,
    parameter integer FIFO_DEPTH = 64
) (
    input logic clk_i,
    input logic rst_n_i,

    /* Input transfer */
    input proc_triangle_t triangle_i,
    input logic valid_i,
    output logic stall_o,

    /* Synchronous read */
    input logic read_i,
    output logic [127:0] read_data_o,
    output logic [$clog2(FIFO_DEPTH + 1) - 1:0] word_count_o
);

    localparam logic [1:0] PULL_OPERATION = 2'b01;
    localparam logic [1:0] PUSH_OPERATION = 2'b10;

//====================================================================================
//      TRIANGLE FIFO
//====================================================================================

    localparam integer TRIANGLE_PTR_SIZE = (TRIANGLE_DEPTH > 1) ? $clog2(TRIANGLE_DEPTH) : 1;
    localparam integer TRIANGLE_COUNT_SIZE = $clog2(TRIANGLE_DEPTH + 1);

    proc_triangle_t triangle_memory [TRIANGLE_DEPTH - 1:0];
    proc_triangle_t triangle_data;
    logic [TRIANGLE_PTR_SIZE - 1:0] triangle_write_ptr, triangle_read_ptr, inc_triangle_write_ptr, inc_triangle_read_ptr;
    logic [TRIANGLE_COUNT_SIZE - 1:0] triangle_count;
    logic triangle_valid, triangle_write, triangle_read, triangle_done;

    /* Load the next triangle while its predecessor emits the last word */
    assign triangle_read = (triangle_count != '0) & (!triangle_valid | triangle_done);

    /* Stall the pipeline once the triangle buffer become full */
    assign stall_o = (triangle_count == TRIANGLE_DEPTH) & !triangle_read;
    
    assign triangle_write = valid_i & !stall_o;

        always_ff @(posedge clk_i) begin
            if (triangle_write) begin
                triangle_memory[triangle_write_ptr] <= triangle_i;
            end

            if (triangle_read) begin
                triangle_data <= triangle_memory[triangle_read_ptr];
            end
        end

        always_comb begin
            if (triangle_write_ptr == (TRIANGLE_DEPTH - 1)) begin
                inc_triangle_write_ptr = '0;
            end else begin
                inc_triangle_write_ptr = triangle_write_ptr + 1'b1;
            end

            if (triangle_read_ptr == (TRIANGLE_DEPTH - 1)) begin
                inc_triangle_read_ptr = '0;
            end else begin
                inc_triangle_read_ptr = triangle_read_ptr + 1'b1;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                triangle_write_ptr <= '0;
                triangle_read_ptr <= '0;
                triangle_count <= '0;
                triangle_valid <= 1'b0;
            end else begin
                if (triangle_write) begin
                    triangle_write_ptr <= inc_triangle_write_ptr;
                end

                if (triangle_read) begin
                    triangle_read_ptr <= inc_triangle_read_ptr;
                end

                if (!triangle_valid | triangle_done) begin
                    triangle_valid <= triangle_read;
                end

                case ({triangle_write, triangle_read})
                    PULL_OPERATION: triangle_count <= triangle_count - 1'b1;

                    PUSH_OPERATION: triangle_count <= triangle_count + 1'b1;
                endcase
            end
        end


//====================================================================================
//      PACKER
//====================================================================================

    typedef enum logic [2:0] {
        WORD0, WORD1, WORD2, WORD3, WORD4
    } fsm_state_t;

    fsm_state_t state_CRT, state_NXT;
    logic [639:0] packed_triangle;
    logic [127:0] write_data;
    logic write_enable, read_enable;

    /* Low bits first; the final 79 bits are padding for the current type */
    assign packed_triangle = {{(640 - $bits(proc_triangle_t)){1'b0}}, triangle_data};

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                state_CRT <= WORD0;
            end else begin
                state_CRT <= state_NXT;
            end
        end

    /* Pack the triangle out from the triangle buffer into 5 
     * words of 128 bits each, write each one into the final buffer */
    always_comb begin
        state_NXT = state_CRT;
        write_data = '0;
        triangle_done = 1'b0;

        case (state_CRT)
            WORD0: begin
                write_data = packed_triangle[127:0];

                if (write_enable) begin
                    state_NXT = WORD1;
                end
            end

            WORD1: begin
                write_data = packed_triangle[255:128];

                if (write_enable) begin
                    state_NXT = WORD2;
                end
            end

            WORD2: begin
                write_data = packed_triangle[383:256];

                if (write_enable) begin
                    state_NXT = WORD3;
                end
            end

            WORD3: begin
                write_data = packed_triangle[511:384];

                if (write_enable) begin
                    state_NXT = WORD4;
                end
            end

            WORD4: begin
                write_data = packed_triangle[639:512];

                if (write_enable) begin
                    triangle_done = 1'b1;
                    state_NXT = WORD0;
                end
            end

            default: state_NXT = WORD0;
        endcase
    end


//====================================================================================
//      WORD FIFO
//====================================================================================

    localparam integer PTR_SIZE = (FIFO_DEPTH > 1) ? $clog2(FIFO_DEPTH) : 1;
    localparam integer COUNT_SIZE = $clog2(FIFO_DEPTH + 1);

    logic [127:0] buffer_memory [FIFO_DEPTH - 1:0];
    logic [PTR_SIZE - 1:0] write_ptr, read_ptr, inc_write_ptr, inc_read_ptr;

    assign read_enable = read_i & (word_count_o != '0);
    assign write_enable = triangle_valid & ((word_count_o != FIFO_DEPTH) | read_enable);

        always_ff @(posedge clk_i) begin
            if (write_enable) begin
                buffer_memory[write_ptr] <= write_data;
            end

            if (read_enable) begin
                read_data_o <= buffer_memory[read_ptr];
            end
        end

        always_comb begin
            if (write_ptr == (FIFO_DEPTH - 1)) begin
                inc_write_ptr = '0;
            end else begin
                inc_write_ptr = write_ptr + 1'b1;
            end

            if (read_ptr == (FIFO_DEPTH - 1)) begin
                inc_read_ptr = '0;
            end else begin
                inc_read_ptr = read_ptr + 1'b1;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                write_ptr <= '0;
                read_ptr <= '0;
                word_count_o <= '0;
            end else begin
                if (write_enable) begin
                    write_ptr <= inc_write_ptr;
                end

                if (read_enable) begin
                    read_ptr <= inc_read_ptr;
                end

                case ({write_enable, read_enable})
                    PULL_OPERATION: word_count_o <= word_count_o - 1'b1;
                    
                    PUSH_OPERATION: word_count_o <= word_count_o + 1'b1;
                endcase
            end
        end

endmodule : triangle_packer

`endif
