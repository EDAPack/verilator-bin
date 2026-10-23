# Upstream task: Verilator fails to link at its documented C++14 floor

**Status:** ready to implement — fix below is written and verified locally, not yet filed upstream.
**Upstream repo:** https://github.com/verilator/verilator
**Affects:** `master` only (not any released tag).
**Our workaround:** `CMakeLists.txt` commit `70826d9` forces `gnu++17` for Verilator's own
build. That is in place and CI is green, so this upstream work is **not** blocking us — it
fixes the defect for everyone else and lets us drop the workaround later.

## What to do

1. File an issue on `verilator/verilator` (content: everything under "Bug report" below).
2. Open a PR with the patch in "Fix" — one file, 4 lines.
3. Optionally raise the CI-gap point separately (see "Secondary: nothing tests the C++14 floor").
   Keep it out of the fix PR; it is a policy question for maintainers, not a code fix.

## Bug report

### Summary

`src/V3AssertNfa.cpp` odr-uses a `static constexpr` data member that has no out-of-line
definition. Before C++17 that requires a definition, so linking Verilator fails on any
toolchain whose default C++ standard is C++14 — which the project still documents as
supported.

### Reproduction

```
git clone https://github.com/verilator/verilator && cd verilator
autoconf && ./configure
CXXFLAGS=-std=gnu++14 make -j$(nproc)
```

```
Linking ../../bin/verilator_bin_dbg...
ld: V3AssertNfa.o: in function
  `(anonymous namespace)::SvaNfaLowering::computeAttemptDepths(...)':
V3AssertNfa.cpp:2372: undefined reference to
  `(anonymous namespace)::SvaNfaLowering::kDepthUnreachable'
collect2: error: ld returned 1 exit status
make[2]: *** [../Makefile_obj:404: ../../bin/verilator_bin_dbg] Error 1
```

Note `CXXFLAGS=-std=gnu++14` only *simulates* the affected environment. Real reports come
from compilers that default to C++14, e.g. RHEL/CentOS 7 (devtoolset-10, GCC 10) as used
by the `manylinux2014` wheel images. There `configure` prints `supports C++14... yes`, so
it adds no `-std=` flag and the build silently proceeds as C++14.

### Root cause

`src/V3AssertNfa.cpp:2344`:

```cpp
static constexpr int kDepthUnreachable = -1;
static constexpr int kDepthAmbiguous = -2;
```

`src/V3AssertNfa.cpp:2372`:

```cpp
std::vector<int> depths(c.N, kDepthUnreachable);
```

`std::vector`'s fill constructor takes `const value_type&`. Binding a reference odr-uses
the member, which under C++14 ([basic.def.odr]/[class.static.data]) requires a namespace-scope
definition. C++17 made `constexpr` static data members implicitly `inline`, which is why
this links everywhere else.

Only `kDepthUnreachable` is affected. `kDepthAmbiguous` (lines 2387, 2391, 2392) appears
only in comparisons and assignments — lvalue-to-rvalue conversions, not odr-uses — so it
is latent, not broken. It would break the moment someone passes it by reference.

Two details worth knowing:

- **Only the debug binary fails.** At `-O3` the constant is folded and no reference is
  emitted, so `bin/verilator_bin` links fine; `bin/verilator_bin_dbg` (`-O0`) is what
  fails. A `-O3`-only build would not catch this.
- **This is the first odr-use of its kind in the tree.** There are ~90 `static constexpr`
  members across `src/`, and no out-of-line definition anywhere — none had ever been
  odr-used before.

### Origin

Introduced by commit `c81be029a6c6984d636369f2afd8853a4717edcb`
("Fix NFA assertion scheduling to fix outcome counts", PR #7946, 2026-08-29). The symbol
is absent from tag `v5.050`, so no release is affected — `master` only.

### Why this is a bug and not an obsolete requirement

The C++14 floor is current, documented, and the move off it is explicitly deferred:

- `docs/guide/deprecations.rst:10` — "Verilator currently requires a C++20 or newer
  compiler for timing, and a **C++14 or newer compiler for both compiling Verilator** and
  compiling Verilated models with `--no-timing`. […] Verilator will require C++20 or newer
  […] no sooner than May 2025. (Although this date has expired, **this change is currently
  on hold** until the Ubuntu LTS versions of GCC and clang use C++20 by default,
  **estimated May 2028**.)"
- `docs/internals.rst:1178` ("Compiler Version and C++14") — "Verilator requires C[++]14.
  Verilator does not require any newer versions, but is maintained to build successfully
  with C[++]17/C[++]20."
- `configure.ac:789` errors with "the $CXX compiler appears to not support C++14. Verilator
  requires a C++14 or newer compiler." Its `-std=` selection (`configure.ac:506-515`) lists
  `gnu++14`/`c++14` as accepted fallbacks.

C++20 is required only for timing/coroutines (`docs/guide/languages.rst:115`), not for
compiling Verilator itself.

## Fix

Also saved as `verilator-cxx14-odr-kdepthunreachable.patch` next to this file; verified to
apply cleanly to `c81be029` with `git apply`.

Make the constants enumerators. Enumerators are values, never objects, so they cannot be
odr-used and need no definition under any standard — this closes the trap for
`kDepthAmbiguous` too, rather than fixing only the one line that happens to break today.

```diff
--- a/src/V3AssertNfa.cpp
+++ b/src/V3AssertNfa.cpp
@@ -2341,8 +2341,10 @@ private:
         AstNodeExpr* throughoutRejectp = nullptr;  // Reject when a throughout guard drops
     };

-    static constexpr int kDepthUnreachable = -1;
-    static constexpr int kDepthAmbiguous = -2;
+    // Sentinels stored in the attempt-depth vector. An enum rather than
+    // 'static constexpr int' as enumerators are never odr-used, so this needs
+    // no out-of-line definition under Verilator's C++14 floor.
+    enum DepthSentinel : int { kDepthUnreachable = -1, kDepthAmbiguous = -2 };
     using OutcomeBuckets = std::map<int, AstNodeExpr*>;

     static AstNodeExpr* boolToCount(LowerCtx& c, AstNodeExpr* condp) {
```

The fixed underlying type `int` keeps every existing use working unchanged: the unscoped
enumerators convert implicitly at all seven use sites (2372, 2381, 2387, 2388, 2391, 2392),
including the `?:` at 2387 where the composite type is still `int`.

### Alternatives considered

- **Force a prvalue at the use site** — `std::vector<int> depths(c.N, int{kDepthUnreachable});`.
  One character-level change, but it leaves the declaration a trap: the next by-reference
  use reintroduces the same link error, with no signal at the declaration.
- **Add an out-of-line definition** — `constexpr int SvaNfaLowering::kDepthUnreachable;`.
  Correct for C++14, but such definitions are *deprecated* in C++17, and it introduces a
  pattern that appears nowhere else in `src/`.

The enum needs no per-use vigilance and no deprecated construct, so it is the recommended
form. If a maintainer prefers one of the alternatives, either resolves the reported bug.

### Verification performed

All on `c81be029` + the patch above, GCC 13.3.0 / Ubuntu 24.04 (a different toolchain from
the one that first reported it, which was GCC 10 / devtoolset-10):

| Check | Result |
| --- | --- |
| `CXXFLAGS=-std=gnu++14 make -k -j32`, unpatched | fails; `kDepthUnreachable` is the **only** error in the whole build (`-k` ran everything else to completion) |
| `CXXFLAGS=-std=gnu++14 make -j32`, patched | exit 0, `bin/verilator_bin_dbg` links |
| `CXXFLAGS=-std=gnu++17 make -j32`, patched | exit 0 — no regression at the standard everyone else uses |
| `test_regress/driver.py` over all 98 `t_assert*` / `*sva*` tests, patched | 95 passed, 1 failed |

The one failure is `t_cover_sva_trace` (VCD miscompare). It **fails identically on unpatched
`master`** — confirmed by stashing the patch, rebuilding, and re-running that test alone. It
is pre-existing and unrelated; do not let it block the PR, and do not claim to have fixed it.

Reproduction and verification notes: `test_regress/driver.py` needs the `distro` Python
module (`pip install distro`), and `wavediff` is absent on a stock box (harmless — it only
affects VCD-diff *reporting*, not the pass/fail result).

## Secondary: nothing tests the C++14 floor

This slipped in because upstream CI never builds at the documented minimum. There is no
`-std=` or `CXXFLAGS` setting anywhere in `.github/workflows/` or `ci/`; every build job
takes the runner's default (ubuntu-22.04/24.04/26.04 and macOS, gcc and clang), all of
which are C++17 or newer. So the C++14 floor is asserted in `configure.ac` and the docs but
exercised by nothing.

Worth raising with maintainers as a choice, not a patch — either is coherent, but the
current state is not:

- Add one build job with `CXXFLAGS=-std=gnu++14` (cheap; would have caught this at PR time).
  It must build the **debug** binary, since `-O3` folds the constant and hides the failure.
- Or drop the C++14 claim from `configure.ac` and the two docs above and move the floor to
  C++17, accepting that C++14 toolchains such as `manylinux2014` are no longer supported.

## Background: why we hit this

`edapack/verilator-bin` builds Verilator nightly from `master` across six wheel targets.
`manylinux2014_x86_64` (el7 / devtoolset-10 / GCC 10) is the only one whose compiler
defaults to C++14; the other five default to C++17 and were unaffected. Run
[33321666880](https://github.com/EDAPack/verilator-bin/actions/runs/33321666880) is the
original failure.

One trap for whoever revisits our side of this: the flag must be applied to the **build**,
not to `configure`. Verilator's `-std=` probe keys off whether `CXXFLAGS` already suffices,
and that same answer sets `CFG_CXXFLAGS_STD`, which `include/verilated.mk.in` passes to
*generated models*. Setting `CXXFLAGS` for `configure` makes the probe succeed, blanks
`CFG_CXXFLAGS_STD`, and leaves macOS models with no `-std=` at all — which broke our macOS
job in run
[33322786777](https://github.com/EDAPack/verilator-bin/actions/runs/33322786777) before
`70826d9` corrected it. See the comment at `CMakeLists.txt:263`.
