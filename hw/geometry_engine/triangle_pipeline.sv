`ifndef TRIANGLE_PIPELINE_SV
    `define TRIANGLE_PIPELINE_SV

module triangle_pipeline (
    input logic clk_i,
    input logic rst_n_i,
    input logic stall_i,

    /* Input transfer: valid_i && !stall_o */
    input vertex_t vertex_i,
    input logic valid_i,
    output logic stall_o,

    /* Matrix stage */
    input logic [3:0][3:0][31:0] coefficient_i,

    /* Viewport transform stage */
    input logic [31:0] width_screen_i,
    input logic [31:0] height_screen_i,

    /* Cull stage */
    input front_face_t front_face_i,
    input cull_mode_t cull_mode_i,

    /* Output transfer: valid_o && !stall_i */
    output proc_triangle_t triangle_o,
    output logic valid_o,
    output triangle_error_t error_o
);

//====================================================================================
//      STALL CONTROL
//====================================================================================

    logic cull_stall, viewport_stall, perspective_stall, clip_stall;
    logic triangle_full, processed_full;

    /* Store backpressure freezes all stages. A full buffer stops its producer. */
    assign cull_stall = stall_i;
    assign viewport_stall = cull_stall | processed_full;
    assign perspective_stall = viewport_stall;
    assign clip_stall = perspective_stall;

    /* A busy clip engine retains the input triangle until clip_done. */
    assign stall_o = clip_stall | triangle_full;


//====================================================================================
//      MATRIX ENGINE
//====================================================================================

    vertex_t matrix_vertex;

    matrix_engine matrix_transform (
        .vertex_i      ( vertex_i      ),
        .coefficient_i ( coefficient_i ),
        .vertex_o      ( matrix_vertex )
    );


    triangle_t buffered_triangle;
    logic triangle_valid, clip_done;

    /* Keep the triangle stable until clipping and assembly complete. */
    triangle_buffer input_buffer (
        .clk_i      ( clk_i             ),
        .rst_n_i    ( rst_n_i           ),
        .stall_i    ( clip_stall        ),
        .accept_i   ( clip_done         ),
        .valid_i    ( valid_i           ),
        .vertex_i   ( matrix_vertex     ),
        .full_o     ( triangle_full     ),
        .valid_o    ( triangle_valid    ),
        .triangle_o ( buffered_triangle )
    );


//====================================================================================
//      CLIP ENGINE
//====================================================================================

    vertex_t clip_vertex;
    logic clip_valid, clip_error;

    clip_engine clip_transform (
        .clk_i      ( clk_i             ),
        .rst_n_i    ( rst_n_i           ),
        .stall_i    ( clip_stall        ),
        .triangle_i ( buffered_triangle ),
        .valid_i    ( triangle_valid    ),
        .stall_o    (                   ),
        .vertex_o   ( clip_vertex       ),
        .valid_o    ( clip_valid        ),
        .done_o     ( clip_done         ),
        .error_o    ( clip_error        )
    );


    vertex_t clip_vertex_ff;
    logic clip_valid_ff;

        always_ff @(posedge clk_i) begin
            if (!perspective_stall) begin
                clip_vertex_ff <= clip_vertex;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                clip_valid_ff <= 1'b0;
            end else if (!perspective_stall) begin
                clip_valid_ff <= clip_valid;
            end
        end


//====================================================================================
//      PERSPECTIVE DIVIDE
//====================================================================================

    vertex_t perspective_vertex;
    logic perspective_valid, perspective_error;

    perspective_divider perspective_transform (
        .clk_i    ( clk_i              ),
        .rst_n_i  ( rst_n_i            ),
        .stall_i  ( perspective_stall  ),
        .vertex_i ( clip_vertex_ff     ),
        .valid_i  ( clip_valid_ff      ),
        .vertex_o ( perspective_vertex ),
        .error_o  ( perspective_error  ),
        .valid_o  ( perspective_valid  )
    );


    vertex_t perspective_vertex_ff;
    logic perspective_valid_ff, perspective_error_ff;

        always_ff @(posedge clk_i) begin
            if (!viewport_stall) begin
                perspective_vertex_ff <= perspective_vertex;
            end
        end

        always_ff @(posedge clk_i) begin
            if (!rst_n_i) begin
                perspective_valid_ff <= 1'b0;
                perspective_error_ff <= 1'b0;
            end else if (!viewport_stall) begin
                perspective_valid_ff <= perspective_valid;
                perspective_error_ff <= perspective_valid & perspective_error;
            end
        end


//====================================================================================
//      VIEWPORT TRANSFORM
//====================================================================================

    proc_vertex_t viewport_vertex;
    logic viewport_valid, viewport_error;

    viewport_transform screen_transform (
        .clk_i           ( clk_i                 ),
        .rst_n_i         ( rst_n_i               ),
        .stall_i         ( viewport_stall        ),
        .vertex_i        ( perspective_vertex_ff ),
        .valid_i         ( perspective_valid_ff  ),
        .error_i         ( perspective_error_ff  ),
        .width_screen_i  ( width_screen_i        ),
        .height_screen_i ( height_screen_i       ),
        .vertex_o        ( viewport_vertex       ),
        .valid_o         ( viewport_valid        ),
        .error_o         ( viewport_error        )
    );


    proc_triangle_t processed_triangle;
    logic processed_valid;

    proc_triangle_buffer output_buffer (
        .clk_i      ( clk_i              ),
        .rst_n_i    ( rst_n_i            ),
        .stall_i    ( cull_stall         ),
        .accept_i   ( !cull_stall        ),
        .valid_i    ( viewport_valid     ),
        .error_i    ( viewport_error     ),
        .vertex_i   ( viewport_vertex    ),
        .full_o     ( processed_full     ),
        .valid_o    ( processed_valid    ),
        .triangle_o ( processed_triangle )
    );


//====================================================================================
//      CULL ENGINE
//====================================================================================

    cull_engine triangle_culler (
        .clk_i        ( clk_i              ),
        .rst_n_i      ( rst_n_i            ),
        .stall_i      ( cull_stall         ),
        .triangle_i   ( processed_triangle ),
        .valid_i      ( processed_valid    ),
        .front_face_i ( front_face_i       ),
        .cull_mode_i  ( cull_mode_i        ),
        .triangle_o   ( triangle_o         ),
        .valid_o      ( valid_o            )
    );

        always_comb begin
            /* Default value */
            error_o = TRIANGLE_NO_ERROR;

            if (rst_n_i) begin
                if (clip_error) begin
                    error_o = TRIANGLE_CLIP_ERROR;
                end else if (perspective_valid & perspective_error) begin
                    error_o = TRIANGLE_PERSPECTIVE_ERROR;
                end
            end
        end

endmodule : triangle_pipeline

`endif
