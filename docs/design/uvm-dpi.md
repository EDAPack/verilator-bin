# Design: ship the UVM DPI sources with verilator-bin and use them from libhdlsim

Status: **implemented and shipping**, and since 2026-09-19 **superseded in part**
by §8: the shipped UVM moved to 1800.2-2020.3.2, which carries the Verilator
backend upstream, so the overlay this document designs no longer exists. §§1–7
are kept as the record of why the capability is there and how it is tested;
read §8 first for what the build actually does today.
Date: 2026-08-28, updated 2026-09-19
Scope: `verilator-bin` (packaging + build test), `dv-flow-libhdlsim` (Verilator
`SimLibUVM`), spanning two repositories.

## 1. Summary of the investigation

The premise checks out, with one important qualification.

Verilator **does** carry a complete, working set of UVM DPI sources — including
everything UVM needs for regular-expression matching — but they live in the
**test suite**, not in the installed tree:

```
test_regress/t/uvm/v2017_1_0/dpi/     <- UVM 1800.2-2017-1.0
test_regress/t/uvm/v2020_3_1/dpi/     <- UVM 1800.2-2020-3.1
```

`make install` (`installdata:` in `Makefile.in`) installs `include/`,
`include/vltstd/`, `examples/`, man pages and the pkg-config/CMake files. It
does **not** install anything from `test_regress`. Confirmed against the local
install:

```
$ ls /tools/verilator/5.040-git-20251011/share/
man  pkgconfig  verilator          # no uvm/
```

So the sources exist upstream, are exercised by upstream CI
(`t_uvm_dpi_v2017_1_0.py`, `t_uvm_hello_all_v2017_1_0_dpi.py`), and are simply
not shipped. That is the gap this design closes.

### 1.1 What is actually Verilator-specific

Diffing `test_regress/t/uvm/v2017_1_0/dpi/` against Accellera UVM
1800.2-2017-1.0 `src/dpi/`, there are exactly **three** substantive deltas; the
rest is clang-format whitespace:

| File | Delta |
|---|---|
| `uvm_hdl_verilator.c` | **New file.** VPI-based implementation of `uvm_hdl_check_path` / `read` / `deposit` / `force` / `release`. Not present in Accellera UVM at all. |
| `uvm_hdl.c` | Adds the `#ifdef VERILATOR` → `#include "uvm_hdl_verilator.c"` branch. Stock UVM knows only VCS / Questa / Xcelium and `#error`s otherwise. |
| `uvm_dpi.h` | Drops `#include <malloc.h>` (absent on macOS). |

Notably **`uvm_regex.cc` is bit-identical to Accellera's apart from trailing
whitespace.** The regex engine is stock UVM (POSIX `<regex.h>`); what Verilator
supplies is the missing *vendor backend* that lets the whole `uvm_dpi.cc`
translation unit link at all. You cannot take the regex half without the HDL
half — `uvm_dpi.cc` is a single translation unit that unconditionally
`#include`s `uvm_common.c`, `uvm_regex.cc`, `uvm_hdl.c` and `uvm_svcmd_dpi.c`.

`-DVERILATOR=1` is set unconditionally by `include/verilated.mk.in:88`, so the
backend selects itself with no user action.

Licensing: all files are Apache-2.0 (Accellera / Cadence / Mentor / NVIDIA /
Synopsys), same as the UVM we already redistribute in `share/uvm`. No new
license obligation beyond carrying `NOTICE.txt`, which we already do.

### 1.2 What we ship today, and why it is degraded

`verilator-bin`'s CMake installs Accellera UVM 1800.2-2017-1.0 into
`share/uvm/src`. That tree's `src/dpi/` has `uvm_hdl_vcs.c`,
`uvm_hdl_questa.c`, `uvm_hdl_xcelium.c` — and no Verilator backend. So
`uvm_dpi.cc` cannot compile, and libhdlsim compensates
(`vlt_sim_lib_uvm.py:66`) by forcing:

```python
defines=["UVM_NO_DPI"]
```

`UVM_NO_DPI` swaps in the SystemVerilog fallback in `uvm_regex.svh`, which is
explicit about what it is:

```
// The Verilog only version does not match regular expressions,
// it only does glob style matching.
```

I measured the consequence rather than assuming it. Built stock UVM 2017 under
Verilator 5.041 with `+define+UVM_NO_DPI`:

```
uvm_re_match('^a.*b$','axxxb')    = 1   (0 == match)  -> WRONG
uvm_re_match('^(foo|bar)$','bar') = 1   (0 == match)  -> WRONG
```

Both should be `0`. This is not a corner case: `uvm_re_match` backs
`uvm_config_db` / `uvm_resource_db` scope matching, `set_report_id_verbosity`
and friends, factory overrides by name, and `+uvm_set_*` command-line
processing. Any user who writes a real regex today gets a silent non-match.
`UVM_NO_DPI` additionally disables register backdoor access
(`uvm_hdl_*` become `uvm_report_fatal` stubs) and the DPI command-line
processor.

### 1.3 Proof the fix works

Copied Verilator's `v2017_1_0/dpi/*` over a stock Accellera 2017-1.0
`src/dpi/`, then built and ran without `UVM_NO_DPI`:

```
verilator --binary --vpi --timing -j 0 \
  +incdir+<uvm>/src <uvm>/src/uvm_pkg.sv <uvm>/src/dpi/uvm_dpi.cc test.sv
```

```
UVM DPI SMOKE PASSED
```

where the test asserts `^a.*b$` matches, `^a.*b$` does *not* match `axxxc`,
`^(foo|bar)$` matches `bar`, and `uvm_hdl_read("t.sig", v)` returns
`32'hdeadbeef` from a `/*verilator public*/` signal. Overlaying Verilator's
files onto the Accellera tree is safe: it adds `uvm_hdl_verilator.c` and
replaces four files whose only non-whitespace changes are the three listed in
§1.1, leaving the other vendors' backends untouched.

### 1.4 `--vpi` is mandatory, and is a hard constraint on libhdlsim

Control experiment — same build without `--vpi`:

```
mold: error: undefined symbol: vpi_handle
mold: error: undefined symbol: vpi_get_value
mold: error: undefined symbol: vpi_put_value
mold: error: undefined symbol: vpi_release_handle
mold: error: undefined symbol: vpi_get_vlog_info
mold: error: undefined symbol: vpi_get
mold: error: undefined symbol: vpi_handle_by_name
```

There is no "regex-only, no VPI" build: `uvm_svcmd_dpi.c` needs
`vpi_get_vlog_info` and `uvm_hdl_verilator.c` needs the rest, and both are in
the same translation unit. Defining `UVM_HDL_NO_DPI` only stubs the *SV* side;
the C side still compiles and still needs VPI.

This collided with `vlt_sim_image.py`, which conflated three separate concerns
behind one guard:

```python
if len(data.vpi) > 0:
    if not custom_main:
        raise Exception("VPI in VLT requires a verilatorMain (eg cocotb)")
    cmd.extend(['--vpi', '--public-flat-rw'])
    ...
```

`--vpi` on its own does not need a custom main — Verilator's own
`t_uvm_hello_all_*_dpi.py` uses `--binary --vpi` with a generated main. This
has been fixed ahead of the rest of the design; see §4.0.

## 2. Goals / non-goals

Goals:

* `verilator-bin` installs a Verilator-capable UVM DPI source set alongside the
  UVM it already ships.
* libhdlsim's Verilator `SimLibUVM` uses it automatically: real regex matching
  and working register backdoor, no user-visible configuration.
* Graceful degradation: an older `verilator-bin`, or a `$UVM_HOME` pointing at
  stock Accellera UVM, keeps working exactly as it does today.
* The capability is verified in `verilator-bin`'s build, so a silent upstream
  regression fails CI rather than shipping.

Non-goals:

* Upgrading the shipped UVM to 1800.2-2020-3.1. (The design maps versions so
  that upgrade is a one-line change later.)
* Vendoring a fork of the UVM DPI sources in `verilator-bin`. We copy from the
  Verilator tree we already clone, so we inherit upstream fixes for free.
* `uvm_hdl_polling.c` / `uvm_polling_dpi.svh` — 2020-3.1 only, out of scope.

## 3. verilator-bin changes

### 3.1 Install the DPI overlay

The Verilator `ExternalProject` source tree is already on disk at build time at
`${CMAKE_BINARY_DIR}/verilator-prefix/src/verilator` (same convention
`scripts/linux-post-install.sh` uses for `bitwuzla-prefix`). New script
`scripts/install-uvm-dpi.sh <verilator-src-dir> <install-prefix> <uvm-version>`:

1. Maps the shipped UVM version to the Verilator DPI directory:

   | UVM shipped | Verilator dir |
   |---|---|
   | `1800.2-2017-1.0` | `test_regress/t/uvm/v2017_1_0/dpi` |
   | `1800.2-2020-3.1` | `test_regress/t/uvm/v2020_3_1/dpi` |

   The version is the `UVM_VERSION` cache variable in `CMakeLists.txt`, which
   also builds the Accellera download URL; the mapping lives in the script.

2. **Hard-fails** if the directory is absent. Verilator could move or rename
   `test_regress/t/uvm` at any time; failing the build is the correct response
   because the alternative — silently reverting users to glob matching — is the
   exact bug we are fixing. The failure message names the expected path so the
   fix is a one-line mapping update.

3. Copies `*.c`, `*.cc`, `*.h`, `*.svh` (explicitly **not** `.clang-format`)
   over `${INSTALL_PREFIX}/share/uvm/src/dpi/`, overwriting, preserving the
   other vendors' backends.

4. Writes a provenance manifest
   `${INSTALL_PREFIX}/share/uvm/src/dpi/VERILATOR_DPI_PROVENANCE.txt`
   recording the Verilator git SHA, the source path, the UVM version, and the
   list of overlaid files. This makes "which upstream commit is this from"
   answerable from a released tarball, and gives libhdlsim a stable
   capability marker (§4.1).

Wired in as its own `uvm-dpi` `ExternalProject` that `DEPENDS uvm verilator`
(it needs the destination tree from one and the source tree from the other);
`post-install` now depends on it. Installation is a plain file copy, so it runs
identically on all platforms — only the *tests* are platform-gated (§5.1).

Verified against a simulated install prefix: the overlay lands 11 files, leaves
`uvm_hdl_vcs.c` / `uvm_hdl_questa.c` / `uvm_hdl_xcelium.c` in place, and writes
a provenance file naming Verilator SHA `0019c122`.

### 3.2 Build-time tests

Two of them, because "the files are installed and compile" and "the package
works the way people consume it" are different claims.

**`tests/uvm_dpi/`** — raw Verilator. `uvm_dpi_smoke.sv` (five regex
assertions including alternation, `.*` and a character class, `uvm_glob_to_re`,
plus `uvm_hdl_read`/`uvm_hdl_deposit` round-trips against a
`/*verilator public*/` signal) driven by `run_uvm_dpi_test.sh`, which:

* locates `share/uvm` relative to the `verilator` on `PATH` (same two-candidate
  search libhdlsim uses: `share/uvm`, `share/verilator/uvm`);
* asserts `src/dpi/uvm_hdl_verilator.c` exists;
* runs `verilator --binary --vpi --timing -j 0 +incdir+<uvm>/src
  <uvm>/src/uvm_pkg.sv <uvm>/src/dpi/uvm_dpi.cc uvm_dpi_smoke.sv`;
* runs the binary under `timeout` and greps for `UVM DPI SMOKE PASSED`.

* also asserts the provenance file is present and non-empty, catching a
  half-applied overlay.

**`tests/uvm_dpi_dfm/`** — through dv-flow-mgr, ie the way the package is
actually consumed. `flow.dv` wires `hdlsim.vlt.SimLibUVM` → `SimImage` →
`SimRun`, and `uvm_dpi_tb.sv` is a real `uvm_test` run via `run_test()` that
makes the same assertions and requires a clean UVM report summary.
`run_dfm_test.sh` provisions a venv from PyPI, then runs the flow with
`UVM_HOME` deliberately **unset**, so `SimLibUVM` has to discover UVM from the
installed layout rather than from a path we handed it.

The flow sets `dpi: "true"`, not `"auto"`: if the overlay is missing this must
fail, not quietly fall back and then fail later with a confusing regex
mismatch. Because dv-flow-mgr's console UI does not print task markers, the
script digs markers out of the per-task `exec_data.json` on failure — otherwise
a CI failure reads only as "status 1".

Added as `uvm-dpi-test` (depends on `post-install`) and `uvm-dpi-dfm-test`
(depends on `uvm-dpi-test`), mirroring the existing `smoke-test` target.
`VERILATOR_BIN_SKIP_DFM_TEST=1` skips the dv-flow one for an offline build.

Cost: ~18 s of verilation each on 32 threads, so roughly two of those plus a
pip install in the manylinux containers. Real, but it is the only thing
standing between an upstream refactor and a silently degraded release.

Both were validated against a simulated install prefix — passing with the
overlay, and failing with a legible message once `uvm_hdl_verilator.c` was
removed.

### 3.3 Docs

**Done** (2026-09-18). `README.md` has a "UVM" section covering the bundled
backend and its provenance file, what `UVM_NO_DPI` costs, the `--vpi`
requirement, the `/*verilator public*/` / `--public-flat-rw` requirement for
backdoor access, and the libhdlsim `dpi` parameter. Its copy-paste `verilator`
command line was run against a local install before being written down.

## 4. dv-flow-libhdlsim changes

### 4.0 Separate `--vpi` from cocotb

Prerequisite, landed independently of the rest of this design because it is a
correctness fix in its own right. `vlt_sim_image.py` now treats three concerns
separately:

| Concern | Flag | Needs a custom main? |
|---|---|---|
| Verilator's VPI runtime | `--vpi` | **No** |
| Signal visibility | `--public-flat-rw` | No |
| Linking an external VPI shared library | `-LDFLAGS -l...` | **Yes** |

The `verilatorMain` guard now fires only on the third — the case it was
actually written for — and its message says so
(`"Linking a VPI library in VLT requires a verilatorMain (eg cocotb)"`).
Linking a VPI library still implies the first two, so existing cocotb flows
are unchanged.

`--public-flat-rw` is deliberately *not* implied by `--vpi`: it inhibits
optimization across the whole design, and the common VPI/DPI cases reach
signals that are already public.

Plumbing:

* `VlSimImageData` gains `vpi_enable` and `public_flat_rw`.
* Verilator's `SimImage` gains `vpi` and `public_flat_rw` params
  (`vlt_flow.dv`), for direct user control.
* `hdlsim.SimCompileArgs` gains `vpi` and `public_flat_rw` bool fields, so a
  library can *declare* "I call VPI from C" rather than string-injecting
  `--vpi` through `args`. This is the channel §4.2 uses.

Covered by `tests/unit/test_vlt_vpi.py` (6 tests, all passing): a build with
`vpi=True`, a `cppSource` that calls `vpi_handle_by_name`/`vpi_get_value`, and
no `verilatorMain` — which previously raised — now compiles, runs, and asserts
`--public-flat-rw` was *not* pulled in as a side effect; plus the opt-in case
and a simulator-free parametrized test of the `SimCompileArgs` channel.

### 4.1 Capability detection

After `uvm_home` is resolved (existing `$UVM_HOME` → Verilator-`share` search
is unchanged), probe:

```python
dpi_cc = os.path.join(uvm_home, "src", "dpi", "uvm_dpi.cc")
dpi_vlt = os.path.join(uvm_home, "src", "dpi", "uvm_hdl_verilator.c")
dpi_capable = os.path.isfile(dpi_cc) and os.path.isfile(dpi_vlt)
```

Probing for `uvm_hdl_verilator.c` — not the provenance file — is deliberate: it
is the actual thing that makes the build link, so a hand-assembled `$UVM_HOME`
that has the backend also works.

### 4.2 Output when DPI is available

```python
FileSet(filetype="systemVerilogSource", basedir=uvm_home,
        files=["src/uvm_pkg.sv"], incdirs=["src"], defines=[])   # no UVM_NO_DPI
FileSet(filetype="cppSource", basedir=os.path.join(uvm_home, "src", "dpi"),
        files=["uvm_dpi.cc"])
ctxt.mkDataItem("hdlsim.SimCompileArgs", vpi=True)
```

Three notes on why this shape:

* `cppSource` is already gathered into `data.csource`
  (`vl_sim_image_builder.py:_gatherSvSources`) and appended to the `verilator`
  command line. No core change needed.
* `SimCompileArgs(vpi=True)` is a *declaration* — "this library calls VPI from
  C" — not a flag string, thanks to §4.0. It sets `data.vpi_enable` without
  touching `data.vpi`, so the `verilatorMain` guard stays untouched.
* No `public_flat_rw=True`: see §4.5.
* No `-DVERILATOR`: `verilated.mk` supplies it.

### 4.3 Fallback

If `dpi_capable` is false, emit exactly today's output (`UVM_NO_DPI`) plus a
`TaskMarker(severity=Warning)` naming the resolved `uvm_home` and saying that
regex matching is degraded to glob matching and backdoor access is unavailable.
A warning, not an error — old installs must keep working.

### 4.4 New `dpi` parameter

`vlt_flow.dv`'s `SimLibUVM` export gains:

```yaml
with:
  dpi:
    doc: Enable the UVM DPI layer (real regex matching, register backdoor).
         "auto" uses it when the UVM installation provides a Verilator backend.
    type: str
    value: "auto"          # auto | true | false
```

`true` turns the §4.3 warning into an error (for users who want to *guarantee*
they are not silently on the glob fallback); `false` forces `UVM_NO_DPI`, which
is the escape hatch if the DPI layer ever misbehaves.

### 4.5 Backdoor visibility is left to the user

`uvm_hdl_*` can only reach signals Verilator has exposed. Users need
`/*verilator public*/` on the target signals, or `public_flat_rw: true` on
`SimImage` (§4.0). `SimLibUVM` deliberately does **not** request it: it
inhibits optimization across the whole design and would silently slow every
UVM simulation, including the majority that never use backdoor access.
Document it instead. This is exactly the split §4.0 exists to make possible —
before it, asking for VPI meant getting `--public-flat-rw` whether you needed
it or not.

## 5. Test plan

### 5.1 verilator-bin

* `uvm-dpi-test` and `uvm-dpi-dfm-test` as described in §3.2, on every platform
  in the build matrix **except MinGW/Cygwin**. The DPI files are still
  *installed* on Windows (harmless — they are sources), but the tests are gated
  off because `uvm_dpi.h` requires POSIX `<regex.h>`, which mingw-w64 does not
  ship. That last part is an assumption I have not verified, and I would rather
  not have an unverified assumption gating the Windows build — if a MinGW build
  turns out to compile it, flip the gate on.
* Provenance file asserted present and non-empty (cheap, catches a
  half-applied overlay).

### 5.2 dv-flow-libhdlsim

* `tests/unit/test_simlib_uvm_dpi.py` — 7 tests, no simulator required, so the
  logic is protected on every CI run. Drives `SimLibUVM` against fixture UVM
  trees with and without `uvm_hdl_verilator.c` and covers: DPI selected (emits
  `cppSource` + `SimCompileArgs(vpi=True)`, no `UVM_NO_DPI`, and notably **no**
  `public_flat_rw`); fallback (emits `UVM_NO_DPI` *and* a warning marker);
  `dpi="true"` erroring rather than falling back; `dpi="false"` forcing the
  fallback silently; an invalid `dpi` value; and `uvm_dpi.cc` missing while the
  backend is present.
* `tests/unit/test_vlt_vpi.py` — 6 tests covering §4.0.
* Full-flow coverage lives in verilator-bin's `uvm-dpi-dfm-test` (§3.2) rather
  than being duplicated here, since it needs an installed overlay to be
  meaningful.

### 5.3 Ordering — **resolved**

There was a genuine cross-repo ordering constraint: `uvm-dpi-dfm-test` fails on
a `dv-flow-libhdlsim` that predates the `dpi` parameter, with

```
E: Parameter 'dpi' not found in base task hdlsim.vlt.SimLibUVM
```

`dv-flow-libhdlsim 0.0.533139756912` (PyPI, 2026-08-28) carries the §4 changes —
the `dpi` parameter and the `uvm_hdl_verilator.c` probe — so the plain
`pip install dv-flow-libhdlsim` in `run_dfm_test.sh` is sufficient and
`DFM_TEST_LIBHDLSIM_SPEC` is only needed to test against something newer.
Confirmed end-to-end in CI: run 34766415545 (2026-09-13) reaches
`UVM_ERROR : 0` on all six targets.

Note this is a *test-only* dependency. The overlay itself (§3) ships
independently, and older libhdlsim releases keep working against a
new verilator-bin — they just stay on the `UVM_NO_DPI` path until upgraded.

## 6. Risks

| Risk | Mitigation |
|---|---|
| Verilator moves/renames `test_regress/t/uvm` | Build hard-fails with the expected path in the message (§3.1). Deliberately noisy. |
| UVM version drift between our tarball and Verilator's snapshot | Explicit version→directory map; unmapped version = build failure, not a silent mismatch. |
| Upstream changes `uvm_dpi.cc` in a way that breaks against our stock Accellera `.svh` files | `uvm-dpi-test` builds the real thing every release. |
| `--vpi` slows down or perturbs non-UVM builds | Scoped: only `SimLibUVM` requests it, so it appears only in UVM flows. |
| A user silently ends up on the `UVM_NO_DPI` fallback | `auto` emits a warning marker naming the path — but dv-flow-mgr's console UI does not print task markers, so in practice the warning is only visible in `exec_data.json`. `dpi: "true"` is the reliable guard. See §7.3. |
| verilator-bin CI depends on an unreleased libhdlsim | Test-only; §5.3 gives the ordering and the `DFM_TEST_LIBHDLSIM_SPEC` escape hatch. |
| MinGW lacks POSIX `<regex.h>` | Files installed, test gated off (§5.1). |
| Extra CI time (~minutes) for the UVM verilation | Accepted; it is the only guard against silently shipping the degraded path. |

## 7. Open questions

1. **Should we also ship `uvm_pkg_all_v2017_1_0_dpi.svh`?** Verilator's
   `nodist/uvm_pkg_packer` output is a single pre-preprocessed UVM package that
   upstream uses for its own tests. Our §1.3 experiment shows the *unpacked*
   Accellera `uvm_pkg.sv` compiles fine, so it is not needed — but it is a
   faster-compiling alternative. Recommend: skip for now.
2. **Upgrade the shipped UVM to 1800.2-2020-3.1?** Verilator supports both.
   2020-3.1 additionally gets `uvm_hdl_polling.c`. Out of scope here, but the
   `UVM_VERSION` variable and the version map in §3.1 make it close to a
   one-line change.
3. **Should dv-flow-mgr's console UI print task markers?** It prints markers a
   task reports through its log filter, but not markers reported via
   `ctxt.add_marker` from a pytask that runs no command — which is why
   `SimLibUVM`'s fallback warning is invisible on the console. That is a
   dv-flow-mgr issue, not a libhdlsim one; worked around here by having
   `run_dfm_test.sh` dump markers from `exec_data.json`. Worth fixing upstream,
   since the whole point of a warning is that someone reads it.

## 8. 2026-09-19 update: UVM 1800.2-2020.3.2, and the end of the overlay

### 8.1 What changed upstream

Accellera released UVM **1800.2-2020.3.2** on 2026-08-10, and it ships the
Verilator backend itself:

* `src/dpi/uvm_hdl_verilator.c` — present
* `src/dpi/uvm_hdl.c:41` — `#ifdef VERILATOR` → `#include "uvm_hdl_verilator.c"`
* `src/dpi/uvm_dpi.h:47` — `<malloc.h>` now behind `#ifndef UVM_NO_MALLOC`

The premise of §1 — "the sources exist upstream but only inside Verilator's
test suite" — no longer holds. Diffing Verilator's
`test_regress/t/uvm/v2020_3_2/dpi/` against Accellera 2020.3.2's `src/dpi/`
ignoring whitespace, **all sixteen files differ by exactly two lines each**, and
those two lines are the UVM release stamp:

```
< // $Rev:      2026-05-08 07:53:24 -0700 $      (Verilator's snapshot)
> // $Rev:      2026-08-10 12:49:20 -0700 $      (Accellera's release)
```

There is no Verilator-specific edit left anywhere in the set. Overlaying would
have replaced released files with a pre-release snapshot of identical code.

### 8.2 What the build does now

* `UVM_VERSION` defaults to `1800.2-2020.3.2`, with the download URL as its own
  `UVM_URL` variable: Accellera's asset naming is not uniform
  (`Accellera-<version>.tar.gz` for 2017-1.0, `<version>%20Release.gz` for
  2020.3.2), so deriving the URL from the version does not work. `DOWNLOAD_NAME`
  gives the bare-`.gz` asset a `.tar.gz` name so CMake extracts it rather than
  merely decompressing it.
* `scripts/install-uvm-dpi.sh` is replaced by `scripts/prepare-uvm-dpi.sh`,
  which no longer copies anything. It (1) asserts `uvm_hdl_verilator.c` is
  present and that `uvm_hdl.c` has the `VERILATOR` branch, failing the build
  loudly if a future UVM drops either; (2) applies the macOS fix in §8.3;
  (3) writes `VERILATOR_DPI_PROVENANCE.txt`, now recording the UVM version, the
  source URL, the UVM release hash and which patch was applied.
* The `uvm-dpi` target no longer `DEPENDS verilator` — it only needs the
  installed UVM tree.

The consequence worth naming: we no longer inherit Verilator's fixes to these
files automatically, because there are none to inherit. If Verilator ever needs
to diverge again, the fix is to restore the overlay, and the assertion in
`prepare-uvm-dpi.sh` is what will tell us.

### 8.3 macOS: `<malloc.h>`

2020.3.2's `uvm_dpi.h` includes `<malloc.h>`, which does not exist on macOS
(it is `<malloc/malloc.h>` there). UVM's escape hatch is `-DUVM_NO_MALLOC`, but
requiring a define on one platform is a trap: the symptom is a compile error
deep inside `uvm_dpi.cc`, and every already-released dv-flow-libhdlsim would
break on macOS. Note the 2017 overlay hid this — Verilator's copy of that
vintage deleted the include outright.

`prepare-uvm-dpi.sh` rewrites the guard to

```c
#if !defined(UVM_NO_MALLOC) && !defined(__APPLE__)
```

on every platform, so the shipped tree is identical everywhere and only the
preprocessor differs. Nothing in the DPI sources needs `malloc.h` —
`malloc`/`free` come from `<stdlib.h>`, already included. An `uvm_dpi.h` that
includes `malloc.h` in a form the patch does not recognize is a hard build
failure rather than a silently unpatched header.

### 8.4 Evidence

Against a locally built shipping-equivalent package (Verilator 5.053 trunk,
built by this repo's own CMake with `UVM_VERSION=1800.2-2020.3.2`):

* `uvm-dpi-test` passes — `UVM DPI SMOKE PASSED`, provenance file present.
* `uvm-dpi-dfm-test` passes — all five `uvm_test`s (§8.5), `UVM_ERROR : 0`,
  with `UVM_HOME` unset so `SimLibUVM` discovers UVM from the installed layout.
* libhdlsim needed **no change**: its capability probe looks for
  `uvm_hdl_verilator.c`, which the stock tree now has. That is exactly why §4.1
  probes for the backend rather than for our provenance file.

Earlier, with the 11-month-old Verilator 5.041 on the dev box, stock 2020.3.2
did *not* verilate (`Unsupported: Initial values in struct/union members`,
`uvm_reg_item.svh:561`). The upgrade is therefore coupled to a recent Verilator;
upstream's own `t_uvm_dpi_v2020_3_2.py` / `t_uvm_hello_all_v2020_3_2_*` tests
mean trunk keeps it working, and our `uvm-dpi-test` fails loudly if a given
build does not.

**Not verified locally: macOS.** The `__APPLE__` guard is reasoned, not
measured; CI's `macos-arm64` target is what proves it.

### 8.5 Test coverage (2026-09-18)

`tests/uvm_dpi_dfm` now builds one image and runs five `uvm_test`s through
`+UVM_TESTNAME`, one dv-flow task each — DPI primitives, `uvm_config_db` regex
scopes, factory instance overrides, `uvm_cmdline_processor`, and `uvm_reg`
backdoor `poke`/`peek`. Each was checked to fail under `dpi: "false"`, so the
suite cannot pass on the `UVM_NO_DPI` path. Two notes for whoever extends it:
`matches` is a SystemVerilog keyword, and an instance-override path needs the
`/.../` regex form because `uvm_glob_to_re` escapes `[` in a bare glob.

### 8.6 Open questions, revisited

* §7.2 (upgrade to 2020-3.1) is closed by this change, one release further on.
* `uvm_hdl_polling.c` is now compiled — it is `#include`d unconditionally by
  2020.3.2's `uvm_dpi.cc` — and builds clean under Verilator. The SV-side
  polling API is not otherwise exercised by our tests.
