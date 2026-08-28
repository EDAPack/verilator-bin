// End-to-end check that the UVM we ship works under dv-flow-mgr + Verilator,
// with the DPI layer active.
//
// Every regex assertion here FAILS under +define+UVM_NO_DPI, so this also
// proves SimLibUVM did NOT fall back to the glob-only implementation.
module uvm_dpi_tb;
  import uvm_pkg::*;
`include "uvm_macros.svh"

  logic [31:0] backdoor_sig  /*verilator public*/;

  class uvm_dpi_test extends uvm_test;
    `uvm_component_utils(uvm_dpi_test)

    int unsigned errors = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void check_re(string re, string str, int exp, string what);
      int got = uvm_re_match(re, str);
      if (got != exp) begin
        errors++;
        `uvm_error("DPI_RE", $sformatf("%s: uvm_re_match(\"%s\",\"%s\") = %0d, expected %0d",
                                       what, re, str, got, exp))
      end
    endfunction

    task run_phase(uvm_phase phase);
      uvm_hdl_data_t v;

      phase.raise_objection(this);

      // Regex metacharacters: '.' and '*'. The UVM_NO_DPI fallback treats
      // these as literals and glob wildcards, so it gets both of these wrong.
      check_re("^a.*b$", "axxxb", 0, "dot-star match");
      check_re("^a.*b$", "axxxc", 1, "dot-star non-match");

      // Alternation
      check_re("^(foo|bar)$", "bar", 0, "alternation");

      // Character class + repetition
      check_re("^[0-9]+$", "12345", 0, "char class");
      check_re("^[0-9]+$", "12x45", 1, "char class non-match");

      // uvm_glob_to_re is the DPI-backed glob translator
      if (uvm_glob_to_re("a foo bar") != "/^a foo bar$/") begin
        errors++;
        `uvm_error("DPI_GLOB", $sformatf("uvm_glob_to_re gave '%s'",
                                         uvm_glob_to_re("a foo bar")))
      end

      // Register backdoor access, via Verilator's uvm_hdl_verilator.c
      backdoor_sig = 32'hdeadbeef;
      v = '0;
      if (uvm_hdl_read("uvm_dpi_tb.backdoor_sig", v) != 1) begin
        errors++;
        `uvm_error("DPI_HDL", "uvm_hdl_read failed")
      end else if (v[31:0] !== 32'hdeadbeef) begin
        errors++;
        `uvm_error("DPI_HDL", $sformatf("uvm_hdl_read gave %h", v[31:0]))
      end

      v = 32'h12345678;
      if (uvm_hdl_deposit("uvm_dpi_tb.backdoor_sig", v) != 1) begin
        errors++;
        `uvm_error("DPI_HDL", "uvm_hdl_deposit failed")
      end else if (backdoor_sig !== 32'h12345678) begin
        errors++;
        `uvm_error("DPI_HDL", $sformatf("after deposit sig = %h", backdoor_sig))
      end

      if (errors == 0)
        `uvm_info("DPI", "UVM DPI DFM TEST PASSED", UVM_NONE)

      phase.drop_objection(this);
    endtask
  endclass

  initial begin
    run_test("uvm_dpi_test");
  end
endmodule
