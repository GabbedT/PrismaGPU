`ifndef CULL_ENGINE_SV
    `define CULL_ENGINE_SV

module cull_engine (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Processed triangle */
    input proc_triangle_t triangle_i,
    input logic valid_i,

    /* Register setup */
    input front_face_t front_face_i,
    input cull_mode_t cull_mode_i,

    /* Output */
    output proc_triangle_t triangle_o,
    output logic valid_o,
    output logic discard_o,
    output logic busy_o
);

//====================================================================================
//      FIRST STAGE
//==================================================================================== 

    /* Subtraction intermediate results */
    /* Valid GE output spans at most the viewport plus reciprocal rounding. */
    logic signed [18:0] sub_xba, sub_xca;
    logic signed [17:0] sub_yba, sub_yca;

    /* Multiplications */
    logic signed [36:0] mul_1, mul_1_ff, mul_2, mul_2_ff;
    proc_vertex_t [2:0] vertices_ff;


    assign sub_xba = $signed(triangle_i.vtx[1].pos.x) - $signed(triangle_i.vtx[0].pos.x);
    assign sub_yca = $signed(triangle_i.vtx[2].pos.y) - $signed(triangle_i.vtx[0].pos.y);

    assign mul_1 = sub_xba * sub_yca;


    assign sub_xca = $signed(triangle_i.vtx[2].pos.x) - $signed(triangle_i.vtx[0].pos.x);
    assign sub_yba = $signed(triangle_i.vtx[1].pos.y) - $signed(triangle_i.vtx[0].pos.y);

    assign mul_2 = sub_xca * sub_yba;


        always_ff @(posedge clk_i) begin
            if (!stall_i) begin
                mul_1_ff <= mul_1;
                mul_2_ff <= mul_2;

                vertices_ff <= triangle_i.vtx;
            end
        end


    logic valid_ff;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                valid_ff <= 1'b0;
            end else if (!stall_i) begin
                valid_ff <= valid_i;
            end
        end


//====================================================================================
//      SECOND STAGE
//==================================================================================== 

    logic signed [37:0] triangle_area;

    assign triangle_area = mul_1_ff - mul_2_ff;

    logic zero_area, ccw, cw;
    logic keep_triangle;

    assign zero_area = triangle_area == 38'sd0;
    assign ccw = triangle_area < 38'sd0;
    assign cw = triangle_area > 38'sd0;


    /* Selection */
    always_comb begin
        /* Default Value */
        keep_triangle = 1'b0;

        if (valid_ff) begin
            if (zero_area) begin
                keep_triangle = 1'b0;
            end else begin
                case ({front_face_i, cull_mode_i})
                    {CW, FRONT}: keep_triangle = ccw;

                    {CW, BACK}: keep_triangle = cw;

                    {CCW, FRONT}: keep_triangle = cw;

                    {CCW, BACK}: keep_triangle = ccw;

                    {CW, NONE}: keep_triangle = 1'b1;

                    {CCW, NONE}: keep_triangle = 1'b1;

                    default: keep_triangle = 1'b0;
                endcase
            end
        end
    end

    /* Capture area, vertices and classification together before they drive
     * the output queue. One additional advancing cycle, one triangle/clock.
     * Both stages hold on stall; reset only needs to invalidate their work. */
    always_ff @(posedge clk_i) begin
        if (!stall_i) begin
            triangle_o <= '{area: triangle_area, vtx: vertices_ff};
        end

        if (!rst_n_i) begin
            valid_o <= 1'b0;
            discard_o <= 1'b0;
        end else if (!stall_i) begin
            valid_o <= keep_triangle;
            discard_o <= valid_ff & !keep_triangle;
        end
    end

    assign busy_o = valid_ff | valid_o | discard_o;

endmodule : cull_engine

`endif
