`ifndef TEXTURIZER_SV
    `define TEXTURIZER_SV

module texturizer (
    input logic clk_i,
    input logic rst_n_i,

    /* Global pipeline hold; accept/consume a pixel only when !stall_o. */
    input logic stall_i,
    output logic stall_o,

    input logic texture_en_i,

    /* 00: 8x8, 01: 16x16, 10: 32x32, 11: 64x64. */
    input texture_size_t texture_size_i,

    input logic pixel_valid_i,
    input logic [9:0] pixel_x_i,
    input logic [8:0] pixel_y_i,

    /* Preserve interpolator RGB lanes verbatim: signed S(36,12). */
    input logic [2:0][35:0] color_i,

    /* Interpolated perspective attributes: signed S(44,16). */
    input logic signed [43:0] u_over_w_i,
    input logic signed [43:0] v_over_w_i,
    input logic signed [43:0] inv_w_i,

    /* Texture memory */
    input logic write_en_i,
    input logic [8:0] write_address_i,
    input logic [127:0] write_data_i,

    /* Pixel out */
    output logic pixel_valid_o,
    output logic [9:0] pixel_x_o,
    output logic [8:0] pixel_y_o,
    output logic [2:0][35:0] color_o,

    /* R[15:12], G[11:8], B[7:4], A[3:0]; meaningful with texture_valid_o. */
    output logic [15:0] texel_o,
    output logic texture_valid_o
);

    logic signed [43:0] u, v;
    logic coordinate_valid, coordinate_invalid;
    logic [TEXTURIZER_LATENCY - 1:0] pixel_valid_pipe;
    logic [9:0] pixel_x_pipe [TEXTURIZER_LATENCY];
    logic [8:0] pixel_y_pipe [TEXTURIZER_LATENCY];
    logic [2:0][35:0] color_pipe [TEXTURIZER_LATENCY];
    texture_size_t size_pipe [TEXTURE_COORDINATE_LATENCY];
    logic [5:0] texel_u, texel_v;
    logic read_en;
    logic [11:0] read_address;

    assign stall_o = stall_i;

//====================================================================================
//      TEXEL COORDINATE COMPUTATION
//====================================================================================

    texture_coordinate coordinate_pipeline (
        .clk_i      ( clk_i                        ),
        .rst_n_i    ( rst_n_i                      ),
        .stall_i    ( stall_i                      ),
        .valid_i    ( pixel_valid_i & texture_en_i ),
        .u_over_w_i ( u_over_w_i                   ),
        .v_over_w_i ( v_over_w_i                   ),
        .inv_w_i    ( inv_w_i                      ),
        .u_o        ( u                            ),
        .v_o        ( v                            ),
        .valid_o    ( coordinate_valid             ),
        .invalid_o  ( coordinate_invalid           )
    );

    /* These payload registers deliberately sit outside texture_coordinate.
     * Bypass pixels take the same path and latency as textured pixels. */
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            pixel_valid_pipe <= '0;
        end else if (!stall_i) begin
            pixel_valid_pipe <= {pixel_valid_pipe[TEXTURIZER_LATENCY - 2:0], pixel_valid_i};
        end
    end

    always_ff @(posedge clk_i) begin
        if (rst_n_i & !stall_i) begin
            pixel_x_pipe[0] <= pixel_x_i;
            pixel_y_pipe[0] <= pixel_y_i;
            color_pipe[0] <= color_i;
            size_pipe[0] <= texture_size_i;

            for (int i = 1; i < TEXTURIZER_LATENCY; i++) begin
                pixel_x_pipe[i] <= pixel_x_pipe[i - 1];
                pixel_y_pipe[i] <= pixel_y_pipe[i - 1];
                color_pipe[i] <= color_pipe[i - 1];
            end

            for (int i = 1; i < TEXTURE_COORDINATE_LATENCY; i++) begin
                size_pipe[i] <= size_pipe[i - 1];
            end
        end
    end


//====================================================================================
//      TEXEL MEMORY
//====================================================================================

    /* Normalized coordinates: floor(U * size), clamped to [0, size-1].
     * Coordinate rounding to F16 takes place before this point sampling. */
    function automatic logic [5:0] texel_index(
        input logic signed [43:0] value,
        input texture_size_t size
    );
        if (value <= 0) begin
            texel_index = '0;
        end else if (value >= 44'sd65536) begin
            texel_index = 6'd63 >> (2'd3 - size);
        end else begin
            case (size)
                TEXTURE_SIZE_8: texel_index = {3'b0, value[15:13]};
                TEXTURE_SIZE_16: texel_index = {2'b0, value[15:12]};
                TEXTURE_SIZE_32: texel_index = {1'b0, value[15:11]};
                TEXTURE_SIZE_64: texel_index = value[15:10];
                default: texel_index = '0;
            endcase
        end
    endfunction

    assign texel_u = texel_index(u, size_pipe[TEXTURE_COORDINATE_LATENCY - 1]);
    assign texel_v = texel_index(v, size_pipe[TEXTURE_COORDINATE_LATENCY - 1]);

    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            read_en <= 1'b0;
        end else if (!stall_i) begin
            read_en <= coordinate_valid & !coordinate_invalid;
        end

        if (!stall_i) begin
            read_address <= {texel_v, texel_u};
        end
    end

    texel_memory texture_memory (
        .clk_i           ( clk_i           ),
        .rst_n_i         ( rst_n_i         ),
        .stall_i         ( stall_i         ),
        .write_en_i      ( write_en_i      ),
        .write_address_i ( write_address_i ),
        .write_data_i    ( write_data_i    ),
        .read_en_i       ( read_en         ),
        .read_address_i  ( read_address    ),
        .texel_o         ( texel_o         ),
        .read_valid_o    ( texture_valid_o )
    );

    assign pixel_valid_o = pixel_valid_pipe[TEXTURIZER_LATENCY - 1];
    assign pixel_x_o = pixel_x_pipe[TEXTURIZER_LATENCY - 1];
    assign pixel_y_o = pixel_y_pipe[TEXTURIZER_LATENCY - 1];
    assign color_o = color_pipe[TEXTURIZER_LATENCY - 1];

endmodule : texturizer

`endif
