/* Simulation-only counters. All events are sampled at the accepting clock edge.
 * Stall categories overlap: do not add them to estimate total stalled cycles. */
module perf_counter #(
    parameter int COUNT = 46
) (
    input logic clk_i,
    input logic rst_n_i,
    input logic frame_begin_i,
    input logic frame_end_i,
    input logic [COUNT-1:0][31:0] events_i
);

//====================================================================================
//      TOTALS AND PER-FRAME SNAPSHOTS
//====================================================================================

    longint unsigned total [COUNT], current_frame [COUNT], last_frame [COUNT];
    logic active;
    always_ff @(posedge clk_i) begin
        if (!rst_n_i) begin
            active <= 1'b0;
            for (int i = 0; i < COUNT; i++) begin
                total[i] <= 0;
                current_frame[i] <= 0;
                last_frame[i] <= 0;
            end
        end else begin
            if (frame_begin_i) active <= 1'b1;
            if (frame_end_i) active <= 1'b0;
            for (int i = 0; i < COUNT; i++) begin
                total[i] <= total[i] + events_i[i];
                if (frame_begin_i) current_frame[i] <= 0;
                else if (active) current_frame[i] <= current_frame[i] + events_i[i];
                if (frame_end_i) last_frame[i] <= current_frame[i] + events_i[i];
            end
        end
    end

//====================================================================================
//      HOST REPORTING INTERFACE
//====================================================================================

    export "DPI-C" function gpu_perf_read;
    export "DPI-C" function gpu_perf_name;
    function longint unsigned gpu_perf_read(input int index, input bit snapshot);
        if (index < 0 || index >= COUNT) return 0;
        return snapshot ? last_frame[index] : total[index];
    endfunction

    function string gpu_perf_name(input int index);
        case (index)
             0: return "cycles";
             1: return "gpu_busy_cycles";
             2: return "ge_busy_cycles";
             3: return "re_busy_cycles";
             4: return "ge_input_words";
             5: return "ge_output_words";
             6: return "ge_input_vertices";
             7: return "matrix_vertices";
             8: return "clipped_vertices";
             9: return "perspective_vertices";
            10: return "viewport_vertices";
            11: return "ge_output_triangles";
            12: return "clip_discarded_triangles";
            13: return "cull_discarded_triangles";
            14: return "re_input_triangles";
            15: return "re_done_triangles";
            16: return "re_discarded_triangles";
            17: return "output_pixels";
            18: return "z_rejected_pixels";
            19: return "ge_raster_stall_cycles";
            20: return "ge_packer_stall_cycles";
            21: return "input_fifo_full_cycles";
            22: return "setup_busy_cycles";
            23: return "raster_busy_cycles";
            24: return "pixel_backpressure_cycles";
            25: return "ddr_read_beats";
            26: return "ddr_write_beats";
            27: return "ddr_read_request_wait_cycles";
            28: return "ddr_write_request_wait_cycles";
            29: return "ddr_read_pending_cycles";
            30: return "ddr_write_pending_cycles";
            31: return "ddr_write_bytes";
            32: return "ge_read_bytes";
            33: return "ge_write_bytes";
            34: return "mmio_reads";
            35: return "mmio_writes";
            36: return "memory_errors";
            37: return "setup_errors";
            38: return "ge_errors";
            39: return "frames";
            40: return "blend_read_requests";
            41: return "blend_busy_cycles";
            42: return "texture_load_beats";
            43: return "framebuffer_write_pixels";
            44: return "setup_compute_cycles";
            45: return "setup_wait_raster_cycles";
            default: return "unknown";
        endcase
    endfunction

endmodule : perf_counter
