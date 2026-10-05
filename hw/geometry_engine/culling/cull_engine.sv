`ifndef CULL_ENGINE_SV
    `define CULL_ENGINE_SV

module cull_engine (
    input logic clk_i,
    input logic rst_n_i,

    /* Processed triangle */
    input proc_triangle_t triangle_i,
    input logic valid_i,

    /* Register setup */
    input front_face_t front_face_i,
    input cull_mode_t cull_mode_i,

    /* Output */
    output proc_triangle_t triangle_o,
    output logic valid_o
);

//====================================================================================
//      FIRST STAGE
//==================================================================================== 

    /* Subtraction intermediate results */
    logic signed [24:0] sub_xba, sub_xca, sub_yba, sub_yca;

    /* Multiplications */
    logic signed [49:0] mul_1, mul_1_ff, mul_2, mul_2_ff;


    assign sub_xba = $signed(triangle_i.vtx[1].pos.x) - $signed(triangle_i.vtx[0].pos.x);
    assign sub_yca = $signed(triangle_i.vtx[2].pos.y) - $signed(triangle_i.vtx[0].pos.y);

    assign mul_1 = sub_xba * sub_yca;


    assign sub_xca = $signed(triangle_i.vtx[2].pos.x) - $signed(triangle_i.vtx[0].pos.x);
    assign sub_yba = $signed(triangle_i.vtx[1].pos.y) - $signed(triangle_i.vtx[0].pos.y);

    assign mul_2 = sub_yba * sub_xca;


        always_ff @(posedge clk_i) begin
            mul_1_ff <= mul_1;
            mul_2_ff <= mul_2;

            triangle_o <= triangle_i;
        end


    logic valid_ff;

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                valid_ff <= 1'b0;
            end else begin
                valid_ff <= valid_i;
            end
        end


//====================================================================================
//      SECOND STAGE
//==================================================================================== 

    logic signed [50:0] triangle_area;

    assign triangle_area = mul_1_ff - mul_2_ff;


    logic zero_area, ccw, cw;

    assign zero_area = triangle_area == '0;
    assign ccw = triangle_area < '0;
    assign cw = triangle_area > '0;


    /* Selection */
    always_comb begin
        /* Default Value */
        valid_o = 1'b0;

        if (valid_ff) begin
            if (zero_area) begin
                valid_o = 1'b0;
            end else begin
                case ({front_face_i, cull_mode_i})
                    {CW, FRONT}: valid_o = ccw;

                    {CW, BACK}: valid_o = cw;

                    {CCW, FRONT}: valid_o = cw;

                    {CCW, BACK}: valid_o = ccw;

                    {CW, NONE}: valid_o = 1'b1;

                    {CCW, NONE}: valid_o = 1'b1;
                endcase
            end
        end
    end

endmodule : cull_engine

`endif