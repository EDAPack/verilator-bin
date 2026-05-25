// Small SV module — clean enough to lint without warnings.
module counter #(parameter int W = 8) (
    input  logic         clk,
    input  logic         rst_n,
    output logic [W-1:0] q
);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= '0;
        else        q <= q + 1'b1;
endmodule
