`ifndef VIEWPORT_TRANSFORM_SV
    `define VIEWPORT_TRANSFORM_SV

module viewport_transform (
    input logic clk_i,
    input logic rst_n_i,

    input vertex_t vertex_i,
    input logic valid_i,

    /* Screen view to convert X, Y normalized into
     * screen coordinates */
    input logic [31:0] width_screen_i,
    input logic [31:0] height_screen_i,

    output proc_vertex_t vertex_o,
    output logic valid_o
);

    /* Viewport transform */
    logic signed [32:0] x_offset, y_offset;
    logic signed [65:0] x_scaled, y_scaled;

    /* This is (1.0 + x) and (1.0 - y) */
    assign x_offset = 33'sd65536 + $signed(vertex_i.pos.x);
    assign y_offset = 33'sd65536 - $signed(vertex_i.pos.y);

    assign x_scaled = x_offset * $signed({1'b0, width_screen_i});
    assign y_scaled = y_offset * $signed({1'b0, height_screen_i});


    logic signed [65:0] x_scaled_ff, y_scaled_ff;
    logic [$bits(vertex_i.pos.z) - 1:0] z_ff;
    logic [$bits(vertex_i.tex.u) - 1:0] u_ff, v_ff;
    logic [$bits(vertex_i.col.r) - 1:0] r_ff, g_ff, b_ff, a_ff;

        always_ff @(posedge clk_i) begin
            x_scaled_ff <= x_scaled;
            y_scaled_ff <= y_scaled;
            z_ff <= vertex_i.pos.z;

            u_ff <= vertex_i.tex.u;
            v_ff <= vertex_i.tex.v;

            r_ff <= vertex_i.col.r;
            g_ff <= vertex_i.col.g;
            b_ff <= vertex_i.col.b;
            a_ff <= vertex_i.col.a;
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                valid_o <= 1'b0;
            end else begin
                valid_o <= valid_i;
            end
        end


    /* Divide by two and convert 16 fractional bits into eight. */
    assign vertex_o.pos.x = (x_scaled_ff + 66'sd256) >>> 9;
    assign vertex_o.pos.y = (y_scaled_ff + 66'sd256) >>> 9;

    assign vertex_o.pos.z = z_ff;

    assign vertex_o.tex.u = u_ff;
    assign vertex_o.tex.v = v_ff;

    assign vertex_o.col.r = r_ff;
    assign vertex_o.col.g = g_ff;
    assign vertex_o.col.b = b_ff;
    assign vertex_o.col.a = a_ff;

endmodule : viewport_transform

`endif