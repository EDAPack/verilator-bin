// Constrained randomization through the bundled SMT solver (z3). The sum
// constraint needs the solver; Verilator's built-in sampler cannot meet it.
class Pkt;
  rand bit [7:0] a, b;
  constraint c_sum { a + b == 8'd100; a > 8'd10; b > 8'd10; }
endclass

module rand_top;
  initial begin
    Pkt p = new;
    bit [7:0] s;
    repeat (5) begin
      if (p.randomize() != 1) $fatal(1, "randomize() failed");
      s = p.a + p.b;
      if (s != 8'd100 || p.a <= 8'd10 || p.b <= 8'd10)
        $fatal(1, "constraint violated: a=%0d b=%0d", p.a, p.b);
      $display("a=%0d b=%0d", p.a, p.b);
    end
    $display("SOLVER TEST PASSED");
    $finish;
  end
endmodule
