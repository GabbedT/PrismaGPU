`ifndef GPU_DDR_INTERFACE_SV
    `define GPU_DDR_INTERFACE_SV

interface gpu_ddr_interface;

    /* Request handshake; addresses are bytes, aligned to 16. */
    logic trx_req;
    logic trx_type;
    logic [31:0] trx_addr;
    logic ready;

    /* One strobe bit per byte; one enables the write. */
    logic [15:0] wstrobe;
    logic [127:0] wdata;

    /* Error qualifies valid. Write completion guarantees read visibility. */
    logic read_valid;
    logic read_error;
    logic [127:0] rdata;
    logic write_valid;
    logic write_error;

    modport master (
        output trx_req,
        output trx_type,
        output trx_addr,
        input ready,

        output wstrobe,
        output wdata,

        input read_valid,
        input read_error,
        input rdata,
        input write_valid,
        input write_error
    );

    modport slave (
        input trx_req,
        input trx_type,
        input trx_addr,
        output ready,

        input wstrobe,
        input wdata,

        output read_valid,
        output read_error,
        output rdata,
        output write_valid,
        output write_error
    );

endinterface : gpu_ddr_interface

`endif
