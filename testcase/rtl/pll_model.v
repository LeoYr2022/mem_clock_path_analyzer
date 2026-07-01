// Behavioral PLL model used as a clock root.
module pll_model (
    input  ref_clk,
    output pll_clk
);
    assign pll_clk = ref_clk;
endmodule
