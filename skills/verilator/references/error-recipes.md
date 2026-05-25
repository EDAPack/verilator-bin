# verilator failure recipes

## "cannot find file containing module: 'foo'"
Symptom:
```
%Error: design.v:10: Cannot find file containing module: 'foo'
```
Cause: `foo` is instantiated but its `.v`/`.sv` file wasn't on the
command line, and no `-y` library dir resolves the name.
Fix:
- Pass the file explicitly, or
- Add `-y <dir> +libext+.v +libext+.sv` for Verilog-style library
  search.

## `WIDTH` warning floods
Symptom: dozens of `%Warning-WIDTH:` lines.
Cause: missing width casts on literals or sign-extension differences.
Fix:
- Cast: `8'(x)` or `{{4{1'b0}}, x[3:0]}`.
- If the design is third-party and known good: `-Wno-WIDTH`
  (or `-Wno-fatal -Wall` to demote *all* warnings to non-fatal).

## "Internal Error" / segfault during elaboration
Symptom: stack trace or `%Error: Internal Error: ...`.
Cause: usually a verilator bug, often around `generate`, dynamic
arrays, or interfaces.
Fix: reduce to a minimal repro (`--xml-only` can help see what
verilator parsed) and file at
https://github.com/verilator/verilator/issues.

## UVM / class-based TB rejected
Symptom:
```
%Error-UNSUPPORTED: ... class is not yet supported
```
Cause: verilator's class support is improving but incomplete for full
UVM. Functional coverage classes are largely supported in 5.x.
Fix: split synthesizable RTL (drive with verilator) from UVM TB
(drive with `iverilog -g2012` or commercial). Or stub out the UVM
parts with `\`ifdef VERILATOR`.

## "delay specifier in non-timing build"
Symptom: `%Error-STMTDLY: Statement ... ignored without --timing`.
Cause: TB uses `#N`, `wait`, or `fork/join_any` and the build did not
enable timing.
Fix: add `--timing` (with a performance cost) or rewrite the TB to be
clock-edge driven.

## Wave file empty / not produced
Cause: `--trace` not on, or in `--cc` builds, the user `main.cpp`
forgot the tracing dance.
Fix (C++ main):
```cpp
Verilated::traceEverOn(true);
VerilatedVcdC* tfp = new VerilatedVcdC;
top->trace(tfp, 99);
tfp->open("trace.vcd");
... tfp->dump(time); ...
tfp->close();
```

## Coverage `coverage.dat` not produced
Cause: `--coverage` set at compile, but the runtime never called
`VerilatedCov::write("coverage.dat")` (in custom `main.cpp`).
Fix: in `--binary` mode this is automatic. In `--cc` mode, add:
```cpp
#if VM_COVERAGE
Verilated::mkdir("logs");
VerilatedCov::write("logs/coverage.dat");
#endif
```

## `g++: command not found` during `--build`
Cause: no host C++ toolchain.
Fix: install `g++` (Linux), Xcode CLT (macOS), MSYS2 + mingw-w64
(Windows). Verilator emits C++17; clang ≥ 10 / gcc ≥ 9.

## Performance disappointing
Causes (in order of impact):
- Default debug build. Add `--O3 -CFLAGS -O2 -CFLAGS -DNDEBUG`.
- Tracing on. Drop `--trace` for non-debug runs.
- Single-threaded. Try `--threads <N>`.
- Excessive `printf` from TB. Buffer or remove.
- 4-state X-handling. `--x-assign fast --x-initial fast`.
