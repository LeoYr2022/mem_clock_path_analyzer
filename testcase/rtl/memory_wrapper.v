module memory_wrapper (
	input clk_a,
	input cen_a,
	input wen_a,
	input [9:0] addr_a,
	input [31:0] din_a,
	output [31:0] dout_a,

	input clk_b,
	input cen_b,
	input wen_b,
	input [9:0] addr_b,
	input [31:0] din_b,
	output [31:0] dout_b
);

    SRAM_1RW u_sram_a (
        .CLK (clk_a),
        .CEN (cen_a),
        .WEN (wen_a),
        .A   (addr_a),
        .D   (din_a),
        .Q   (dout_a)
    );

    SRAM_1RW u_sram_b (
        .CLK (clk_b),
        .CEN (cen_b),
        .WEN (wen_b),
        .A   (addr_b),
        .D   (din_b),
        .Q   (dout_b)
    );
endmodule
