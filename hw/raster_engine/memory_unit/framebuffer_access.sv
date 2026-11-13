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
    input re_viewport_size_t viewport_size_i,

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
    logic buffer_full;
    logic [31:0] buffer_address;
    logic [8:0] buffer_y;

    /* Retain a compact pixel descriptor until MERGE. A fresh pixel has three
     * nibbles; a spill retains one/two high nibbles at offset zero. Expanding
     * only when merging avoids registering two mostly-empty 140-bit words. */
    logic [11:0] pending_pixel, pending_nibble_mask;
    logic [4:0] pending_offset;
    logic [1:0] pending_nibbles;
    logic pending_spill;
    logic [127:0] pending_data, pending_mask;
    logic [32:0] pending_address;
    logic [8:0] pending_y;
    logic pending_coordinates_valid, blend_coordinates_valid_CRT;
    logic [127:0] cache_data;
    logic [31:0] cache_tag;
    logic [32:0] blend_address;
    logic cache_valid, blend_second;
    logic [6:0] blend_offset;
    logic [11:0] blend_low;
    logic partial_byte;


//====================================================================================
//      PIXEL ADDRESSES
//====================================================================================

    logic [9:0] viewport_width;
    logic [8:0] viewport_height;
    logic [11:0] pixel_tripled_x, blend_tripled_x;
    logic [14:0] pixel_row, blend_row, pixel_word, blend_word;
    logic [6:0] blend_pixel_offset;
    logic [32:0] pixel_address, blend_address_ext;
    logic [32:0] pending_access_end, blend_access_end;
    logic surface_valid, pixel_in_range, blend_in_range;
    logic pixel_coordinates_valid, blend_coordinates_valid;

    always_comb begin
        viewport_width = 10'd640;
        viewport_height = 9'd480;
        pixel_row = (pixel_y_i << 5) - (pixel_y_i << 1);
        blend_row = (blend_y_i << 5) - (blend_y_i << 1);

        if (viewport_size_i == RE_VIEWPORT_320_240) begin
            viewport_width = 10'd320;
            viewport_height = 9'd240;
        end else begin
            pixel_row = pixel_row << 1;
            blend_row = blend_row << 1;
        end

        /* RGB444: 3*x nibbles; every row starts on a DDR word. */
        pixel_tripled_x = (pixel_x_i << 1) + pixel_x_i;
        blend_tripled_x = (blend_x_i << 1) + blend_x_i;
        pixel_word = pixel_row + pixel_tripled_x[11:5];
        blend_word = blend_row + blend_tripled_x[11:5];
        blend_pixel_offset = {blend_tripled_x[4:0], 2'b0};
        pixel_address = {1'b0, base_i} + {14'b0, pixel_word, 4'b0};
        blend_address_ext = {1'b0, base_i} + {14'b0, blend_word, 4'b0};
        surface_valid = base_i[3:0] == 0;
        pixel_coordinates_valid = surface_valid && (pixel_x_i < viewport_width) && (pixel_y_i < viewport_height);
        blend_coordinates_valid = surface_valid && (blend_x_i < viewport_width) && (blend_y_i < viewport_height);
    end

    /* ACCEPT captures the full address carry and the cheap coordinate checks.
     * Validate the complete one/two-word access in MERGE or BLEND, before any
     * write-buffer merge, flush or DDR request. Keep configuration stable until
     * idle. This splits address generation from bounds comparison without
     * adding a cycle to ordinary pixel writes or clean-cache blend reads. */
    /* Only a fresh three-nibble pixel can have offset 30 or 31. Spill
     * fragments always have offset zero, so their validation covers one beat. */
    assign pending_spill = pending_offset >= 5'd30;
    assign pending_access_end = pending_address + (pending_spill ? 33'd32 : 33'd16);
    assign blend_access_end = blend_address + ((!blend_second && blend_offset > 116) ? 33'd32 : 33'd16);
    assign pixel_in_range = pending_coordinates_valid && (pending_access_end <= {1'b0, end_i});
    assign blend_in_range = blend_coordinates_valid_CRT && (blend_access_end <= {1'b0, end_i});

    always_comb begin
        case (pending_nibbles)
            2'd1: pending_nibble_mask = 12'h00f;
            2'd2: pending_nibble_mask = 12'h0ff;
            2'd3: pending_nibble_mask = 12'hfff;
            default: pending_nibble_mask = '0;
        endcase
    end

    assign pending_data = {116'b0, pending_pixel} << {pending_offset, 2'b0};
    assign pending_mask = {116'b0, pending_nibble_mask} << {pending_offset, 2'b0};

//====================================================================================
//      HANDSHAKES AND BYTE ENABLES
//====================================================================================

    /* Register the 128-bit reduction with the mask update, so framebuffer
     * readiness does not send it back through the complete pixel pipeline. */
    assign pixel_ready_o = state == ACCEPT && !abort_i && !flush_i && !blend_valid_i && !buffer_full;
    assign blend_ready_o = state == ACCEPT && !abort_i && !flush_i && !blend_valid_o && !buffer_full;
    assign idle_o = state == ACCEPT && dirty_bits == 0 && !blend_valid_o;
    assign read_request_o = !abort_i && (state == RMW_REQUEST | state == BLEND_REQUEST);
    assign read_address_o = state == RMW_REQUEST ? buffer_address : blend_address[31:0];
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
        if (!rst_n_i | abort_i) begin
            state <= ACCEPT;
            return_state <= ACCEPT;
            write_buffer <= '0;
            dirty_bits <= '0;
            buffer_full <= 1'b0;
            buffer_address <= '0;
            buffer_y <= '0;
            pending_pixel <= '0;
            pending_offset <= '0;
            pending_nibbles <= '0;
            pending_address <= '0;
            pending_y <= '0;
            pending_coordinates_valid <= 1'b0;
            blend_coordinates_valid_CRT <= 1'b0;
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
                    if (flush_i | buffer_full) begin
                        if (dirty_bits != 0) begin
                            return_state <= ACCEPT;
                            state <= FLUSH;
                        end

                        if (flush_i) begin
                            cache_valid <= 1'b0;
                        end
                    end else if (blend_valid_i && blend_ready_o) begin
                        blend_address <= blend_address_ext;
                        blend_offset <= blend_pixel_offset;
                        blend_coordinates_valid_CRT <= blend_coordinates_valid;
                        blend_second <= 1'b0;
                        return_state <= BLEND;
                        state <= BLEND;
                    end else if (pixel_valid_i && pixel_ready_o) begin
                        pending_address <= pixel_address;
                        pending_coordinates_valid <= pixel_coordinates_valid;
                        pending_y <= pixel_y_i;
                        pending_pixel <= pixel_i;
                        pending_offset <= pixel_tripled_x[4:0];
                        pending_nibbles <= 2'd3;
                        state <= MERGE;
                    end
                end

                MERGE: begin
                    if (!pixel_in_range) begin
                        address_error_o <= 1'b1;
                        state <= FAULT;
                    end else if (dirty_bits != 0 && (buffer_address != pending_address[31:0] | buffer_y != pending_y)) begin
                        return_state <= MERGE;
                        state <= FLUSH;
                    end else begin
                        if (dirty_bits == 0) begin
                            write_buffer <= pending_data;
                        end else begin
                            write_buffer <= (write_buffer & ~pending_mask) | pending_data;
                        end

                        dirty_bits <= dirty_bits | pending_mask;
                        buffer_full <= &(dirty_bits | pending_mask);
                        buffer_address <= pending_address[31:0];
                        buffer_y <= pending_y;
                        if (cache_valid && cache_tag == pending_address[31:0]) begin
                            cache_valid <= 1'b0;
                        end

                        if (pending_spill) begin
                            pending_address <= pending_address + 33'd16;
                            pending_offset <= '0;
                            if (pending_offset == 5'd30) begin
                                pending_pixel <= {8'b0, pending_pixel[11:8]};
                                pending_nibbles <= 2'd1;
                            end else begin
                                pending_pixel <= {4'b0, pending_pixel[11:4]};
                                pending_nibbles <= 2'd2;
                            end
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
                        buffer_full <= 1'b0;
                        state <= return_state;
                    end
                end

                BLEND: begin
                    if (drain_i) begin
                        state <= ACCEPT;
                    end else if (!blend_in_range) begin
                        address_error_o <= 1'b1;
                        state <= FAULT;
                    end else if (dirty_bits != 0) begin
                        /* Validate before flushing preceding writes, so a bad
                         * destination request cannot start memory traffic. */
                        return_state <= BLEND;
                        state <= FLUSH;
                    end else if (cache_valid && cache_tag == blend_address[31:0]) begin
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
                            blend_address <= blend_address + 33'd16;
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
                        cache_tag <= blend_address[31:0];
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

                if (state == BLEND | state == BLEND_REQUEST | state == BLEND_WAIT) begin
                    state <= ACCEPT;
                end
            end
        end
    end

endmodule : framebuffer_access

`endif
