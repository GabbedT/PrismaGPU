`ifndef CLIP_FRACTION_DIVIDER_SV
    `define CLIP_FRACTION_DIVIDER_SV

module clip_fraction_divider (
    input logic               clk_i,
    input logic               rst_n_i,
    input logic               stall_i,

    input logic signed [32:0] plane_start_i,
    input logic signed [32:0] plane_end_i,
    input logic               data_valid_i,

    output logic [16:0] fraction_o,
    output logic        fraction_inexact_o,
    output logic        data_valid_o,
    output logic        invalid_edge_o,
    output logic        idle_o
);

    typedef enum logic {IDLE, DIVIDE} fsm_state_t;

//====================================================================================
//      REGISTER
//====================================================================================  

    fsm_state_t state_CRT, state_NXT;
    logic [33:0] remainder_CRT, remainder_NXT;
    logic [33:0] denominator_CRT, denominator_NXT;
    logic [16:0] fraction_CRT, fraction_NXT;
    logic [2:0] iter_count_CRT, iter_count_NXT;
    logic data_valid_CRT, data_valid_NXT;
    logic invalid_edge_CRT, invalid_edge_NXT;

    /* Only control signals need a defined value after reset. */
    always_ff @(posedge clk_i or negedge rst_n_i) begin
        if (!rst_n_i) begin
            state_CRT <= IDLE;
            data_valid_CRT <= 1'b0;
            invalid_edge_CRT <= 1'b0;
        end else if (!stall_i) begin
            state_CRT <= state_NXT;
            data_valid_CRT <= data_valid_NXT;
            invalid_edge_CRT <= invalid_edge_NXT;
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_n_i & !stall_i) begin
            remainder_CRT <= remainder_NXT;
            denominator_CRT <= denominator_NXT;
            fraction_CRT <= fraction_NXT;
            iter_count_CRT <= iter_count_NXT;
        end
    end


//====================================================================================
//      DATAPATH
//====================================================================================  

    logic [33:0] start_magnitude, end_magnitude;
    logic [34:0] shifted_first, shifted_second;
    logic [35:0] trial_first, trial_second;
    logic [33:0] remainder_first, remainder_second;
    logic first_bit, second_bit;

    /* Extend before negating to preserve the minimum signed input. */
    assign start_magnitude = plane_start_i[32] ? -{plane_start_i[32], plane_start_i} : 
                                                  {plane_start_i[32], plane_start_i};

    assign end_magnitude = plane_end_i[32] ? -{plane_end_i[32], plane_end_i} : 
                                              {plane_end_i[32], plane_end_i};

    /* The top subtraction bit indicates a borrow. */
    assign shifted_first = {remainder_CRT, 1'b0};
    assign trial_first = {1'b0, shifted_first} - {2'b0, denominator_CRT};
    assign first_bit = !trial_first[35];
    assign remainder_first = first_bit ? trial_first[33:0] : shifted_first[33:0];

    assign shifted_second = {remainder_first, 1'b0};
    assign trial_second = {1'b0, shifted_second} - {2'b0, denominator_CRT};
    assign second_bit = !trial_second[35];
    assign remainder_second = second_bit ? trial_second[33:0] : shifted_second[33:0];


//====================================================================================
//      FSM LOGIC
//====================================================================================  

    always_comb begin
        state_NXT = state_CRT;
        remainder_NXT = remainder_CRT;
        denominator_NXT = denominator_CRT;
        fraction_NXT = fraction_CRT;
        iter_count_NXT = iter_count_CRT;
        data_valid_NXT = 1'b0;
        invalid_edge_NXT = 1'b0;

        case (state_CRT)
            IDLE: begin
                if (data_valid_i) begin
                    if ((plane_start_i == '0) && (plane_end_i == '0)) begin
                        invalid_edge_NXT = 1'b1;
                    end else if (plane_start_i == '0) begin
                        fraction_NXT = '0;
                        remainder_NXT = '0;
                        data_valid_NXT = 1'b1;
                    end else if (plane_end_i == '0) begin
                        fraction_NXT = 17'h10000;
                        remainder_NXT = '0;
                        data_valid_NXT = 1'b1;
                    end else if (plane_start_i[32] == plane_end_i[32]) begin
                        invalid_edge_NXT = 1'b1;
                    end else begin
                        remainder_NXT = start_magnitude;
                        denominator_NXT = start_magnitude + end_magnitude;

                        fraction_NXT = '0;
                        iter_count_NXT = '0;
                        
                        state_NXT = DIVIDE;
                    end
                end
            end

            DIVIDE: begin
                remainder_NXT = remainder_second;
                fraction_NXT = {fraction_CRT[14:0], first_bit, second_bit};
                iter_count_NXT = iter_count_CRT + 1'b1;

                if (iter_count_CRT == 3'd7) begin
                    data_valid_NXT = 1'b1;
                    state_NXT = IDLE;
                end
            end
        endcase
    end

    assign fraction_o = fraction_CRT;

    /* Retained with the fraction until the next request. */
    assign fraction_inexact_o = |remainder_CRT;

    assign data_valid_o = data_valid_CRT;
    assign invalid_edge_o = invalid_edge_CRT;
    assign idle_o = (state_CRT == IDLE);

endmodule : clip_fraction_divider

`endif
