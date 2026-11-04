`ifndef FRAMEBUFFER_ACCESS_SV
    `define FRAMEBUFFER_ACCESS_SV

module framebuffer_access (
    input logic clk_i,
    input logic rst_n_i,

    /* Abort discards local data; drain preserves accepted writes */
    input logic abort_i,
    input logic drain_i,
    input logic flush_i,

    /* Packed RGB444 surface */
    input logic [31:0] base_i,
    input logic [31:0] end_i,
    input logic [9:0] width_i,
    input logic [8:0] height_i,

    /* Pixel write stream */
    input pixel_t pixel_i,
    input logic [9:0] pixel_x_i,
    input logic [8:0] pixel_y_i,
    input logic pixel_valid_i,
    output logic pixel_ready_o,

    /* Destination pixel read */
    input logic blend_valid_i,
    output logic blend_ready_o,
    input logic [9:0] blend_x_i,
    input logic [8:0] blend_y_i,
    input logic blend_ready_i,
    output logic blend_valid_o,
    output pixel_t blend_pixel_o,

    /* Status */
    output logic idle_o,
    output logic address_error_o,

    /* Memory read client */
    output logic read_request_o,
    input logic read_ready_i,
    input logic read_response_i,
    output logic [31:0] read_address_o,
    input logic [127:0] read_data_i,

    /* Memory write client */
    output logic write_request_o,
    input logic write_ready_i,
    input logic write_response_i,
    output logic [31:0] write_address_o,
    output logic [127:0] write_data_o,
    output logic [15:0] write_mask_o
);

//====================================================================================
//      FRAMEBUFFER STATE
//====================================================================================

    typedef enum logic [3:0] {
        ACCEPT, MERGE, FLUSH,
        RMW_REQUEST, RMW_WAIT, WRITE_REQUEST, WRITE_WAIT,
        BLEND, BLEND_REQUEST, BLEND_WAIT,
        FAULT
    } state_t;

    state_t state, return_state;
    logic [127:0] write_buffer, dirty_bits;
    logic [31:0] buffer_address;
    logic [8:0] buffer_y;

    /* One beat plus the part of a pixel crossing its boundary. */
    logic [139:0] pending_data, pending_mask;
    logic [31:0] pending_address;
    logic [8:0] pending_y;
    logic [127:0] cache_data;
    logic [31:0] cache_tag, blend_address;
    logic cache_valid, blend_second;
    logic [6:0] blend_offset;
    logic [11:0] blend_low;
    logic partial_byte;


//====================================================================================
//      PIXEL ADDRESSES
//====================================================================================

    logic [18:0] pixel_index, blend_index;
    logic [22:0] pixel_bit, blend_bit;
    logic [32:0] pixel_address, blend_address_ext;
    logic [32:0] pixel_access_end, blend_access_end;
    logic surface_valid, pixel_in_range, blend_in_range;
    logic pixel_split, blend_split;

    /* y*width+x fits in 19 bits for all input values; RGB444 uses 12 bits. */
    assign pixel_index = pixel_y_i * width_i + pixel_x_i;
    assign blend_index = blend_y_i * width_i + blend_x_i;
    assign pixel_bit = pixel_index * 23'd12;
    assign blend_bit = blend_index * 23'd12;

    assign pixel_address = {1'b0, base_i} + {13'b0, pixel_bit[22:7], 4'b0};
    assign blend_address_ext = {1'b0, base_i} + {13'b0, blend_bit[22:7], 4'b0};
    assign pixel_split = pixel_bit[6:0] > 7'd116;
    assign blend_split = blend_bit[6:0] > 7'd116;
    assign pixel_access_end = pixel_address + (pixel_split ? 33'd32 : 33'd16);
    assign blend_access_end = blend_address_ext + (blend_split ? 33'd32 : 33'd16);

    assign surface_valid = (width_i != 0) && (width_i <= 640) &&
                           (height_i != 0) && (height_i <= 480) && (base_i[3:0] == 0);
    assign pixel_in_range = surface_valid && (pixel_x_i < width_i) && (pixel_y_i < height_i) &&
                           (pixel_access_end <= {1'b0, end_i});
    assign blend_in_range = surface_valid && (blend_x_i < width_i) && (blend_y_i < height_i) &&
                           (blend_access_end <= {1'b0, end_i});


//====================================================================================
//      HANDSHAKES AND BYTE ENABLES
//====================================================================================

    assign pixel_ready_o = state == ACCEPT && !abort_i && !flush_i && !blend_valid_i && dirty_bits != '1;
    assign blend_ready_o = state == ACCEPT && !abort_i && !flush_i && !blend_valid_o && dirty_bits != '1;
    assign idle_o = state == ACCEPT && dirty_bits == 0 && !blend_valid_o;
    assign read_request_o = !abort_i && (state == RMW_REQUEST || state == BLEND_REQUEST);
    assign read_address_o = state == RMW_REQUEST ? buffer_address : blend_address;
    assign write_request_o = !abort_i && state == WRITE_REQUEST;
    assign write_address_o = buffer_address;
    assign write_data_o = write_buffer;
    always_comb begin
        partial_byte = 1'b0;
        for (int b = 0; b < 16; b++) begin
            write_mask_o[b] = |dirty_bits[8*b +: 8];
            if (dirty_bits[8*b +: 8] != 0 && dirty_bits[8*b +: 8] != 8'hff) begin
                partial_byte = 1'b1;
            end
        end
    end


//====================================================================================
//      PIXEL WRITER AND READ CACHE
//====================================================================================

    always_ff @(posedge clk_i) begin
        if (!rst_n_i || abort_i) begin
            state <= ACCEPT;
            return_state <= ACCEPT;
            write_buffer <= '0;
            dirty_bits <= '0;
            buffer_address <= '0;
            buffer_y <= '0;
            pending_data <= '0;
            pending_mask <= '0;
            pending_address <= '0;
            pending_y <= '0;
            cache_valid <= 1'b0;
            cache_data <= '0;
            cache_tag <= '0;
            blend_address <= '0;
            blend_offset <= '0;
            blend_second <= 1'b0;
            blend_low <= '0;
            blend_valid_o <= 1'b0;
            blend_pixel_o <= '0;
            address_error_o <= 1'b0;
        end else begin
            address_error_o <= 1'b0;
            if (blend_valid_o && blend_ready_i) begin
                blend_valid_o <= 1'b0;
            end
            case (state)
                ACCEPT: begin
                    if (flush_i || dirty_bits == '1) begin
                        if (dirty_bits != 0) begin
                            return_state <= ACCEPT;
                            state <= FLUSH;
                        end

                        if (flush_i) begin
                            cache_valid <= 1'b0;
                        end
                    end else if (blend_valid_i && blend_ready_o) begin
                        if (!blend_in_range) begin
                            address_error_o <= 1'b1;
                            state <= FAULT;
                        end else begin
                            blend_address <= blend_address_ext[31:0];
                            blend_offset <= blend_bit[6:0];
                            blend_second <= 1'b0;
                            return_state <= BLEND;
                            if (dirty_bits != 0) begin
                                state <= FLUSH;
                            end else begin
                                state <= BLEND;
                            end
                        end
                    end else if (pixel_valid_i && pixel_ready_o) begin
                        if (!pixel_in_range) begin
                            address_error_o <= 1'b1;
                            state <= FAULT;
                        end else begin
                            pending_address <= pixel_address[31:0];
                            pending_y <= pixel_y_i;
                            pending_data <= 140'(pixel_i) << pixel_bit[6:0];
                            pending_mask <= 140'hfff << pixel_bit[6:0];
                            state <= MERGE;
                        end
                    end
                end

                MERGE: begin
                    if (dirty_bits != 0 && (buffer_address != pending_address || buffer_y != pending_y)) begin
                        return_state <= MERGE;
                        state <= FLUSH;
                    end else begin
                        if (dirty_bits == 0) begin
                            write_buffer <= pending_data[127:0];
                        end else begin
                            write_buffer <= (write_buffer & ~pending_mask[127:0]) | pending_data[127:0];
                        end

                        dirty_bits <= dirty_bits | pending_mask[127:0];
                        buffer_address <= pending_address;
                        buffer_y <= pending_y;
                        if (cache_valid && cache_tag == pending_address) begin
                            cache_valid <= 1'b0;
                        end

                        if (pending_mask[139:128] != 0) begin
                            pending_address <= pending_address + 32'd16;
                            pending_mask <= {128'b0, pending_mask[139:128]};
                            pending_data <= {128'b0, pending_data[139:128]};
                        end else begin
                            state <= ACCEPT;
                        end
                    end
                end

                FLUSH: begin
                    cache_valid <= 1'b0;
                    if (partial_byte) begin
                        state <= RMW_REQUEST;
                    end else begin
                        state <= WRITE_REQUEST;
                    end
                end

                RMW_REQUEST: begin
                    if (read_ready_i) begin
                        state <= RMW_WAIT;
                    end
                end

                RMW_WAIT: begin
                    if (read_response_i) begin
                        write_buffer <= (read_data_i & ~dirty_bits) | (write_buffer & dirty_bits);
                        state <= WRITE_REQUEST;
                    end
                end

                WRITE_REQUEST: begin
                    if (write_ready_i) begin
                        state <= WRITE_WAIT;
                    end
                end

                WRITE_WAIT: begin
                    if (write_response_i) begin
                        dirty_bits <= '0;
                        state <= return_state;
                    end
                end

                BLEND: begin
                    if (cache_valid && cache_tag == blend_address) begin
                        if (blend_second) begin
                            /* A 12-bit pixel can cross at offset 120 or 124. */
                            if (blend_offset == 7'd120) begin
                                blend_pixel_o <= pixel_t'({cache_data[3:0], blend_low[7:0]});
                            end else begin
                                blend_pixel_o <= pixel_t'({cache_data[7:0], blend_low[3:0]});
                            end
                            blend_valid_o <= 1'b1;
                            state <= ACCEPT;
                        end else if (blend_offset > 116) begin
                            blend_low <= 12'(cache_data >> blend_offset);
                            blend_address <= blend_address + 32'd16;
                            blend_second <= 1'b1;
                        end else begin
                            blend_pixel_o <= pixel_t'(cache_data >> blend_offset);
                            blend_valid_o <= 1'b1;
                            state <= ACCEPT;
                        end
                    end else begin
                        state <= BLEND_REQUEST;
                    end
                end

                BLEND_REQUEST: begin
                    if (read_ready_i) begin
                        state <= BLEND_WAIT;
                    end
                end

                BLEND_WAIT: begin
                    if (read_response_i) begin
                        cache_data <= read_data_i;
                        cache_tag <= blend_address;
                        cache_valid <= 1'b1;
                        state <= BLEND;
                    end
                end

                default: begin
                end
            endcase

            /* Cancel the read consumer while accepted pixel writes drain. */
            if (drain_i) begin
                blend_valid_o <= 1'b0;
                if (return_state == BLEND) begin
                    return_state <= ACCEPT;
                end

                if (state == BLEND || state == BLEND_REQUEST || state == BLEND_WAIT) begin
                    state <= ACCEPT;
                end
            end
        end
    end

endmodule : framebuffer_access

`endif
