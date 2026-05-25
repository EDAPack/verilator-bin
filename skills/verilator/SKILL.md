---
name: verilator
description: Cycle-accurate Verilog/SystemVerilog simulator that compiles RTL into a C++ (or SystemC) model and links it with a user-written testbench harness. Also a strict linter for synthesizable RTL and the de-facto open-source SV simulator for performance-critical regression. Ships alongside verilator_coverage and verilator_gantt.
license: LGPL-3.0-or-later / Artistic-2.0
version: "5.038"
---

# verilator — Agent Skill

## When to use this skill
- The user wants **fast simulation** of Verilog/SystemVerilog (large
  designs, cycle-accurate, no commercial-tool license required).
- The user says "lint" against synthesizable RTL — `verilator
  --lint-only` is the open-source go-to.
- A CPU/SoC testbench is driven from C++ (or DPI-C from SV) — verilator
  is the fastest path.
- The user mentions "coverage merge" → `verilator_coverage`.
- The user wants a profiled flame-graph-like view of the simulation
  scheduler → `verilator_gantt`.

Do **not** use verilator for:
- Behavioral SV (delays in non-`#1step` time, race-sensitive `initial`
  blocks, `forever` without sensitivity) — use `iverilog` + `vvp`.
- Synthesis — that's `yosys`. Verilator is a *simulator*; its output is
  a C++ model, not a netlist.
- Mixed-language VHDL — not supported.

## Core mental model
Verilator is a **compiler**, not an interpreter. The flow is:

```
   .v / .sv  ──verilator──►  obj_dir/Vtop.{h,cpp}  ──make──►  obj_dir/Vtop  (executable)
                                                  │
                                                  │  (or .a / .so + user main.cpp)
                                                  │
                                                  ▼
                                              ./obj_dir/Vtop
```

You always pick **one of three output modes**:

| Mode | Flag | Use when |
|---|---|---|
| Binary | `--binary` | You have a self-checking `initial` block in SV that drives the design — verilator builds a runnable executable with a built-in `main()`. Simplest. |
| C++ model | `--cc` | You want to write your own `main.cpp` in C++ that instantiates `Vtop` and clocks it. Most flexible; the canonical way. |
| SystemC model | `--sc` | You're integrating with a SystemC TLM environment. |

Critical invariants:
1. Verilator only fully simulates the **synthesizable subset** plus
   selected SV features. Don't expect it to run pure-behavioral testbenches.
2. Verilator is **2-state by default**. `X`/`Z` propagate as `0`. Use
   `--x-assign unique` / `--x-initial unique` to force corner-case
   coverage, or expect different behavior from a 4-state simulator.
3. The compiled model uses **eval-driven** scheduling — testbench
   advances by calling `top->eval()` after each `top->clk = 0/1; ` flip.
4. Output goes to `obj_dir/` by default; clean it between runs that
   change Verilog defines.

## Quick start
```sh
# Self-checking SV testbench → standalone executable.
verilator --binary -j 0 -Wall tb_top.sv
./obj_dir/Vtb_top

# C++ harness around a DUT.
verilator --cc --exe --build -j 0 dut.v sim_main.cpp --top-module dut
./obj_dir/Vdut
```

## Common tasks
- **Lint only (no simulate) →** `verilator --lint-only -Wall design.v`
- **Strict lint (warnings as errors) →** `verilator --lint-only -Wall -Wpedantic -Werror-IMPLICIT design.v`
- **SystemVerilog file mix →** `verilator --binary --sv -j 0 top.sv`
  (verilator auto-detects `.sv`; `--sv` forces SV parsing on `.v`).
- **Add a define →** `-DFOO=1` or `+define+FOO=1`.
- **Add an include dir →** `+incdir+<path>` (or `-I<path>`).
- **File list →** `-f files.f` (one file or flag per line).
- **VCD waves from the binary →** `verilator --binary --trace tb.sv` then
  run; trace lands at `obj_dir/<top>.vcd`.
- **FST waves (smaller) →** `--trace-fst` instead.
- **Compile with optimization →** `-O3 --x-assign fast --x-initial fast`.
- **Coverage →** `--coverage` at compile; run; then
  `verilator_coverage --annotate logs annotated obj_dir/coverage.dat`.
- **Profile scheduler →** `--prof-exec` at compile; run produces
  `obj_dir/profile_exec.dat`; render with `verilator_gantt`.
- **Run faster with multithread →** `--threads <N>` (also requires
  multithreaded testbench — see manual).

## Flags you actually need
| Flag | Effect | When |
|---|---|---|
| `--binary` | Build a runnable executable, no user `main()` needed. | Self-checking SV TB. |
| `--cc` / `--sc` | Emit C++ / SystemC model (no main). | Custom C++ harness. |
| `--exe <main.cpp>` | Add `main.cpp` to the build list. | With `--cc`. |
| `--build` | Run `make` after generating sources. | One-shot builds. |
| `-j <N>` | Parallel compile (`-j 0` = nproc). | All real builds. |
| `--top-module <name>` | Set top. Required when multiple top candidates exist. | Most non-trivial RTL. |
| `--Mdir <dir>` | Override `obj_dir`. | Multiple variants side by side. |
| `--trace` / `--trace-fst` | Enable VCD / FST tracing. | Debugging. |
| `--trace-depth <N>` | Limit trace depth (perf). | Big designs. |
| `-Wall` | Enable all standard warnings. | Always. |
| `-Wno-<warn>` / `-Wno-fatal` | Demote a specific warning. | When known false-positive. |
| `-Werror-<warn>` | Promote a warning to error. | CI. |
| `--lint-only` | Skip building; lint only. | Linting. |
| `--sv` | Treat `.v` files as SystemVerilog. | Mixed legacy designs. |
| `-DNAME[=val]` / `+define+NAME=val` | Verilog define. | Conditional RTL. |
| `+incdir+<dir>` | Include search path. | `\`include` resolution. |
| `-f <file>` | Read file list. | Large builds. |
| `--coverage` / `--coverage-line` / `--coverage-toggle` | Enable coverage classes. | Coverage regressions. |
| `--prof-exec` | Scheduler exec profile. | Profiling. |
| `--prof-cfuncs` | C-function profile (gprof). | Profiling. |
| `--threads <N>` | Multithreaded simulation. | Big DUTs. |
| `--x-assign <0\|1\|fast\|unique>` | How to treat `X` on assignments. | Coverage / determinism. |
| `--x-initial <0\|1\|fast\|unique>` | Initial register value. | Same. |
| `--public-flat-rw` | Expose all signals to C++. | Debug only. |
| `--timing` | Enable SV timing controls (`#delay`, `wait`, fork/join) — slower. | Pure-RTL TBs that use delays. |

## verilator_coverage (essentials)
```sh
verilator_coverage \
    --annotate ./annotated \
    --annotate-min 1 \
    obj_dir/coverage.dat            # one run
verilator_coverage --write merged.dat run1.dat run2.dat   # merge
verilator_coverage --rank obj_dir/coverage.dat            # rank tests by new coverage
```

Output: `annotated/<file>.v` with per-line `+`/`-`/`%` markers — feed
to humans or a coverage dashboard.

## verilator_gantt (essentials)
```sh
# After running a --prof-exec build, render gantt + flame-graph.
verilator_gantt obj_dir/profile_exec.dat
# Produces gantt.vcd (open in GTKWave) and a text summary on stdout.
```

## Failure recipes
| Symptom | Likely cause | Fix |
|---|---|---|
| `%Error: ... cannot find file containing module: 'foo'` | File or library path missing. | Add `-y <dir>` library path or pass the file explicitly. |
| `%Warning-WIDTH: ... operator BITAND expects ...` | Width mismatch (sign-extension, literal width). | Add a width cast `WIDTH'(x)` or fix the literal. Demote with `-Wno-WIDTH` only if intentional. |
| `%Error: Internal Error: ...` | Hit a verilator bug. | Reduce to minimal repro; file at https://github.com/verilator/verilator/issues. |
| `%Error: Define or directive not defined: \`UVM_*` | Trying to compile UVM. | Verilator's UVM support is partial; consider `iverilog -g2012` or commercial. |
| `make: g++: command not found` (during `--build`) | No C++ toolchain on PATH. | Install `g++`/`clang++`; verilator emits C++17. |
| Simulation hangs | TB never advances clock or never asserts a `$finish`. | Drive the clock; add `$finish` on done; or `--timeout`. |
| Wave file is empty | Forgot to call `top->trace(...)` and `tfp->dump(time)` in C++ main, or didn't `--trace`. | Re-build with `--trace`; in C++ main call `Verilated::traceEverOn(true); top->trace(tfp, 99);`. |

## Interop with edapack
- **Upstream**: nothing in this repo *generates* RTL for verilator.
  Hand-written or external SV/V.
- **Downstream**: VCD/FST traces → GTKWave (not in edapack). Coverage
  → external dashboards.
- **Alternative simulator**: `iverilog` (sibling package) — slower but
  handles full behavioral SV, including pure-event testbenches and
  more 4-state semantics.

## References
See `references/docs-index.md` and `references/cli-cheatsheet.md`.

## Examples
- `examples/01-lint/` — lint-only smoke check.
- `examples/02-binary/` — `--binary` SV self-checking testbench.
- `examples/03-cc-cpp/` — `--cc` plus a hand-written C++ main driving
  the clock.
