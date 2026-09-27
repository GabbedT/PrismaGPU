`ifndef CLIP_TESTER_SV
    `define CLIP_TESTER_SV

module clip_tester (
    input logic [31:0] x_i,
    input logic [31:0] y_i,
    input logic [31:0] z_i,
    input logic [31:0] w_i,

    output logic [5:0] clip_code_o
);

    logic signed [32:0] x, y, z, w;

    assign x = {x_i[31], x_i};
    assign y = {y_i[31], y_i};
    assign z = {z_i[31], z_i};
    assign w = {w_i[31], w_i};


    /* If code bit is 0 then vertex is inside that plane
     * If code bit is 1 then vertex is outside that plane */

    /* Left plane test */
    assign clip_code_o[0] = x < -w;

    /* Right plane test */
    assign clip_code_o[1] = x > w;

    /* Upper plane test */
    assign clip_code_o[2] = y > w;

    /* Lower plane test */
    assign clip_code_o[3] = y < -w;

    /* Far plane test */
    assign clip_code_o[4] = z > w;

    /* Near plane test */
    assign clip_code_o[5] = z < 0;

endmodule : clip_tester

`endif
