# verilator CLI cheatsheet

## Invocation shape
```
verilator [flags] <sources> [-- <verilator-runtime-args>]
```
Sources are positional: `.v`/`.sv`/`.vh`/`.cpp` files in any order, or
`-f <list>` files.

## Build-mode selectors (pick exactly one)
| Flag | Output |
|---|---|
| `--binary` | Standalone executable from a self-checking SV testbench. |
| `--cc` | C++ class `V<top>.{h,cpp}` for use by a user `main.cpp`. |
| `--sc` | SystemC `sc_module` for SystemC environments. |
| `--lint-only` | No build; just elaboration + warnings. |
| `--xml-only` | Dump the AST as XML; no build. |
| `--E` | Run preprocessor only, print to stdout. |

## Common build modifiers
| Flag | Purpose |
|---|---|
| `--exe <main.cpp>` | Add `main.cpp` (or `.cc`) to the build list. |
| `--build` / `--build-dep-bin` | Run `make` (or compile dependency manager). |
| `-j <N>` | Parallel jobs. `-j 0` = autodetect. |
| `--Mdir <dir>` | Place generated files at `<dir>` (default `obj_dir`). |
| `--top-module <name>` | Pick top when ambiguous. |
| `--prefix <name>` | Rename the generated class (default `V<top>`). |
| `--MMD` | Emit `.d` Make dependency files. |
| `--cflags '<opt>'` | Extra C++ flags. Repeatable. |
| `--ldflags '<opt>'` | Linker flags. |
| `--make <gmake\|cmake>` | Pick the generated build system. |

## Source-file directives
| Flag | Purpose |
|---|---|
| `-DNAME[=val]` / `+define+NAME=val` | Verilog `define`. |
| `+incdir+<dir>` / `-I<dir>` | `\`include` search path. |
| `-y <dir>` | Library directory (`module_name.v` lookup). |
| `+libext+.v` / `+libext+.sv` | Extensions for library lookup. |
| `--sv` | Treat all `.v` files as SV. |
| `--language <1364-2005|1800-2017>` | Force a language standard. |
| `-f <file>` | Argument file (one flag/path per line). |
| `-F <file>` | Same, but paths in the file are relative to the file. |

## Trace & profile
| Flag | Purpose |
|---|---|
| `--trace` | Enable VCD tracing. |
| `--trace-fst` | Enable FST tracing (smaller, requires `--trace-threads`). |
| `--trace-depth <N>` | Cap trace depth. |
| `--trace-max-array <N>` / `--trace-max-width <N>` | Cap arrays / wide signals. |
| `--prof-exec` | Scheduler exec profile (feed to verilator_gantt). |
| `--prof-cfuncs` | gprof-friendly C profile. |
| `--prof-pgo` | Two-pass PGO build. |

## Coverage
| Flag | Purpose |
|---|---|
| `--coverage` | Enable line + toggle + functional. |
| `--coverage-line` / `--coverage-toggle` / `--coverage-user` | Subset. |
| `--coverage-underscore` | Cover signals beginning with `_`. |

## Warnings
- `-Wall` — recommended baseline.
- `-Wno-<name>` — demote one warning.
- `-Werror-<name>` — promote a warning to a fatal error.
- `-Wpedantic` — be strict about every implicit conversion.
- `-Wfuture-<name>` — gate behavior planned for a future release.

Common warnings worth knowing: `WIDTH` (width mismatch), `UNUSED`
(declared but unread), `UNDRIVEN`, `BLKANDNBLK` (`always` style mix),
`SYNCASYNCNET`, `MULTIDRIVEN`, `IMPLICIT` (implicit wire), `STMTDLY`
(delay in non-`--timing` build).

## Runtime args (after `--`)
Some args are consumed by `verilator` and some are passed to the
emitted simulator. After a `--` separator, pass to the executable:
```
./obj_dir/Vtop +verilator+seed+12345
```
- `+verilator+seed+N` — seed random init.
- `+verilator+rand+reset+N` — `0`/`1`/`2` for X-randomization mode.
