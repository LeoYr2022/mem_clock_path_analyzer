// 2:1 behavioral clock mux.
module clk_mux (
    input  clk_a,
    input  clk_b,
    input  sel,
    output clk_out
);
    assign clk_out = sel ? clk_b : clk_a;
endmodule
