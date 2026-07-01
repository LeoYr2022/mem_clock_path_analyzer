// Placeholder memory module. Only the CLK port matters to the analyzer.
module SRAM_1RW (
    input        CLK,
    input        CEN,
    input        WEN,
    input  [9:0] A,
    input  [31:0] D,
    output [31:0] Q
);
    // behavior omitted
endmodule
