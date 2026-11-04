`ifndef Z_BUFFER_CONTROLLER_SV
    `define Z_BUFFER_CONTROLLER_SV

module z_buffer_controller #(
    parameter integer Z_WIDTH = 16,
    parameter integer ADDRESS_WIDTH = 32
) (
    input logic clk_i,
    input logic rst_n_i,

    /* First line span of a triangle from triangle rasterizer */
    input logic start_i,
    input logic [ADDRESS_WIDTH - 1:0] line_address_i,
    input logic [9:0] x_start_i,
    input logic [9:0] x_end_i,
    input logic last_line_i,
    output logic request_o,

    /* Next line span */
    input logic next_valid_i,
    input logic [ADDRESS_WIDTH - 1:0] next_line_address_i,
    input logic [9:0] next_x_start_i,
    input logic [9:0] next_x_end_i,
    input logic next_last_line_i,
    output logic next_ready_o,

    /* Control the buffer memory */
    input logic line_done_i,
    input logic dirty_i,
    output logic buffer_select_o,
    output logic line_ready_o,
    output logic new_line_o,
    output logic [9:0] active_x_start_o,
    output logic [9:0] active_x_end_o,
    output logic done_o,

    /* Back bank memory port, relative addresses in pixels. */
    input logic [127:0] buffer_ddr_read_data_i,
    input logic [15:0] buffer_ddr_read_mask_i,
    input logic buffer_ddr_read_valid_i,
    output logic buffer_ddr_select_o,
    output logic buffer_ddr_read_o,
    output logic buffer_ddr_write_o,
    output logic [9:0] buffer_ddr_address_o,
    output logic [127:0] buffer_ddr_write_data_o,
    output logic [15:0] buffer_ddr_mask_o,

    /* DDR interface */
    input logic ddr_ready_i,
    input logic ddr_response_valid_i,
    input logic [127:0] ddr_read_data_i,
    output logic ddr_request_o,
    output logic ddr_write_o,
    output logic [ADDRESS_WIDTH - 1:0] ddr_address_o,
    output logic [127:0] ddr_write_data_o,
    output logic [15:0] ddr_mask_o
);

//====================================================================================
//      PARAMETERS AND REGISTERS
//====================================================================================

    localparam integer SLOT_BYTES = (Z_WIDTH <= 16) ? 2 : 4;
    localparam integer LANES = 16 / SLOT_BYTES;
    localparam integer LANE_BITS = $clog2(LANES);
    localparam integer BYTE_SHIFT = $clog2(SLOT_BYTES);

    typedef enum logic [2:0] {
        IDLE, START_LINE, RUN_LINE, 
        NEXT_LINE, FINISH
    } state_t;

    typedef enum logic [2:0] {
        FREE, FILL_PENDING, FILLING, READY, 
        ACTIVE, EVICT_PENDING, EVICTING
    } bank_state_t;

    typedef enum logic [2:0] {
        MEMORY_IDLE, FILL_REQUEST, FILL_WAIT, EVICT_READ, 
        EVICT_CAPTURE, EVICT_REQUEST, EVICT_WAIT
    } memory_state_t;

    state_t state_CRT, state_NXT;
    bank_state_t [1:0] bank_CRT, bank_NXT;
    memory_state_t memory_CRT, memory_NXT;
    logic front_CRT, front_NXT, transfer_CRT, transfer_NXT;
    logic [1:0] dirty_CRT, dirty_NXT, last_CRT, last_NXT;
    logic [1:0][9:0] start_CRT, start_NXT, end_CRT, end_NXT;
    logic [1:0][ADDRESS_WIDTH - 1:0] address_CRT, address_NXT;
    logic [9:0] word_CRT, word_NXT;
    logic [127:0] data_CRT, data_NXT;
    logic [15:0] mask_CRT, mask_NXT;
    logic new_line_CRT, new_line_NXT, done_CRT, done_NXT;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                state_CRT <= IDLE;
                bank_CRT[0] <= FREE;
                bank_CRT[1] <= FREE;
                memory_CRT <= MEMORY_IDLE;
                front_CRT <= 1'b0;
                transfer_CRT <= 1'b0;
                dirty_CRT <= '0;
                last_CRT <= '0;
                new_line_CRT <= 1'b0;
                done_CRT <= 1'b0;
            end else begin
                state_CRT <= state_NXT;
                bank_CRT <= bank_NXT;
                memory_CRT <= memory_NXT;
                front_CRT <= front_NXT;
                transfer_CRT <= transfer_NXT;
                dirty_CRT <= dirty_NXT;
                last_CRT <= last_NXT;
                new_line_CRT <= new_line_NXT;
                done_CRT <= done_NXT;
            end
        end

        always_ff @(posedge clk_i) begin
            start_CRT <= start_NXT;
            end_CRT <= end_NXT;
            address_CRT <= address_NXT;
            word_CRT <= word_NXT;
            data_CRT <= data_NXT;
            mask_CRT <= mask_NXT;
        end

//====================================================================================
//      SPAN AND TRANSFER CONTROL
//====================================================================================

    logic [15:0] word_mask;
    logic final_word;
    logic service_valid, service_bank;

    assign buffer_select_o = front_CRT;
    assign active_x_start_o = start_CRT[front_CRT];
    assign active_x_end_o = end_CRT[front_CRT];
    assign final_word = ((word_CRT >> LANE_BITS) == (end_CRT[transfer_CRT] >> LANE_BITS));

        always_comb begin
            word_mask = '0;
            for (int lane = 0; lane < LANES; lane++) begin
                if (((int'(word_CRT) + lane) >= int'(start_CRT[transfer_CRT])) &
                    ((int'(word_CRT) + lane) <= int'(end_CRT[transfer_CRT]))) begin
                    word_mask[lane * SLOT_BYTES +: SLOT_BYTES] = '1;
                end
            end

            /* Free a dirty bank before refilling it; current span has fill priority. */
            service_valid = 1'b1;
            service_bank = front_CRT;
            if (bank_CRT[0] == EVICT_PENDING) service_bank = 1'b0;
            else if (bank_CRT[1] == EVICT_PENDING) service_bank = 1'b1;
            else if (bank_CRT[front_CRT] == FILL_PENDING) service_bank = front_CRT;
            else if (bank_CRT[!front_CRT] == FILL_PENDING) service_bank = !front_CRT;
            else service_valid = 1'b0;
        end

        always_comb begin
            state_NXT = state_CRT;
            bank_NXT = bank_CRT;
            memory_NXT = memory_CRT;
            front_NXT = front_CRT;
            transfer_NXT = transfer_CRT;
            dirty_NXT = dirty_CRT;
            last_NXT = last_CRT;
            start_NXT = start_CRT;
            end_NXT = end_CRT;
            address_NXT = address_CRT;
            word_NXT = word_CRT;
            data_NXT = data_CRT;
            mask_NXT = mask_CRT;
            new_line_NXT = 1'b0;
            done_NXT = 1'b0;

            request_o = 1'b0;
            next_ready_o = 1'b0;
            line_ready_o = 1'b0;
            new_line_o = 1'b0;
            done_o = 1'b0;

            buffer_ddr_select_o = transfer_CRT;
            buffer_ddr_read_o = 1'b0;
            buffer_ddr_write_o = 1'b0;
            buffer_ddr_address_o = word_CRT;
            buffer_ddr_write_data_o = ddr_read_data_i;
            buffer_ddr_mask_o = word_mask;
            ddr_request_o = 1'b0;
            ddr_write_o = 1'b0;
            ddr_address_o = address_CRT[transfer_CRT] + (word_CRT << BYTE_SHIFT);
            ddr_write_data_o = data_CRT;
            ddr_mask_o = word_mask;

            case (state_CRT)
                IDLE: begin
                    request_o = 1'b1;
                    done_o = done_CRT;

                    if (start_i & request_o) begin
                        front_NXT = 1'b0;
                        bank_NXT[0] = FILL_PENDING;
                        dirty_NXT[0] = 1'b0;
                        start_NXT[0] = x_start_i;
                        end_NXT[0] = x_end_i;
                        address_NXT[0] = line_address_i;
                        last_NXT[0] = last_line_i;
                        state_NXT = START_LINE;
                    end
                end

                START_LINE: begin
                    next_ready_o = !last_CRT[front_CRT] & (bank_CRT[!front_CRT] == FREE);

                    if (bank_CRT[front_CRT] == READY) begin
                        bank_NXT[front_CRT] = ACTIVE;
                        new_line_NXT = 1'b1;
                        state_NXT = RUN_LINE;
                    end
                end

                RUN_LINE: begin
                    next_ready_o = !last_CRT[front_CRT] & (bank_CRT[!front_CRT] == FREE);
                    new_line_o = new_line_CRT;
                    line_ready_o = !new_line_o;

                    /* Include a write committed on the same edge as line_done_i. */
                    if (dirty_i) begin
                        dirty_NXT[front_CRT] = 1'b1;
                    end

                    if (line_done_i) begin
                        bank_NXT[front_CRT] = dirty_NXT[front_CRT] ? EVICT_PENDING : FREE;
                        state_NXT = last_CRT[front_CRT] ? FINISH : NEXT_LINE;
                    end
                end

                NEXT_LINE: begin
                    next_ready_o = !last_CRT[front_CRT] & (bank_CRT[!front_CRT] == FREE);

                    if (bank_CRT[!front_CRT] == READY) begin
                        front_NXT = !front_CRT;
                        bank_NXT[!front_CRT] = ACTIVE;
                        new_line_NXT = 1'b1;
                        state_NXT = RUN_LINE;
                    end
                end

                FINISH: begin
                    /* Barrier between triangles: all writes have a DDR response. */
                    if ((bank_CRT[0] == FREE) & (bank_CRT[1] == FREE) & (memory_CRT == MEMORY_IDLE)) begin
                        done_NXT = 1'b1;
                        state_NXT = IDLE;
                    end
                end

                default: state_NXT = IDLE;
            endcase

            /* Capture the descriptor after the state has driven next_ready_o. */
            if (next_valid_i & next_ready_o) begin
                bank_NXT[!front_CRT] = FILL_PENDING;
                dirty_NXT[!front_CRT] = 1'b0;
                start_NXT[!front_CRT] = next_x_start_i;
                end_NXT[!front_CRT] = next_x_end_i;
                address_NXT[!front_CRT] = next_line_address_i;
                last_NXT[!front_CRT] = next_last_line_i;
            end

            case (memory_CRT)
                MEMORY_IDLE: begin
                    if (service_valid) begin
                        transfer_NXT = service_bank;
                        word_NXT = (start_CRT[service_bank] >> LANE_BITS) << LANE_BITS;
                        if (bank_CRT[service_bank] == EVICT_PENDING) begin
                            bank_NXT[service_bank] = EVICTING;
                            memory_NXT = EVICT_READ;
                        end else begin
                            bank_NXT[service_bank] = FILLING;
                            memory_NXT = FILL_REQUEST;
                        end
                    end
                end

                FILL_REQUEST: begin
                    ddr_request_o = rst_n_i;
                    if (ddr_ready_i) memory_NXT = FILL_WAIT;
                end

                FILL_WAIT: begin
                    if (ddr_response_valid_i) begin
                        buffer_ddr_write_o = rst_n_i;
                        if (final_word) begin
                            bank_NXT[transfer_CRT] = READY;
                            memory_NXT = MEMORY_IDLE;
                        end else begin
                            word_NXT = word_CRT + LANES[9:0];
                            memory_NXT = FILL_REQUEST;
                        end
                    end
                end

                EVICT_READ: begin
                    buffer_ddr_read_o = rst_n_i;
                    memory_NXT = EVICT_CAPTURE;
                end

                EVICT_CAPTURE: begin
                    if (buffer_ddr_read_valid_i) begin
                        data_NXT = buffer_ddr_read_data_i;
                        mask_NXT = buffer_ddr_read_mask_i;
                        if (buffer_ddr_read_mask_i != '0) begin
                            memory_NXT = EVICT_REQUEST;
                        end else if (final_word) begin
                            bank_NXT[transfer_CRT] = FREE;
                            dirty_NXT[transfer_CRT] = 1'b0;
                            memory_NXT = MEMORY_IDLE;
                        end else begin
                            word_NXT = word_CRT + LANES[9:0];
                            memory_NXT = EVICT_READ;
                        end
                    end
                end

                EVICT_REQUEST: begin
                    ddr_request_o = rst_n_i;
                    ddr_write_o = 1'b1;
                    ddr_mask_o = mask_CRT;
                    if (ddr_ready_i) memory_NXT = EVICT_WAIT;
                end

                EVICT_WAIT: begin
                    if (ddr_response_valid_i) begin
                        if (final_word) begin
                            bank_NXT[transfer_CRT] = FREE;
                            dirty_NXT[transfer_CRT] = 1'b0;
                            memory_NXT = MEMORY_IDLE;
                        end else begin
                            word_NXT = word_CRT + LANES[9:0];
                            memory_NXT = EVICT_READ;
                        end
                    end
                end

                default: memory_NXT = MEMORY_IDLE;
            endcase
        end

endmodule : z_buffer_controller

`endif
