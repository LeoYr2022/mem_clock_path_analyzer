// Simple AND-gate integrated clock gating cell.
module icg (
    input  clk_in,
    input  en,
    output clk_out
);
    assign clk_out = clk_in & en;
endmodule
