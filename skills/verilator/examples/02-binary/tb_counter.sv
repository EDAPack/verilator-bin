// Self-checking SV testbench for an 8-bit counter.  Drives clk + rst_n
// and asserts that q rolls over correctly.  `--binary` produces an
// executable with a built-in main().
module tb_counter;
    logic clk   = 0;
    logic rst_n = 0;
    logic [7:0] q;

    counter #(.W(8)) dut (.clk(clk), .rst_n(rst_n), .q(q));

    always #5 clk = ~clk;

    initial begin
        // 2 cycles of reset
        repeat (2) @(posedge clk);
        rst_n <= 1;
        // 257 cycles → counter must wrap to 1
        repeat (257) @(posedge clk);
        if (q !== 8'd1)
            $fatal(1, "counter wrap failed: q=%0d (expected 1)", q);
        $display("PASS: counter wrapped at 256 cycles");
        $finish;
    end
endmodule

module counter #(parameter int W = 8) (
    input  logic         clk,
    input  logic         rst_n,
    output logic [W-1:0] q
);
    always_ff @(posedge clk or negedge rst_n)
        if (!rst_n) q <= '0;
        else        q <= q + 1'b1;
endmodule
