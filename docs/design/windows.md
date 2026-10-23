# Design: Windows Verilator for pyhdl-if CI

Status: **reviewed — decisions recorded in §8; ready to prototype**
Date: 2026-10-23
Scope: `verilator-bin` (recipe A), `edapack-common` build pipeline (one new
target kind), and the consumers — `pyhdl-if`, `dv-flow-libhdlsim` (recipe B)

## 1. Goal and non-goals

**Goal.** Run pyhdl-if's Verilator tests (`tests/unit`, `PYTEST_FV_HDLSIM=vlt`)
on a GitHub `windows-latest` runner, against a Verilator that we build and
release ourselves.

That needs two recipes:

* **Recipe A — build and release.** verilator-bin produces a
  `verilator-windows-x86_64-<ver>.tar.gz` asset on the same releases as the
  Linux/macOS ones, through the shared edapack pipeline.
* **Recipe B — test environment.** A repeatable way (CI first, then a desktop)
  to get from a clean Windows machine to `pytest tests/unit` passing in
  pyhdl-if with that Verilator.

**Non-goals.**

* Windows across EDAPack. Nothing here commits other `*-bin` packages to
  Windows. The one pipeline change (§4.2) is generic only because a
  verilator-specific one would cost the same.
* A self-contained Windows install. Verilator compiles generated C++ at user
  sites, so it needs a GCC toolchain, `make` and `perl` regardless. We accept
  "install MSYS2 first" as a documented manual prerequisite.
* MSVC, Cygwin, 32-bit. Upstream Verilator's own Windows CI is MSVC/CMake
  (`ci/ci-win-compile.ps1`) with no solver support, and it only builds an
  example — it does not run one (upstream #5163). We stay on MSYS2/GCC, which is
  what worked for us before (§2.1).

## 2. What we have today

### 2.1 A MinGW build existed, shipped, and was turned off

From the git history (merge `1291bf2`, 2026-01-03):

* A legacy-workflow job on `windows-latest` used `msys2/setup-msys2@v2` with a
  `MINGW64` + `MINGW32` matrix, `shell: msys2 {0}`, and ran `scripts/build.sh`.
  It is still there, commented out, in `.github/workflows-legacy/ci.yml:213-288`.
* Problems that were solved, and whose fixes are **still in the tree**:
  * GMP's configure fails on MinGW, so MSYS2's `gmp`/`mpfr` packages are used
    (`CMakeLists.txt:97-106,138-147`).
  * `FlexLexer.h` is not on MinGW gcc's include path, so it gets symlinked into
    `/mingw64/include` (done in the workflow, not the recipe).
  * The `PATH` split on the drive-letter colon (`c40ffa0`), and Verilator could
    not find `verilated_std.sv` until an `include ->
    share/verilator/include` symlink was added (`ff201ea`,
    `CMakeLists.txt:351`).
  * `scripts/build.sh:54-62,87-100` maps `MINGW*` to `IS_WINDOWS` and copies the
    runtime DLLs (`libgcc_s`, `libstdc++`, `libwinpthread`, `libgmp`, `libmpfr`)
    into `bin/`.
* **It was smoke-tested and released.** On Windows the build runs
  `tests/run_smoke_test.sh` (`verilator --binary`, run `simv.exe`, check
  "Hello World"). `verilator-mingw{64,32}-*.tar.gz` shipped on every release
  from `v5.045.20679523434` (2026-01-03) to `v5.047.23403476108` (2026-03-22).
* **What broke was MINGW32.** From 2026-03-29 the i686 job failed in `build`.
  MINGW64 was cancelled with it, and `publish` was skipped. `6e9676b`
  (`-fno-lto` for the pip-built ninja) did not fix it, and `9f88b1e`
  (2026-05-17) commented the job out to get releases moving again. The logs
  have expired, so the root cause is unknown. There is no record of MINGW64
  itself failing.
* `WINDOWS_BUILD_SUMMARY.md` ("Production Ready") is stale. §7 retires it.

### 2.2 The shared pipeline has no Windows path

`edapack-common/.github/workflows/build-release.yml` reads only `kind` and
`runs-on` from each `targets` entry:

* `kind: docker` (`:459-481`) runs `bash /src/scripts/build.sh` in an image.
* `kind: native` (`:490-522`) is macOS in practice: it uses brew flex/bison and
  `brew --prefix`. On `windows-latest` it would get Git-Bash and fail.
* `ec_platform_json` (`scripts/build-common.sh:225-248`) builds the manifest's
  platform block from `uname`. Under MSYS2 that reports
  `os = mingw64_nt-10.0-…`.
* Publish uploads only `*.tar.gz` and `*.sha256` (`:597-606`). That suits us; a
  tarball is the right format here.

Prior art elsewhere: `iverilog-bin` has a bespoke msys2 job outside the shared
pipeline (`ci.yml:104-128`). yosys-bin and icestorm-bin list Windows as a
tracked follow-up.

### 2.3 ivpm will select a Windows asset only if it is named for it

In `ivpm/src/ivpm/pkg_types/package_gh_rls.py`:

* `_select_windows_asset` (`:940-954`) matches `windows`, `win64`, `win32` or
  `win`, and prefers `x86_64`/`amd64`.
* **`mingw64` does not match.** The old asset names would be invisible to ivpm.
* The platform comes from `platform.system()`, which is `Windows` for
  python.org and MINGW Python. MSYS-runtime Python reports `msys_nt-…` and is
  rejected.
* Known rough edges on Windows:
  * The package cache uses `os.symlink` with no copy fallback (`cache.py:270`),
    which fails without Developer Mode.
  * The bare `win` key also matches `darwin`. That is harmless with our
    `macos-arm64` naming.

### 2.4 pyhdl-if and dv-flow-libhdlsim do not run on Windows

**This is the larger part of the work.** Verilator is the easy half.

**pyhdl-if** (`~/projects/fvutils/pyhdl-if`):

* `setup.py:49-51` slices `sysconfig LDLIBRARY`, which is `None` on Windows
  Python. The build crashes, and the value is unused.
* `src/entry.c` (the DPI/VPI bridge DLL) has a Windows branch that is a stub:
  * It calls `dlopen`/`dlsym`, includes `<unistd.h>`, and its
    `find_loaded_python_lib` returns -1.
  * The Python discovery path is Linux-only: `posix_spawn` of
    `python -m sysconfig`, `/proc/<pid>/maps`, `.so` matching, and `:` and `/`
    as separators.
* **Link model.** `entry.c:75-89` references DPI-exported symbols that live in
  the simulator executable. A PE DLL cannot have unresolved symbols, so these
  must be looked up at run time with
  `GetProcAddress(GetModuleHandle(NULL), …)`. The executable must export them
  (`-Wl,--export-all-symbols`).
* The Python side uses `ctypes.cdll.LoadLibrary(None)` to reach the executable's
  symbols (`impl/dpi/hdl_services_dpi.py:33`,
  `impl/call/hdl_call_endpoint_dpi.py:33`). That raises on Windows, so it needs
  `ctypes.CDLL(None, handle=GetModuleHandleW(None))` or equivalent.
* **Good news:** libpython is never linked at build time. `entry.c` loads it at
  run time by path (via `PYHDL_IF_PYTHON`/`LIBPYTHON_LOC`) and resolves the API
  through a generated function-pointer table. Its compiler ABI is therefore
  irrelevant at link time, and a GCC-built `simv.exe` can drive a python.org
  (MSVC) `python3XY.dll`.

**dv-flow-libhdlsim** (`hdlsim.vlt.*`):

* `shutil.which('verilator')` cannot find an extensionless Perl script on
  Windows.
* `create_subprocess_exec('verilator', …)` cannot execute one.
* It runs `make` on the generated `.mk`, which needs MSYS2 `make`/`sh`.
* `obj_dir/simv` is hard-coded (`vlt_sim_image.py:57-60,284`,
  `vlt_sim_run.py:44`); MinGW produces `simv.exe`.
* `-Wl,-rpath` (`:147,240`) has no PE meaning. DLL directories must be on
  `PATH` at run time instead.
* `-Wl,--export-dynamic` (`:245`) is ELF-only. The Windows equivalent is
  `-Wl,--export-all-symbols`.

## 3. Key decisions

| # | Decision | Recommendation | Why |
|---|---|---|---|
| D1 | Toolchain | MSYS2 GCC | Worked before; no MSVC port of our recipe |
| D2 | MSYS2 environment | **UCRT64** *(agreed)* | python.org CPython uses the UCRT. A UCRT64 `simv.exe` then shares one C runtime with `python3XY.dll`, so `FILE*` and heap objects can cross safely. MINGW64 uses `msvcrt.dll`, which mixes two CRTs in one process. UCRT64 is MSYS2's recommended default; MINGW64 (`msvcrt`) is legacy. |
| D3 | Architectures | x86_64 only | i686 is what broke (§2.1); nothing needs it |
| D4 | Asset name | `verilator-windows-x86_64-<ver>.tar.gz` | ivpm matches it (§2.3) |
| D5 | Test Python | python.org CPython (`actions/setup-python`), **newest release only (3.14)** *(agreed)* | pip wheels exist for cp39–cp314; it is what `PYHDL_IF_PYTHON=sys.executable` points at. MSYS2's Python lacks wheels for many dependencies. |
| D6 | Runtime toolchain | User-installed MSYS2 UCRT64 (`gcc`, `make`, `perl`) | Needed anyway to compile models; a documented manual step |
| D7 | Pipeline integration | New `kind: msys2` target in edapack-common | Assets land on the same release and manifest as the other platforms, under the same change gate. A bespoke job (the iverilog-bin pattern) would need its own publish path and would lose both. |

Added after review:

| # | Decision | Agreed |
|---|---|---|
| D8 | Can Windows block a release? | **No.** The Windows target is `optional` from day one (§4.4) |
| D9 | Bitwuzla on Windows | **Dropped.** Windows builds Verilator with no bundled solver (§4.1 item 9) |
| D10 | Home of the CI setup action | **verilator-bin** (§5.2) |

If UCRT64 throws up a build problem that MINGW64 did not have, MINGW64 stays the
fallback, provided `entry.c` passes no CRT objects across the boundary. The
generated Python-API table would then need checking for `FILE*` functions such
as `PyRun_*File`.

## 4. Recipe A — build and release Verilator for Windows

### 4.1 verilator-bin changes

1. **Target entry**, added to both the `release` and `dev` track `targets` in
   `.github/workflows/ci.yml`:
   ```json
   {"name":"windows-x86_64","runs-on":"windows-latest","kind":"msys2","msystem":"UCRT64"}
   ```
   `EC_IMAGE_NAME` already overrides `plat` in `scripts/build.sh:53`, so the
   tarball comes out as `verilator-windows-x86_64-<ver>.tar.gz` (D4).
2. **Move workflow-only provisioning into the recipe**, so the shared step stays
   generic. `scripts/build.sh` gains a Windows block that:
   * creates the `FlexLexer.h` link into `$MINGW_PREFIX/include`;
   * checks the required pacman packages are present (and fails clearly if not)
     rather than installing them.
   The package list itself lives in `scripts/msys2-packages.txt`, which is read by
   both CI (§4.2) and the manual setup doc:
   `base-devel git flex bison autoconf automake help2man tar` plus
   `mingw-w64-ucrt-x86_64-{toolchain,cmake,python}`.
3. **No meson/ninja on Windows.** They were only needed to build Bitwuzla, which
   is dropped (item 9). This also removes the pip-built ninja and its
   LTO/`mkdtemp` failure mode (`6e9676b`).
4. **Port the `-std=gnu++17` fix** from the Unix verilator branch
   (`CMakeLists.txt:249-276`) to the MinGW branch, which never got it.
5. **Static-link the C++ runtime into `verilator_bin(.exe)`**
   (`-static-libgcc -static-libstdc++`, plus static winpthread). Then
   *stop copying `libstdc++-6.dll` / `libgcc_s` / `libwinpthread` into `bin/`.*
   * **Why:** with `verilator/bin` on `PATH`, a user's freshly compiled
     `simv.exe` would load our bundled, possibly older `libstdc++-6.dll` instead
     of their MSYS2 one, and fail with "entry point not found".
   * With no solver (item 9), nothing else needs bundling: `bin/` carries no
     DLLs at all.
6. **`verilator.cmd` shim in `bin/`**: `@perl "%~dp0verilator" %*`. This
   makes `verilator` findable by `shutil.which` (it appears in `PATHEXT`) and
   runnable from cmd, PowerShell and native Python without changing the Perl
   script. It needs MSYS2's `perl` on `PATH`, which D6 already requires.
7. **Symlinks in the tarball.** `include -> share/verilator/include` must
   survive extraction on machines without symlink privilege. Either make it a
   copy on Windows or verify that `tar` and ivpm's extractor dereference it.
   Copying is simpler.
8. **Smoke test** (`tests/run_smoke_test.sh`) is unchanged; it already handles
   `.exe`. Add a second check that runs `verilator --version` through
   `verilator.cmd` from `pwsh`, so the native-Python invocation path is covered
   at build time.
9. **No Bitwuzla on Windows (D9).** pyhdl-if's tests do not need constraint
   solving, and this removes the largest dependency from the Windows build.
   * Under `IS_WINDOWS`, `CMakeLists.txt` skips the `gmp`, `mpfr` and `bitwuzla`
     ExternalProjects and configures Verilator without `--with-solver=bitwuzla`.
   * gmp/mpfr drop out of the pacman list and the DLL bundle.
   * Verilator then falls back to whatever SMT solver is on `PATH` at run time,
     which is the standard upstream behaviour. `randomize()` with constraints
     needs the user to supply one; no pyhdl-if test exercises that.

### 4.2 edapack-common: `kind: msys2`

In `build-release.yml`:

* Gate the existing `native` steps to `runner.os == 'macOS'`.
* Add steps under `if: matrix.target.kind == 'msys2'`:
  * `msys2/setup-msys2@v2` with `msystem: ${{ matrix.target.msystem || 'UCRT64' }}`,
    `update: false`, and `install:` from the package's
    `scripts/msys2-packages.txt` (read in a prior step). 
  * A `shell: msys2 {0}` step that exports the standard `EC_*`, `SRC_DIR`,
    `WORK_DIR` and `OUT_DIR` env, with paths converted by `cygpath -u`, then
    runs `bash scripts/build.sh`.
* Make the `ivpm update` step tolerate Windows, or skip it for `msys2`. It is
  only there for the package's own build deps, and verilator-bin's Windows build
  needs none of them.
* `ec_platform_json`: map `MINGW*|MSYS*|UCRT*` to `os: windows`, `libc: ""`
  (or `ucrt`), `arch` from `uname -m`.
* Schema/docs: list `msys2` and the optional `msystem` field.

This is the only cross-repo change in recipe A. It ships behind the `@v1`
alias, which moves forward on edapack-common `main` (see the release-path
header in `ci.yml`). It should be tested from a branch ref
(`@<branch>` in a verilator-bin feature branch) before `v1` is retargeted.

### 4.3 What a release contains, and what a user must already have

```
verilator/
  bin/      verilator (perl), verilator.cmd, verilator_bin.exe,
            verilator_bin_dbg.exe, verilator_* helper scripts
            (no runtime DLLs: C++ runtime static, no solver)
  include -> copy of share/verilator/include
  share/verilator/...   share/uvm/...
```

The user must already have MSYS2 with the UCRT64 toolchain, `make` and `perl`
installed (§5.3). That is documented, not automated.

### 4.4 CI cost

The previous MINGW64 build took about 18 minutes. The job runs in parallel with
the six existing targets, so release wall-clock should be unchanged; macOS is
already the long pole. Because the Windows target sits in `needs:` for publish,
**a Windows failure blocks the release**, which is exactly what stalled releases
for eight weeks (§2.1). **Decided (D8): the target is `optional: true` from
day one.** In §4.2:
* the build matrix sets `continue-on-error: ${{ matrix.target.optional || false }}`;
* publish uploads whatever optional assets exist;
* a missing optional asset is a warning in the run summary, not a failure.

## 5. Recipe B — a pyhdl-if test environment on Windows

### 5.1 Shape of the environment

```
windows-latest
├─ MSYS2 UCRT64 (setup-msys2)   gcc/g++, make, perl, sh   ← compiles simv.exe
├─ python.org CPython 3.14      pytest, dv-flow-*, pyhdl-if ← drives the flow
└─ verilator-windows-x86_64     from verilator-bin release
```

* Tests run from **native Python** (pwsh, or Git-Bash), not inside the MSYS2
  shell.
* `PATH` order: `<verilator>/bin`, `<msys64>/ucrt64/bin`, `<msys64>/usr/bin`,
  then the setup-python directories. `ucrt64/bin` must come before `usr/bin` so
  that `gcc` is the UCRT64 one.
* **`PYTHON3` hazard.** Verilator's generated makefiles call `$(PYTHON3)`. On a
  Windows runner, `python3` can resolve to the Microsoft Store stub. The
  environment sets `PYTHON3` to the setup-python interpreter explicitly. The
  `PYTHON3 = python3` rewrite in `CMakeLists.txt:340-356` may need to defer to
  that variable.

### 5.2 CI: a composite action plus the pyhdl-if job

To keep pyhdl-if's workflow short, verilator-bin (D10) ships a composite action,
`.github/actions/setup-windows-verilator/action.yml`:

1. `msys2/setup-msys2@v2` (UCRT64, `update: false`), installing
   `mingw-w64-ucrt-x86_64-gcc make perl`.
2. Download `verilator-windows-x86_64-*.tar.gz` for a given `version`
   (default: latest full release) with `gh release download`, verify its
   `.sha256`, and extract it.
3. Append the §5.1 `PATH` entries to `$GITHUB_PATH`, and set `PYTHON3` and
   `VERILATOR_ROOT` in `$GITHUB_ENV`.
4. Sanity check: `verilator --version` from `pwsh`.

The pyhdl-if job (`windows-pretest`, next to `linux-pretest`):

```yaml
runs-on: windows-latest
steps:
  - uses: actions/checkout@v4
  - uses: actions/setup-python@v5
    with: { python-version: "3.14" }
  - uses: edapack/verilator-bin/.github/actions/setup-windows-verilator@v1
  - run: pip install pytest git+…/dv-flow-mgr git+…/dv-flow-libhdlsim git+…/pytest-dfm
  - run: python setup.py build_ext --inplace --compiler=mingw32
  - run: pytest tests/unit
    env: { PYTEST_FV_HDLSIM: vlt }
```

**Phase 1 deliberately bypasses ivpm.** It gets Verilator from
`gh release download` and the Python dependencies from `pip`. ivpm on Windows
has the cache-symlink issue (§2.3) and is not on the critical path. Moving the
job back to `ivpm update -a` is a follow-up once that is fixed (§6, step 7).

### 5.3 Desktop: manual steps

Documented in a new `docs/windows.md` in verilator-bin:

1. Install MSYS2, then in its shell run
   `pacman -S mingw-w64-ucrt-x86_64-gcc make perl`.
2. Install python.org CPython.
3. Download and extract the `windows-x86_64` asset.
4. Set `PATH` in the §5.1 order, and set `PYTHON3`. Optionally use a
   `setup-env.ps1` in the tarball that does this for the current session.
5. Clone pyhdl-if, `pip install -e .` plus the test dependencies, then run
   pytest.

### 5.4 Consumer-side changes recipe B depends on

These live outside verilator-bin, but without them the environment has nothing
to run.

**dv-flow-libhdlsim:**

* Find `verilator` via `shutil.which`; this works once the `.cmd` shim exists
  (§4.1 item 6).
* Execute the resolved path. `create_subprocess_exec` of a `.cmd` works on
  Windows, but this needs verifying, and the fallback is `perl <path>`.
* Use `simv.exe` when `sys.platform == 'win32'`.
* Replace `-Wl,--export-dynamic` with `-Wl,--export-all-symbols`.
* Drop `-rpath`, and prepend the DPI library directories to `PATH` in
  `SimRun`'s environment.

**pyhdl-if:**

* Delete `setup.py:49-51`.
* Port `entry.c`: add a `dlopen`/`dlsym` → `LoadLibraryExW`/`GetProcAddress`
  shim; look up DPI exports through `GetModuleHandle(NULL)`; find Python from
  `PYHDL_IF_PYTHON` with `sys.base_prefix` and `python3XY.dll`, using
  `CreateProcess`/`_popen` instead of `posix_spawn`; handle `;` and `\` as
  separators.
* Fix the ctypes `LoadLibrary(None)` sites.
* Build the DLL with MinGW gcc.

## 6. Plan and milestones

**Progress** (updated as steps finish):

| Step | State | Notes |
|---|---|---|
| 1 Spike | **done** 2026-10-23 | branch `windows-spike`, `.github/workflows/windows-spike.yml`; `ci.yml` push builds are off on that branch |
| | | Run 1 (`39878427213`): Verilator 5.053 built under UCRT64 (GCC 16.2), statically linked. The smoke-test model failed to link (§6.1) |
| | | Probe (`39879952731`, `windows-probe.yml`): bug reproduced with a five-line program and with MSYS2's own verilator package; `-std=gnu++17` fixes it |
| | | Run 2 (`39880200411`): build and MSYS2-shell smoke pass. From pwsh, `verilator.cmd` found the script but Verilator mislocated its root, because MSYS2 perl's FindBin does not split a `\` path |
| | | Run 3 (`39881909472`): **green.** The pwsh path works: `Get-Command`/`shutil.which` find `verilator.cmd`, and `--binary` builds and runs. `verilator_bin.exe` imports only Windows system DLLs, and `bin/` ships none. Tarball is `verilator-windows-x86_64-5.053.20261023.tar.gz`, 14 MB |
| 2 | next | Also fix two manifest defects seen in run 3: `platform` reads `os: mingw64_nt-10.0-26100, libc: glibc_3.6` (`ec_platform_json`, §4.2), and `inputs` still lists bitwuzla, which is not built on Windows (`build.sh` should drop it) |
| 3–7 | not started | |

Each step is independently checkable. Steps 1–3 are verilator-bin and
edapack-common; steps 4–6 are the consumers.

1. **Spike.** Run a throwaway workflow in a verilator-bin branch with the old
   msys2 job, UCRT64 and x86_64 only, calling `scripts/build.sh` directly.
   Done when the smoke test passes. This de-risks D2 and the static-link change
   before touching the shared pipeline.
2. **Recipe A, items 1–9** (§4.1), with `kind: msys2` in an edapack-common
   branch (§4.2), and verilator-bin's `ci.yml` pointed at that branch. Done when
   a `workflow_dispatch` dev-track run publishes a prerelease that includes
   `verilator-windows-x86_64-*.tar.gz`, and its manifest says `os: windows`.
3. **Merge edapack-common and retarget `v1`.** Repoint verilator-bin at `@v1`.
   Add the `optional` target flag (§4.4).
4. **Composite action** (§5.2), plus a self-test job in verilator-bin that uses
   it to run a plain `--binary` design from native Python through
   dv-flow-libhdlsim. This is the first point where libhdlsim's Windows fixes
   (§5.4) are needed. Done when an hdlsim `SimImage` + `SimRun` passes on
   Windows with no pyhdl-if involved.
5. **pyhdl-if port** (§5.4): `setup.py`, `entry.c`, ctypes. Done when a single
   DPI test (e.g. `test_py_api`) passes on Windows.
6. **pyhdl-if `windows-pretest` job** running all of `tests/unit`. Failing
   tests are skipped explicitly with a reason, so the job can go green and the
   rest is tracked.
7. *(Follow-up.)* ivpm on Windows: a copy fallback in the cache, and `mingw` as
   a Windows key. Then the pyhdl-if job moves to `ivpm update -a`, matching
   Linux.

### 6.1 Finding: MSYS2 GCC 16.2, C++20 and `-Os`

The current MSYS2 toolchain is GCC 16.2, which defaults to `-std=gnu++20`.
In that mode at `-Os`, a call to `std::string`'s move constructor compiles to
an out-of-line reference that `libstdc++` does not export. Linking fails with
`undefined reference to std::__cxx11::basic_string<…>::basic_string(basic_string&&)`.

* `-O2` links, and so does `-std=gnu++17` at any `-O`.
* `verilated.mk` builds the runtime (`verilated.cpp`) at `-Os`, so every model
  hits the bug. This includes MSYS2's own `mingw-w64-ucrt-x86_64-verilator`.
* The March builds used GCC 15, which defaults to gnu++17, so this is new.

**Workaround:** the Windows post-install pins `CFG_CXXFLAGS_STD =
-std=gnu++17` in the shipped `verilated.mk`. A user's `-CFLAGS -std=…` still
overrides it.

Worth reporting upstream to MSYS2/GCC once the spike is green.

## 7. Housekeeping

* Replace `WINDOWS_BUILD_SUMMARY.md` with a pointer to this doc and to
  `docs/windows.md`. It currently claims "Production Ready" for a build that has
  not run since March.
* Delete `scripts/debug-mingw-env.sh`; it refers to the GMP-from-source path
  that no longer exists.
* `scripts/create-pacman-package.sh` is not needed for these goals. Keep it but
  leave it unwired. A pacman package is an alternative distribution for later,
  and ivpm would not consume it.
* The legacy comment at `.github/workflows-legacy/ci.yml:213` ("cross-compilation
  issues") is wrong (the builds were native). Leave it; the file is archived.

## 8. Review outcome (2026-10-23)

| Question | Answer |
|---|---|
| UCRT64 vs MINGW64 | **UCRT64** (D2). It is MSYS2's maintained default; MINGW64 is the fallback |
| Should Windows block a release? | **No.** `optional` target (D8, §4.4) |
| Keep Bitwuzla on Windows? | **No** (D9, §4.1 item 9) |
| Where the composite action lives | **verilator-bin** (D10, §5.2) |
| Python versions for pyhdl-if on Windows | **Newest release only, 3.14** (D5) |

Next step: the §6 step 1 spike, in a verilator-bin branch.
