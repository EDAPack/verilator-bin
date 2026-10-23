# Verilator on Windows

verilator-bin publishes a Windows build, `windows-x86_64`, next to the Linux and
macOS ones. It is built with MSYS2's UCRT64 GCC toolchain and runs from cmd,
PowerShell, Git Bash, the MSYS2 shell and native Python.

Why it exists, the decisions behind it, and its build history are in
[design/windows.md](design/windows.md).

## What is different from the Linux/macOS builds

| | Windows | Linux/macOS |
|---|---|---|
| Architectures | x86_64 only | x86_64, aarch64 / arm64 |
| SMT solver (constrained `randomize()`) | **none bundled.** Verilator uses a solver found on `PATH` at run time | Bitwuzla bundled |
| Compiler for your models | **you install it** (MSYS2 UCRT64 GCC, below) | system compiler |
| Default C++ standard for models | `-std=gnu++17`, pinned (see below) | Verilator's configure default |
| UVM | shipped (`share/uvm`); the UVM DPI layer is not tested on Windows (mingw has no POSIX `<regex.h>`) | shipped and tested |
| In releases | `optional`: a Windows build failure never blocks a release, so an occasional release may lack the Windows asset | always |

`verilator_bin.exe` is statically linked and the release ships no DLLs. The
only runtime it needs is the Windows UCRT, which is part of Windows 10 and
later.

## Prerequisites (one-time, manual)

Verilator compiles each design to C++ and builds it with `make` and a C++
compiler, so a toolchain is needed on the machine. It is not bundled.

1. Install [MSYS2](https://www.msys2.org/) (default location `C:\msys64`).
2. In an MSYS2 shell, install the packages listed in
   [`scripts/msys2-runtime-packages.txt`](../scripts/msys2-runtime-packages.txt):

   ```sh
   pacman -S --needed make perl mingw-w64-ucrt-x86_64-gcc mingw-w64-ucrt-x86_64-python
   ```

   | Package | Used for |
   |---|---|
   | `mingw-w64-ucrt-x86_64-gcc` | compiling models |
   | `make` | running the generated makefiles (`--build`, `--binary`) |
   | `perl` | the `verilator` front-end script |
   | `mingw-w64-ucrt-x86_64-python` | `verilator_includer`, run by the generated makefiles |

Use **UCRT64** packages (`mingw-w64-ucrt-x86_64-*`), not MINGW64 ones. The
release is built against the UCRT C runtime.

## Getting the release

**With ivpm**, the same dependency as on Linux/macOS. ivpm picks the
`windows-x86_64` asset on Windows automatically:

```yaml
- name: verilator
  url: https://github.com/edapack/verilator-bin
  src: gh-rls
```

Leave `IVPM_CACHE` unset on Windows for now. ivpm's shared cache links packages
into a workspace with a symlink, and that needs symlink privilege (Developer
Mode) on Windows.

**By hand:** download `verilator-windows-x86_64-<version>.tar.gz` from the
[releases page](https://github.com/edapack/verilator-bin/releases) and extract it
with `tar -xzf` (Windows 10+ includes `tar`).

## Setting up `PATH`

Put these first on `PATH`, **in this order** (adjust `C:\msys64` and the
release location):

```
<release>\verilator\bin
C:\msys64\ucrt64\bin
C:\msys64\usr\bin
```

PowerShell, for the current session:

```powershell
$env:PATH = "C:\tools\verilator\bin;C:\msys64\ucrt64\bin;C:\msys64\usr\bin;$env:PATH"
verilator --version
```

* `ucrt64\bin` must come before `usr\bin` so that `gcc`/`g++` are the UCRT64
  ones.
* `usr\bin` puts MSYS2's Unix tools (`make`, `perl`, `sh`, but also `find`,
  `sort`) ahead of Windows' own tools of the same name. That is usual for an
  MSYS2 development shell. Scope it to the session or the project environment
  if it matters to you.
* **Python.** `ucrt64\bin` also contains MSYS2's `python`/`python3`, which shadow
  any other Python later on `PATH`. If you want models to use a different
  interpreter, set `PYTHON3` to it. The release's `verilated.mk` honours a
  `PYTHON3` environment variable (`PYTHON3 ?= python3`).

`bin\verilator.cmd` is what cmd, PowerShell and Python (`shutil.which`,
`subprocess`) find when they look for `verilator`. It runs the Perl front end
with MSYS2's `perl`. In Git Bash or the MSYS2 shell, the `verilator` script
runs directly.

## Check it works

From the verilator-bin checkout (or any small design):

```powershell
verilator --binary tests\smoke.sv -o simv
.\obj_dir\simv.exe        # prints "Hello World"
```

## Known issues

* **Models are pinned to `-std=gnu++17`.** MSYS2's GCC 16.2 defaults to
  gnu++20. At `-Os`, which `verilated.mk` uses for the Verilator runtime, that
  combination fails to link with `undefined reference to
  std::__cxx11::basic_string<…>::basic_string(basic_string&&)`. MSYS2's own
  verilator package hits the same failure. The release's `verilated.mk` sets
  `CFG_CXXFLAGS_STD = -std=gnu++17`. To pick a standard yourself, pass
  `-CFLAGS -std=…`, but gnu++20 will hit this bug until MSYS2's GCC fixes it.
* **No bundled solver.** Constrained randomization needs an SMT solver
  (Bitwuzla, Z3 or cvc5) on `PATH`. MSYS2 ships `mingw-w64-ucrt-x86_64-z3`.
* **Runtime VPI library loading** (`+verilator+vpi+…`) is not supported by
  upstream Verilator on Windows.
