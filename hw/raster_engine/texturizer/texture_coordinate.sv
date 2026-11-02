`ifndef TEXTURE_COORDINATE_SV
    `define TEXTURE_COORDINATE_SV

module texture_coordinate (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,
    input logic valid_i,

    input logic signed [43:0] u_over_w_i,
    input logic signed [43:0] v_over_w_i,
    input logic signed [43:0] inv_w_i,

    output logic signed [43:0] u_o,
    output logic signed [43:0] v_o,
    output logic valid_o,
    output logic invalid_o
);

//====================================================================================
//      LOCALPARAMS AND VARIABLES
//====================================================================================

    localparam int PRODUCT_WIDTH = 44 + TEXTURE_RECIPROCAL_WIDTH;

    localparam int SHIFTED_WIDTH = PRODUCT_WIDTH - 1;

    localparam logic [SHIFTED_WIDTH:0] NEGATIVE_LIMIT = (SHIFTED_WIDTH + 1)'(1) << 43;
    localparam logic [SHIFTED_WIDTH:0] POSITIVE_LIMIT = NEGATIVE_LIMIT - 1'b1;

    typedef struct packed {
        logic [1:0] negative;
        logic [5:0] shift;
    } coordinate_metadata_t;

    logic [TEXTURE_COORDINATE_LATENCY-1:0] valid_pipe, invalid_pipe;
    logic [5:0] leading_one, captured_leading_one;
    logic [43:0] captured_denominator;
    logic [1:0][43:0] captured_magnitude;
    logic [1:0] captured_negative;
    logic [9:0] normalized_index, lookup_index;
    logic [TEXTURE_RECIPROCAL_WIDTH-1:0] lookup_reciprocal, reciprocal;
    logic [1:0][43:0] normalized_magnitude, reciprocal_magnitude;
    coordinate_metadata_t normalized_metadata, reciprocal_metadata;

    /* Two coordinates, each split into two 22-bit numerator halves. */
    logic [1:0][1:0][39:0] partial_product;
    logic [1:0][PRODUCT_WIDTH-1:0] full_product;
    coordinate_metadata_t partial_metadata, product_metadata;

    logic [1:0][SHIFTED_WIDTH-1:0] shifted_magnitude, shifted_magnitude_next;
    logic [1:0] round_negative, round_guard, round_sticky;
    logic [1:0] guard_next, sticky_next;


//====================================================================================
//      FUNCTIONS
//====================================================================================

    function automatic logic [43:0] magnitude_of(input logic signed [43:0] value);
        /* Unsigned storage also represents abs(-2^43) exactly. */
        return value[43] ? $unsigned(-value) : $unsigned(value);
    endfunction

    function automatic logic signed [43:0] rounded_coordinate(
        input logic [SHIFTED_WIDTH-1:0] magnitude,
        input logic negative,
        input logic guard_bit,
        input logic sticky_bit
    );
        logic [SHIFTED_WIDTH:0] rounded;

        rounded = {1'b0, magnitude} + (SHIFTED_WIDTH + 1)'(guard_bit & (sticky_bit | magnitude[0]));
        
        if (negative) begin
            if (rounded >= NEGATIVE_LIMIT) begin
                return 44'sh800_0000_0000;
            end

            return -$signed(rounded[43:0]);
        end
        
        if (rounded > POSITIVE_LIMIT) begin
            return 44'sh7ff_ffff_ffff;
        end
        
        return $signed(rounded[43:0]);
    endfunction


//====================================================================================
//      RECIPROCAL CALCULATION
//====================================================================================

    /* D[42:33]; the leading one and the unused low bits need no registers. */
    assign normalized_index = 10'(
        (captured_denominator << (6'd43 - captured_leading_one)) >> 33
    );

    reciprocal_lut lookup_table (
        .index_i      ( lookup_index      ),
        .reciprocal_o ( lookup_reciprocal )
    );

    always_comb begin
        leading_one = '0;

        for (int bit_index = 0; bit_index < 43; bit_index++) begin
            if (inv_w_i[bit_index]) begin
                leading_one = 6'(bit_index);
            end
        end
    end


//====================================================================================
//      ROUND BITS
//====================================================================================

    always_comb begin
        shifted_magnitude_next = '0;
        guard_next = '0;
        sticky_next = '0;

        for (int coordinate = 0; coordinate < 2; coordinate++) begin
            shifted_magnitude_next[coordinate] = SHIFTED_WIDTH'(full_product[coordinate] >> product_metadata.shift);
            guard_next[coordinate] = full_product[coordinate][product_metadata.shift - 6'd1];

            for (int bit_index = 0; bit_index < PRODUCT_WIDTH; bit_index++) begin
                if (bit_index < (int'(product_metadata.shift) - 1)) begin
                    sticky_next[coordinate] |= full_product[coordinate][bit_index];
                end
            end
        end
    end


//====================================================================================
//      OUTPUT STATUS
//====================================================================================

    assign valid_o = valid_pipe[TEXTURE_COORDINATE_LATENCY-1];
    assign invalid_o = valid_o & invalid_pipe[TEXTURE_COORDINATE_LATENCY-1];

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            valid_pipe <= '0;
            invalid_pipe <= '0;
        end else if (!stall_i) begin
            valid_pipe <= {valid_pipe[TEXTURE_COORDINATE_LATENCY-2:0], valid_i};
            invalid_pipe <= {
                invalid_pipe[TEXTURE_COORDINATE_LATENCY-2:0], inv_w_i <= 44'sd0
            };
        end
    end


//====================================================================================
//      FINAL COORDINATES CALCULATION
//====================================================================================

    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            /* Stage 1: capture signs, exact magnitudes and normalization index. */
            captured_denominator <= $unsigned(inv_w_i);
            captured_leading_one <= leading_one;
            captured_magnitude[0] <= magnitude_of(u_over_w_i);
            captured_magnitude[1] <= magnitude_of(v_over_w_i);
            captured_negative <= {v_over_w_i[43], u_over_w_i[43]};

            /* Stage 2: normalize and register the ten-bit table index. */
            lookup_index <= invalid_pipe[0] ? 10'd0 : normalized_index;
            normalized_magnitude <= captured_magnitude;
            normalized_metadata.negative <= captured_negative;
            normalized_metadata.shift <= captured_leading_one + 6'd1;

            /* Stage 3: one table result supplies both coordinate multipliers. */
            reciprocal <= lookup_reciprocal;
            reciprocal_magnitude <= normalized_magnitude;
            reciprocal_metadata <= normalized_metadata;

            /* Stage 4: two 22x18 unsigned partial products per coordinate. */
            for (int coordinate = 0; coordinate < 2; coordinate++) begin
                for (int numerator_half = 0; numerator_half < 2; numerator_half++) begin
                    partial_product[coordinate][numerator_half] <=
                        reciprocal_magnitude[coordinate][numerator_half*22 +: 22] * reciprocal;
                end
            end
            partial_metadata <= reciprocal_metadata;

            /* Stage 5: combine both numerator halves into the exact product. */
            for (int coordinate = 0; coordinate < 2; coordinate++) begin
                full_product[coordinate] <= {22'b0, partial_product[coordinate][0]} +
                    {partial_product[coordinate][1], 22'b0};
            end
            product_metadata <= partial_metadata;

            /* Stage 6: variable scale and independent guard/sticky extraction. */
            shifted_magnitude <= shifted_magnitude_next;
            round_negative <= product_metadata.negative;
            round_guard <= guard_next;
            round_sticky <= sticky_next;

            /* Stage 7: symmetric RNE, sign restoration, signed saturation. */
            if (invalid_pipe[TEXTURE_COORDINATE_LATENCY-2]) begin
                u_o <= '0;
                v_o <= '0;
            end else begin
                u_o <= rounded_coordinate(
                    shifted_magnitude[0], round_negative[0], round_guard[0], round_sticky[0]
                );
                v_o <= rounded_coordinate(
                    shifted_magnitude[1], round_negative[1], round_guard[1], round_sticky[1]
                );
            end
        end
    end

endmodule : texture_coordinate

`endif
