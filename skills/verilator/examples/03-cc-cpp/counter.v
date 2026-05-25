module counter (
    input  wire       clk,
    input  wire       rst_n,
    output reg  [7:0] q
);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) q <= 8'd0;
        else        q <= q + 1'b1;
endmodule
