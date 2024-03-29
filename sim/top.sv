
`include "core.sv"
`include "tb.sv"

module top;

    // Just checking if the core can be instantiated
    core core_inst();

    // Just checking if the TB can be instantiated
    tb tb_inst();

endmodule