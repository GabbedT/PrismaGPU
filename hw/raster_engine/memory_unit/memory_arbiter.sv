`ifndef MEMORY_ARBITER_SV
    `define MEMORY_ARBITER_SV

module memory_arbiter #(
    parameter integer CLIENTS = 5,
    parameter bit WRITE = 1'b0
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic abort_i,

    /* Client request; ready reserves the transaction register. */
    input logic [CLIENTS - 1:0] request_i,
    output logic [CLIENTS - 1:0] ready_o,
    input logic [CLIENTS - 1:0][31:0] address_i,
    input logic [CLIENTS - 1:0][127:0] data_i,
    input logic [CLIENTS - 1:0][15:0] mask_i,

    /* Response is routed to the client that owns the transaction. */
    output logic [CLIENTS - 1:0] response_o,
    output logic [CLIENTS - 1:0] error_o,
    output logic [127:0] data_o,
    output logic idle_o,

    gpu_ddr_interface.master ddr
);

//====================================================================================
//      ROUND-ROBIN SELECTION
//====================================================================================

    localparam integer CLIENT_WIDTH = (CLIENTS > 1) ? $clog2(CLIENTS) : 1;

    logic [CLIENT_WIDTH - 1:0] turn, owner, grant;
    logic grant_valid, accept_request;
    logic [CLIENT_WIDTH - 1:0] first_client, next_client;
    logic first_valid, next_valid;

    /* Select the first request at/after turn, wrapping only if necessary. */
    always_comb begin
        first_client = '0;
        next_client = '0;
        first_valid = 1'b0;
        next_valid = 1'b0;

        for (int client = 0; client < CLIENTS; client++) begin
            if (request_i[client]) begin
                if (!first_valid) begin
                    first_client = CLIENT_WIDTH'(client);
                    first_valid = 1'b1;
                end

                if (!next_valid && (CLIENT_WIDTH'(client) >= turn)) begin
                    next_client = CLIENT_WIDTH'(client);
                    next_valid = 1'b1;
                end
            end
        end

        grant_valid = first_valid;

        if (next_valid) begin
            grant = next_client;
        end else begin
            grant = first_client;
        end
    end

//====================================================================================
//      TRANSACTION CONTROL
//====================================================================================

    typedef enum logic [1:0] {
        IDLE,
        PRESENT,
        WAIT_RESPONSE
    } state_t;

    state_t state_CRT, state_NXT;
    logic completed, failed;

    assign accept_request = (state_CRT == IDLE) && grant_valid && !abort_i;
    assign completed = WRITE ? ddr.write_valid : ddr.read_valid;
    assign failed = WRITE ? ddr.write_error : ddr.read_error;

    assign data_o = ddr.rdata;
    assign idle_o = state_CRT == IDLE;
    assign ddr.trx_req = state_CRT == PRESENT;
    assign ddr.trx_type = WRITE;

    always_comb begin
        state_NXT = state_CRT;
        ready_o = '0;
        response_o = '0;
        error_o = '0;

        case (state_CRT)
            IDLE: begin
                if (accept_request) begin
                    ready_o[grant] = 1'b1;
                    state_NXT = PRESENT;
                end
            end

            PRESENT: begin
                if (ddr.ready) begin
                    state_NXT = WAIT_RESPONSE;
                end
            end

            WAIT_RESPONSE: begin
                if (completed) begin
                    response_o[owner] = 1'b1;
                    error_o[owner] = failed;
                    state_NXT = IDLE;
                end
            end

            default: begin
                state_NXT = IDLE;
            end
        endcase
    end

    /* Abort blocks new work; presented requests still complete normally. */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            turn <= '0;
            owner <= '0;
            ddr.trx_addr <= '0;
            ddr.wdata <= '0;
            ddr.wstrobe <= '0;
        end else begin
            state_CRT <= state_NXT;

            if (accept_request) begin
                owner <= grant;
                ddr.trx_addr <= address_i[grant];
                ddr.wdata <= WRITE ? data_i[grant] : '0;
                ddr.wstrobe <= WRITE ? mask_i[grant] : '0;

                if (grant == CLIENT_WIDTH'(CLIENTS - 1)) begin
                    turn <= '0;
                end else begin
                    turn <= grant + 1'b1;
                end
            end
        end
    end

endmodule : memory_arbiter

`endif
