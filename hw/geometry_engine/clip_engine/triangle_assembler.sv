`ifndef TRIANGLE_ASSEMBLER_SV
    `define TRIANGLE_ASSEMBLER_SV

module triangle_assembler (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* From clipper */
    input logic start_i,

    /* FIFO FWFT interface */
    input vertex_t fifo_vtx_i,
    input logic fifo_empty_i,
    output logic fifo_read_o,

    /* Generated triangle */
    output vertex_t vertex_o,
    output logic valid_o,

    /* Status */
    output logic done_o,
    output logic error_o
);

//====================================================================================
//      REGISTERS
//====================================================================================

    typedef enum logic [1:0] {
        IDLE, POP_PIVOT, POP_VTX1, POP_VTX2
    } fsm_state_t;

    fsm_state_t state_CRT, state_NXT;

    vertex_t pivot_CRT, pivot_NXT, previous_CRT, previous_NXT;
    logic produced_CRT, produced_NXT;

    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            produced_CRT <= 1'b0;
        end else begin
            state_CRT <= state_NXT;
            produced_CRT <= produced_NXT;
        end
    end

    always_ff @(posedge clk_i) begin
        pivot_CRT <= pivot_NXT;
        previous_CRT <= previous_NXT;
    end


//====================================================================================
//      FSM LOGIC
//====================================================================================

    always_comb begin : fsm_logic
        state_NXT = state_CRT;
        produced_NXT = produced_CRT;
        pivot_NXT = pivot_CRT;
        previous_NXT = previous_CRT;

        fifo_read_o = 1'b0;
        vertex_o = '0;
        valid_o = 1'b0;
        done_o = 1'b0;
        error_o = 1'b0;

        case (state_CRT)
            IDLE: begin
                if (start_i) begin
                    produced_NXT = 1'b0;

                    if (fifo_empty_i) begin
                        done_o = 1'b1;
                        error_o = 1'b1;
                    end else begin
                        state_NXT = POP_PIVOT;
                    end
                end
            end

            POP_PIVOT: begin
                if (fifo_empty_i) begin
                    state_NXT = IDLE;
                    
                    done_o = 1'b1;
                    error_o = !produced_CRT;
                end else begin
                    vertex_o = produced_CRT ? pivot_CRT : fifo_vtx_i;
                    valid_o = 1'b1;

                    if (!stall_i) begin
                        state_NXT = POP_VTX1;

                        if (!produced_CRT) begin
                            pivot_NXT = fifo_vtx_i;

                            fifo_read_o = 1'b1;
                        end
                    end
                end
            end

            POP_VTX1: begin
                if (fifo_empty_i) begin
                    state_NXT = IDLE;

                    done_o = 1'b1;
                    error_o = 1'b1;
                end else begin
                    vertex_o = produced_CRT ? previous_CRT : fifo_vtx_i;
                    valid_o = 1'b1;

                    if (!stall_i) begin
                        state_NXT = POP_VTX2;

                        if (!produced_CRT) begin
                            fifo_read_o = 1'b1;
                        end
                    end
                end
            end

            POP_VTX2: begin
                if (fifo_empty_i) begin
                    state_NXT = IDLE;
                    
                    done_o = 1'b1;
                    error_o = 1'b1;
                end else begin
                    vertex_o = fifo_vtx_i;
                    valid_o = 1'b1;

                    if (!stall_i) begin
                        state_NXT = POP_PIVOT;

                        previous_NXT = fifo_vtx_i;
                        produced_NXT = 1'b1;

                        fifo_read_o = 1'b1;
                    end
                end
            end

            default: state_NXT = IDLE;
        endcase
    end

endmodule : triangle_assembler

`endif
