// End-to-end check that the UVM we ship works under dv-flow-mgr + Verilator,
// with the DPI layer active.
//
// One image, several uvm_tests, selected with +UVM_TESTNAME. Verilating UVM is
// the expensive part (~2.5 min in CI), so additional coverage is nearly free
// as long as it is another test class in this same file rather than another
// image.
//
// Every test here fails under +define+UVM_NO_DPI -- either because it uses a
// regex feature the glob fallback cannot express (a character class, '.', or
// alternation), or because it uses a DPI service the fallback does not provide
// at all (the command-line processor, the register backdoor). So passing also
// proves SimLibUVM did NOT quietly fall back.
module uvm_dpi_tb;
  import uvm_pkg::*;
`include "uvm_macros.svh"

  // Backdoor target. Verilator only exposes signals to VPI when they are
  // marked public, and SimLibUVM deliberately does not pass --public-flat-rw.
  logic [31:0] backdoor_sig  /*verilator public*/;

  //------------------------------------------------------------------
  // Common reporting: every test prints exactly one PASSED line, which
  // run_dfm_test.sh greps for per run task. Silence is a failure.
  //------------------------------------------------------------------
  virtual class dpi_test_base extends uvm_test;
    int unsigned errors = 0;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void chk(bit ok, string id, string msg);
      if (!ok) begin
        errors++;
        `uvm_error(id, msg)
      end
    endfunction

    function void report_phase(uvm_phase phase);
      if (errors == 0)
        `uvm_info("DPI", $sformatf("UVM DPI TEST PASSED: %s", get_type_name()), UVM_NONE)
    endfunction
  endclass

  //------------------------------------------------------------------
  // 1. The DPI primitives themselves: uvm_re_match, uvm_glob_to_re and
  //    uvm_hdl_read/deposit.
  //------------------------------------------------------------------
  class uvm_dpi_test extends dpi_test_base;
    `uvm_component_utils(uvm_dpi_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void check_re(string re, string str, int exp, string what);
      int got = uvm_re_match(re, str);
      chk(got == exp, "DPI_RE",
          $sformatf("%s: uvm_re_match(\"%s\",\"%s\") = %0d, expected %0d",
                    what, re, str, got, exp));
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
      chk(uvm_glob_to_re("a foo bar") == "/^a foo bar$/", "DPI_GLOB",
          $sformatf("uvm_glob_to_re gave '%s'", uvm_glob_to_re("a foo bar")));

      // Register backdoor access, via Verilator's uvm_hdl_verilator.c
      backdoor_sig = 32'hdeadbeef;
      v = '0;
      if (uvm_hdl_read("uvm_dpi_tb.backdoor_sig", v) != 1)
        chk(0, "DPI_HDL", "uvm_hdl_read failed");
      else
        chk(v[31:0] === 32'hdeadbeef, "DPI_HDL",
            $sformatf("uvm_hdl_read gave %h", v[31:0]));

      v = '0;
      v[31:0] = 32'h12345678;
      if (uvm_hdl_deposit("uvm_dpi_tb.backdoor_sig", v) != 1)
        chk(0, "DPI_HDL", "uvm_hdl_deposit failed");
      else
        chk(backdoor_sig === 32'h12345678, "DPI_HDL",
            $sformatf("after deposit sig = %h", backdoor_sig));

      phase.drop_objection(this);
    endtask
  endclass

  //------------------------------------------------------------------
  // 2. uvm_config_db scope matching. This is where a degraded uvm_re_match
  //    bites real users: a config set against a regex scope silently stops
  //    reaching its target.
  //------------------------------------------------------------------
  class uvm_cfgdb_test extends dpi_test_base;
    `uvm_component_utils(uvm_cfgdb_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      int v;

      phase.raise_objection(this);

      // A scope wrapped in '/' is handed to uvm_re_match as a regex rather
      // than being glob-translated. The character class is the part the glob
      // fallback cannot express.
      uvm_config_db #(int)::set(null, "/^top\\.env\\.[a-z]+_agent$/", "cfg_val", 42);

      v = 0;
      chk(uvm_config_db #(int)::get(null, "top.env.rx_agent", "cfg_val", v) && v == 42,
          "CFGDB", "regex scope did not match top.env.rx_agent");

      v = 0;
      chk(uvm_config_db #(int)::get(null, "top.env.tx_agent", "cfg_val", v) && v == 42,
          "CFGDB", "regex scope did not match top.env.tx_agent");

      // ...and must not over-match: 'driver' is not '[a-z]+_agent'.
      v = 0;
      chk(!uvm_config_db #(int)::get(null, "top.env.rx_driver", "cfg_val", v),
          "CFGDB", "regex scope wrongly matched top.env.rx_driver");

      phase.drop_objection(this);
    endtask
  endclass

  //------------------------------------------------------------------
  // 3. Factory instance overrides. The instance path is glob-translated and
  //    then regex-matched, so an override aimed at a set of instances lands
  //    on the wrong ones (or none) without real regex support.
  //------------------------------------------------------------------
  class base_drv extends uvm_component;
    `uvm_component_utils(base_drv)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class derived_drv extends base_drv;
    `uvm_component_utils(derived_drv)
    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction
  endclass

  class uvm_factory_test extends dpi_test_base;
    `uvm_component_utils(uvm_factory_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    function void build_phase(uvm_phase phase);
      uvm_factory f = uvm_coreservice_t::get().get_factory();
      uvm_component c;

      super.build_phase(phase);

      // '[rt]x_agent' matches rx_agent and tx_agent but not px_agent. The
      // path is wrapped in '/' so it is taken as a regex: uvm_glob_to_re
      // escapes '[' in an unwrapped glob, which would make the class literal.
      // The glob fallback has no character class either way, so under
      // UVM_NO_DPI this override matches nothing.
      f.set_inst_override_by_name("base_drv", "derived_drv",
                                  "/^uvm_test_top\\.env\\.[rt]x_agent\\.drv[0-9]*$/");

      c = f.create_component_by_name("base_drv", "uvm_test_top.env.rx_agent", "drv", this);
      chk(c != null && c.get_type_name() == "derived_drv", "FACTORY",
          $sformatf("rx_agent.drv is '%s', expected derived_drv",
                    (c == null) ? "<null>" : c.get_type_name()));

      c = f.create_component_by_name("base_drv", "uvm_test_top.env.tx_agent", "drv2", this);
      chk(c != null && c.get_type_name() == "derived_drv", "FACTORY",
          $sformatf("tx_agent.drv is '%s', expected derived_drv",
                    (c == null) ? "<null>" : c.get_type_name()));

      c = f.create_component_by_name("base_drv", "uvm_test_top.env.px_agent", "drv3", this);
      chk(c != null && c.get_type_name() == "base_drv", "FACTORY",
          $sformatf("px_agent.drv is '%s', expected base_drv (override must not match)",
                    (c == null) ? "<null>" : c.get_type_name()));
    endfunction
  endclass

  //------------------------------------------------------------------
  // 4. The command-line processor. uvm_cmdline_processor gets argv through
  //    uvm_dpi_get_next_arg (uvm_svcmd_dpi.c, which also needs VPI), so under
  //    UVM_NO_DPI it sees no arguments at all -- +uvm_set_* processing and
  //    every user plusarg lookup silently stop working.
  //------------------------------------------------------------------
  class uvm_cmdline_test extends dpi_test_base;
    `uvm_component_utils(uvm_cmdline_test)

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      uvm_cmdline_processor clp = uvm_cmdline_processor::get_inst();
      // NB: 'matches' is a SystemVerilog keyword -- do not name a variable that.
      string hits[$];
      string values[$];
      string all_args[$];

      phase.raise_objection(this);

      // Sanity: the DPI arg list is non-empty. Under UVM_NO_DPI it is empty.
      clp.get_args(all_args);
      chk(all_args.size() > 0, "CLP", "uvm_cmdline_processor saw no arguments");

      // get_arg_matches runs uvm_re_match over argv.
      void'(clp.get_arg_matches("/^\\+dpi_opt=/", hits));
      chk(hits.size() == 1, "CLP",
          $sformatf("get_arg_matches(+dpi_opt=) returned %0d entries, expected 1",
                    hits.size()));

      void'(clp.get_arg_values("+dpi_opt=", values));
      chk(values.size() == 1 && values[0] == "hello", "CLP",
          $sformatf("+dpi_opt value is '%s', expected 'hello'",
                    (values.size() == 0) ? "<none>" : values[0]));

      // The test itself only runs because +UVM_TESTNAME was read through the
      // same path, but assert it explicitly so a failure names the cause.
      values.delete();
      void'(clp.get_arg_values("+UVM_TESTNAME=", values));
      chk(values.size() == 1 && values[0] == "uvm_cmdline_test", "CLP",
          "+UVM_TESTNAME not visible through the command-line processor");

      phase.drop_objection(this);
    endtask
  endclass

  //------------------------------------------------------------------
  // 5. Register backdoor through the register model, rather than through raw
  //    uvm_hdl_* calls: uvm_reg::poke/peek reaching a Verilator signal via an
  //    HDL path. This is the layer users actually write against.
  //------------------------------------------------------------------
  class dpi_reg extends uvm_reg;
    `uvm_object_utils(dpi_reg)
    rand uvm_reg_field f;

    function new(string name = "dpi_reg");
      super.new(name, 32, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      f = uvm_reg_field::type_id::create("f");
      f.configure(this, 32, 0, "RW", 0, 32'h0, 1, 1, 1);
    endfunction
  endclass

  class dpi_reg_block extends uvm_reg_block;
    `uvm_object_utils(dpi_reg_block)
    rand dpi_reg r;

    function new(string name = "dpi_reg_block");
      super.new(name, UVM_NO_COVERAGE);
    endfunction

    virtual function void build();
      default_map = create_map("default_map", 0, 4, UVM_LITTLE_ENDIAN);
      r = dpi_reg::type_id::create("r");
      r.configure(this, null, "backdoor_sig");
      r.build();
      default_map.add_reg(r, 'h0, "RW");
      set_hdl_path_root("uvm_dpi_tb");
    endfunction
  endclass

  class uvm_reg_backdoor_test extends dpi_test_base;
    `uvm_component_utils(uvm_reg_backdoor_test)

    dpi_reg_block blk;

    function new(string name, uvm_component parent);
      super.new(name, parent);
    endfunction

    task run_phase(uvm_phase phase);
      uvm_status_e status;
      uvm_reg_data_t val;

      phase.raise_objection(this);

      blk = dpi_reg_block::type_id::create("blk");
      blk.build();
      blk.lock_model();

      backdoor_sig = 32'h0;
      blk.r.poke(status, 32'hcafebabe);
      chk(status == UVM_IS_OK, "REG_BKDR",
          $sformatf("poke status = %s", status.name()));
      chk(backdoor_sig === 32'hcafebabe, "REG_BKDR",
          $sformatf("after poke backdoor_sig = %h", backdoor_sig));

      backdoor_sig = 32'h5a5a5a5a;
      blk.r.peek(status, val);
      chk(status == UVM_IS_OK, "REG_BKDR",
          $sformatf("peek status = %s", status.name()));
      chk(val[31:0] === 32'h5a5a5a5a, "REG_BKDR",
          $sformatf("peek gave %h", val[31:0]));

      phase.drop_objection(this);
    endtask
  endclass

  initial begin
    run_test();
  end
endmodule
