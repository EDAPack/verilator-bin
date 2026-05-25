# verilator documentation index

## Primary
- **Project site** — https://verilator.org/
- **Online manual** — https://verilator.org/guide/latest/
- **Source repo** — https://github.com/verilator/verilator
- **CHANGES** — https://github.com/verilator/verilator/blob/master/Changes
  (read when bumping versions; flag renames are common).

## Topic-specific
- **Connecting to C++** —
  https://verilator.org/guide/latest/connecting.html (the canonical
  `--cc` example).
- **Tracing (VCD/FST)** —
  https://verilator.org/guide/latest/exe_verilator.html#tracing
- **Coverage workflow** —
  https://verilator.org/guide/latest/exe_verilator_coverage.html
- **Performance tuning / threading** —
  https://verilator.org/guide/latest/performance.html
- **Warnings reference** —
  https://verilator.org/guide/latest/warnings.html (one entry per
  `-Wfoo`).
- **Supported SV subset** —
  https://verilator.org/guide/latest/languages.html

## Worked examples
- **Verilator `examples/`** —
  https://github.com/verilator/verilator/tree/master/examples
  (covers --binary, --cc, tracing, coverage, threading, DPI).
- **CV32E40P / CORE-V CPU regression** — Verilator is the primary
  simulator. https://github.com/openhwgroup/cv32e40p
- **ibex (lowRISC)** — https://github.com/lowRISC/ibex (Meson +
  Verilator + cocotb).
- **Chipyard / FireSim** — large-design Verilator use at scale.

## In-tool help
```
verilator --help            # all flags
verilator --help-warnings   # warning catalog
verilator_coverage --help
verilator_gantt --help
```
