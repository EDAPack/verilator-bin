# verilator-bin

Binary build of Verilator for various platforms. This build also includes an 
installation of the [Bitwuzla](https://github.com/bitwuzla/bitwuzla) SMT solver
to support constrained randomization, and a compatible version of the 
[UVM](https://www.accellera.org/downloads/standards/uvm) library.

## Release Scheme

Releases come from two automatic tracks.

**Release track** — when Verilator publishes a tag newer than the last one we
built, CI builds it from that tag. The version matches upstream exactly
(`5.050`, tagged `v5.050`), it is published as a full release, its notes are
Verilator's own release notes for that version, and it becomes `latest`.
Verilator tags roughly every 6–8 weeks.

**Snapshot track** — a weekly build of Verilator top-of-trunk, versioned
`<upstream in-development version>.<CI run id>` (e.g. `5.051.32639969514`) and
tagged `v5.051.32639969514`. These are marked pre-release and never become
`latest`. A build is published only when an input actually changed since the
previous snapshot.

The two tracks never both build in the same run: when a new upstream release is
available, the release track builds it and the snapshot stands down, since the
release covers the same code.

So `latest` always points at a build of a tagged Verilator release. Use
`latest` for stable work and a pre-release tag for top-of-trunk.

Both tracks build the same platform set and can be run by hand from the CI
workflow's *Run workflow* button, which takes a track selector.

## UVM

Accellera UVM **1800.2-2020.3.2** is installed under `share/uvm`, and its
`share/uvm/src/dpi` carries a **Verilator DPI backend** (`uvm_hdl_verilator.c`).
`share/uvm/src/dpi/VERILATOR_DPI_PROVENANCE.txt` records the UVM version, the
release hash and the one portability fix we apply (`<malloc.h>` is not guarded
for macOS upstream).

The backend matters because without it `uvm_dpi.cc` cannot compile under
Verilator, and UVM has to be built with `+define+UVM_NO_DPI` — which silently downgrades
`uvm_re_match` to glob-only matching (so `^a.*b$` stops matching `axxxb`,
affecting `uvm_config_db` scopes, factory overrides by name and `+uvm_set_*`),
disables the register backdoor, and leaves the command-line processor with no
arguments at all.

To use it, compile `uvm_dpi.cc` alongside your design and pass `--vpi`
(`$VLT_PREFIX` is the directory this package was unpacked into — the one
containing `bin/verilator`):

```bash
verilator --binary --vpi --timing -j 0 -o simv \
    +incdir+$VLT_PREFIX/share/uvm/src \
    $VLT_PREFIX/share/uvm/src/uvm_pkg.sv \
    $VLT_PREFIX/share/uvm/src/dpi/uvm_dpi.cc \
    my_tb.sv --top-module my_tb
```

`--top-module` is worth passing explicitly: with `uvm_pkg.sv` on the command
line Verilator otherwise has more than one top candidate and can pick the wrong
one, producing a binary that elaborates nothing and exits at time 0.

`--vpi` is mandatory, not optional: `uvm_svcmd_dpi.c` and `uvm_hdl_verilator.c`
are compiled into the same translation unit as the regex code and both call into
VPI. There is no regex-only build.

Backdoor access (`uvm_hdl_read`/`uvm_hdl_deposit`, `uvm_reg::peek`/`poke`) can
only reach signals Verilator has exposed to VPI. Mark them `/*verilator public*/`,
or build with `--public-flat-rw` — the latter inhibits optimization across the
whole design, so prefer marking the specific signals.

With [dv-flow-libhdlsim](https://github.com/dv-flow/dv-flow-libhdlsim), all of
this is automatic: `hdlsim.vlt.SimLibUVM` detects the backend and wires up the
DPI sources and `--vpi` itself. Its `dpi` parameter is `auto` by default; set it
to `true` to make a missing backend an error rather than a silent fallback, or
`false` to force `UVM_NO_DPI`.

## Testing
Each build automatically runs a smoke test to validate the installation. The test:
1. Compiles a simple SystemVerilog module (`tests/smoke.sv`) using `verilator --binary`
2. Runs the resulting simulation executable with a 5-second timeout
3. Verifies that "Hello World" is displayed in the output

You can manually run the smoke test after installing Verilator:
```bash
cd tests
./run_smoke_test.sh
```

Builds also run two UVM tests (skipped on MinGW/Cygwin, which lack POSIX
`<regex.h>`):

* `tests/uvm_dpi/` — raw `verilator` command line; checks the Verilator
  backend is installed and that regex matching and `uvm_hdl_*` work.
* `tests/uvm_dpi_dfm/` — the same capabilities through dv-flow-mgr, the way the
  package is actually consumed. One image, five `uvm_test`s selected with
  `+UVM_TESTNAME`: the DPI primitives, `uvm_config_db` regex scopes, factory
  instance overrides, the command-line processor, and register backdoor
  `peek`/`poke`. Every one of them fails under `UVM_NO_DPI`, so a silent
  fallback cannot pass. Set `VERILATOR_BIN_SKIP_DFM_TEST=1` to skip it (it
  provisions a venv from PyPI, so it needs network).

