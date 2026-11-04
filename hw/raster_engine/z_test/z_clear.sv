`ifndef Z_CLEAR_SV
    `define Z_CLEAR_SV

module z_clear #(
    parameter integer Z_WIDTH = 16,
    parameter integer ADDRESS_WIDTH = 32
) (
    input logic clk_i,
    input logic rst_n_i,

    /* Validated clear job; hold configuration through done */
    input logic start_i,
    input logic [Z_WIDTH - 1:0] depth_i,
    input logic [ADDRESS_WIDTH - 1:0] base_i,
    input logic [9:0] width_i,
    input logic [8:0] height_i,
    input logic [15:0] pitch_i,

    /* Completion follows the final write response */
    output logic busy_o,
    output logic done_o,

    /* DDR write client */
    output logic request_o,
    input logic ready_i,
    input logic response_i,
    output logic [ADDRESS_WIDTH - 1:0] address_o,
    output logic [127:0] data_o,
    output logic [15:0] mask_o
);

//====================================================================================
//      CLEAR STATE
//====================================================================================

    localparam integer SLOT = Z_WIDTH <= 16 ? 16 : 32;
    localparam integer LANES = 128 / SLOT;
    localparam integer BYTE_SHIFT = (Z_WIDTH <= 16) ? 1 : 2;

    typedef enum logic [1:0] {
        IDLE,
        REQUEST,
        RESPONSE
    } state_t;
    state_t state;
    logic [ADDRESS_WIDTH - 1:0] row_address;
    logic [9:0] x;
    logic [8:0] y;
    logic [Z_WIDTH - 1:0] depth;
    logic [10:0] next_x;
    logic last_word;

    assign next_x = {1'b0, x} + 11'(LANES);
    assign last_word = next_x >= {1'b0, width_i};
    assign busy_o = state != IDLE;
    assign request_o = state == REQUEST;
    assign address_o = row_address + (ADDRESS_WIDTH'(x) << BYTE_SHIFT);

//====================================================================================
//      DEPTH SLOTS AND BYTE ENABLES
//====================================================================================

    /* Preserve padding after the final pixel of each row. */
    always_comb begin
        data_o = '0;
        mask_o = '0;
        for (int lane = 0; lane < LANES; lane++) begin
            data_o[lane * SLOT +: SLOT] = SLOT'(depth);
            if ({1'b0, x} + 11'(lane) < {1'b0, width_i}) begin
                mask_o[lane * (SLOT / 8) +: SLOT / 8] = '1;
            end
        end
    end

//====================================================================================
//      WRITE SEQUENCE
//====================================================================================

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state <= IDLE;
            x <= '0;
            y <= '0;
            row_address <= '0;
            depth <= '0;
            done_o <= 1'b0;
        end else begin
            done_o <= 1'b0;
            case (state)
                IDLE: begin
                    if (start_i) begin
                        row_address <= base_i;
                        depth <= depth_i;
                        x <= '0;
                        y <= '0;
                        state <= REQUEST;
                    end
                end

                REQUEST: begin
                    if (ready_i) begin
                        state <= RESPONSE;
                    end
                end

                RESPONSE: begin
                    if (response_i) begin
                        if (last_word) begin
                            x <= '0;
                            y <= y + 9'd1;
                            row_address <= row_address + ADDRESS_WIDTH'(pitch_i);
                            if (y + 9'd1 == height_i) begin
                                state <= IDLE;
                                done_o <= 1'b1;
                            end else begin
                                state <= REQUEST;
                            end
                        end else begin
                            x <= next_x[9:0];
                            state <= REQUEST;
                        end
                    end
                end

                default: begin
                    state <= IDLE;
                end
            endcase
        end
    end

endmodule : z_clear

`endif
