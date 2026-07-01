// Toggle-FF divide-by-2 clock divider.
module clk_div2 (
    input  clk_in,
    input  rst_n,
    output clk_out
);
    reg q;
    always @(posedge clk_in or negedge rst_n) begin
        if (!rst_n) q <= 1'b0;
        else        q <= ~q;
    end
    assign clk_out = q;
endmodule
