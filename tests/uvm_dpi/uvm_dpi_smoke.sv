// Validates that the UVM DPI layer shipped in share/uvm actually works.
// Every regex here FAILS under +define+UVM_NO_DPI, which downgrades
// uvm_re_match to glob-only matching -- that is the regression this guards.
//
// (Note: a comment line starting with the word "verilator" is parsed as a
// lint pragma, so keep it out of column 1 of a comment.)
module t;
  import uvm_pkg::*;

  logic [31:0] sig  /*verilator public*/;

  initial begin
    int i;
    uvm_hdl_data_t v;

    // '.' and '*' as regex metacharacters -- the glob fallback cannot do this
    i = uvm_re_match("^a.*b$", "axxxb");
    if (i != 0) begin
      $display("%%Error: uvm_re_match('^a.*b$','axxxb') = %0d, expected 0", i);
      $finish;
    end

    // and it must not match when it shouldn't
    i = uvm_re_match("^a.*b$", "axxxc");
    if (i == 0) begin
      $display("%%Error: uvm_re_match('^a.*b$','axxxc') matched, expected no match");
      $finish;
    end

    // alternation
    i = uvm_re_match("^(foo|bar)$", "bar");
    if (i != 0) begin
      $display("%%Error: uvm_re_match('^(foo|bar)$','bar') = %0d, expected 0", i);
      $finish;
    end

    // character class + repetition
    i = uvm_re_match("^[0-9]+$", "12345");
    if (i != 0) begin
      $display("%%Error: uvm_re_match('^[0-9]+$','12345') = %0d, expected 0", i);
      $finish;
    end

    // uvm_glob_to_re round-trip
    if (uvm_glob_to_re("a foo bar") != "/^a foo bar$/") begin
      $display("%%Error: uvm_glob_to_re('a foo bar') = %s", uvm_glob_to_re("a foo bar"));
      $finish;
    end

    // Register backdoor access via uvm_hdl_verilator.c -- the Verilator VPI
    // backend that Accellera UVM does not ship.
    sig = 32'hdeadbeef;
    v   = '0;
    if (uvm_hdl_read("t.sig", v) != 1) begin
      $display("%%Error: uvm_hdl_read('t.sig') failed");
      $finish;
    end
    if (v[31:0] !== 32'hdeadbeef) begin
      $display("%%Error: uvm_hdl_read('t.sig') = %h, expected deadbeef", v[31:0]);
      $finish;
    end

    v = 32'h12345678;
    if (uvm_hdl_deposit("t.sig", v) != 1) begin
      $display("%%Error: uvm_hdl_deposit('t.sig') failed");
      $finish;
    end
    if (sig !== 32'h12345678) begin
      $display("%%Error: after deposit sig = %h, expected 12345678", sig);
      $finish;
    end

    $display("UVM DPI SMOKE PASSED");
    $finish;
  end
endmodule
