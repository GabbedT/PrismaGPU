`ifndef Z_CLEAR_SV
    `define Z_CLEAR_SV

module z_clear #(
    parameter integer Z_WIDTH = 16,
    parameter integer ADDRESS_WIDTH = 32
) (
    input logic clk_i,
    input logic rst_n_i,

    /* Validated clear job; fixed rows have no padding. */
    input logic start_i,
    input logic [Z_WIDTH - 1:0] depth_i,
    input logic [ADDRESS_WIDTH - 1:0] base_i,
    input re_viewport_size_t viewport_size_i,

    /* Completion follows the final write response. */
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
    localparam integer COUNT_WIDTH = $clog2(640 * 480 / LANES + 1);

    typedef enum logic [1:0] {
        IDLE,
        REQUEST,
        RESPONSE
    } state_t;

    state_t state_CRT, state_NXT;
    logic [ADDRESS_WIDTH - 1:0] address_CRT, address_NXT;
    logic [COUNT_WIDTH - 1:0] remaining_CRT, remaining_NXT;
    logic [Z_WIDTH - 1:0] depth_CRT, depth_NXT;
    logic done_NXT;

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            done_o <= 1'b0;
        end else begin
            state_CRT <= state_NXT;
            done_o <= done_NXT;
        end
    end

    /* A new job initializes payload before the first request. */
    always_ff @(posedge clk_i) begin
        address_CRT <= address_NXT;
        remaining_CRT <= remaining_NXT;
        depth_CRT <= depth_NXT;
    end

//====================================================================================
//      LINEAR WRITE SEQUENCE
//====================================================================================

    always_comb begin
        state_NXT = state_CRT;
        address_NXT = address_CRT;
        remaining_NXT = remaining_CRT;
        depth_NXT = depth_CRT;
        done_NXT = 1'b0;

        busy_o = 1'b1;
        request_o = 1'b0;
        address_o = address_CRT;
        mask_o = 16'hffff;
        data_o = '0;

        for (int lane = 0; lane < LANES; lane++) begin
            data_o[lane * SLOT +: SLOT] = depth_CRT;
        end

        case (state_CRT)
            IDLE: begin
                busy_o = 1'b0;
                if (start_i) begin
                    address_NXT = base_i;
                    depth_NXT = depth_i;
                    remaining_NXT = COUNT_WIDTH'(640 * 480 / LANES);
                    if (viewport_size_i == RE_VIEWPORT_320_240) begin
                        remaining_NXT = COUNT_WIDTH'(320 * 240 / LANES);
                    end
                    state_NXT = REQUEST;
                end
            end

            REQUEST: begin
                request_o = 1'b1;
                if (ready_i) begin
                    state_NXT = RESPONSE;
                end
            end

            RESPONSE: begin
                if (response_i) begin
                    if (remaining_CRT == 1) begin
                        done_NXT = 1'b1;
                        state_NXT = IDLE;
                    end else begin
                        address_NXT = address_CRT + 16;
                        remaining_NXT = remaining_CRT - 1'b1;
                        state_NXT = REQUEST;
                    end
                end
            end

            default: begin
                state_NXT = IDLE;
            end
        endcase
    end

endmodule : z_clear

`endif
