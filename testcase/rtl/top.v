// Top module wiring PLL -> DIV/2 -> MUX -> ICG -> two SRAMs.
module top (
    input  ref_clk,
    input  test_en,
    input  mem_en,
    input  rst_n,
    input  cen_a,
    input  cen_b,
    input  wen_a,
    input  wen_b,
    input  [9:0]  addr_a,
    input  [9:0]  addr_b,
    input  [31:0] din_a,
    input  [31:0] din_b,
    output [31:0] dout_a,
    output [31:0] dout_b
);
    wire pll_clk;
    wire clk_div2;
    wire sel_clk;
    wire gated_clk;

    pll_model u_pll (
        .ref_clk (ref_clk),
        .pll_clk (pll_clk)
    );

    clk_div2 u_div (
        .clk_in  (pll_clk),
        .rst_n   (rst_n),
        .clk_out (clk_div2)
    );

    clk_mux u_mux (
        .clk_a   (clk_div2),
        .clk_b   (pll_clk ),
        .sel     (test_en),
        .clk_out (sel_clk)
    );

    icg u_icg_sram_a (
        .clk_in  (sel_clk),
        .en      (mem_en),
        .clk_out (gated_clk_a)
    );

    icg u_icg_sram_b (
        .clk_in  (sel_clk),
        .en      (mem_en),
        .clk_out (gated_clk_b)
    );

    SRAM_1RW u_sram_a (
        .CLK (gated_clk_a),
        .CEN (cen_a),
        .WEN (wen_a),
        .A   (addr_a),
        .D   (din_a),
        .Q   (dout_a)
    );

    SRAM_1RW u_sram_b (
        .CLK (gated_clk_b),
        .CEN (cen_b),
        .WEN (wen_b),
        .A   (addr_b),
        .D   (din_b),
        .Q   (dout_b)
    );
endmodule
