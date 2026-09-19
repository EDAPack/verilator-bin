#!/bin/bash
# Make the installed UVM tree's DPI layer usable under Verilator, and record
# what we did in a provenance file.
#
# HISTORY. Through UVM 1800.2-2017-1.0 this script's predecessor
# (install-uvm-dpi.sh) overlaid Verilator's own copy of the UVM DPI sources
# from test_regress/t/uvm/<version>/dpi, because Accellera UVM shipped backends
# for VCS, Questa and Xcelium only -- stock uvm_dpi.cc could not compile under
# Verilator at all, which forced every consumer onto +define+UVM_NO_DPI and its
# glob-only uvm_re_match.
#
# As of 1800.2-2020.3.2 that backend is upstream: Accellera ships
# uvm_hdl_verilator.c and the '#ifdef VERILATOR' branch in uvm_hdl.c itself.
# Verilator's test_regress copy is now byte-identical to Accellera's apart from
# the UVM release stamp in the file headers, so overlaying would only pin us to
# an older snapshot of the same code. The overlay is gone; what remains is:
#
#   1. assert the Verilator backend is actually there (cheap, and the failure
#      mode it catches -- silently reverting users to glob matching -- is the
#      exact bug this whole path exists to prevent);
#   2. one portability fix for macOS (see below);
#   3. the provenance file, which libhdlsim and the build tests look for.
#
# Usage: prepare-uvm-dpi.sh <install-prefix> <uvm-version> [uvm-source-url]

set -e

INSTALL_PREFIX="$1"
UVM_VERSION="$2"
UVM_URL="${3:-unknown}"

if test -z "${INSTALL_PREFIX}" -o -z "${UVM_VERSION}"; then
    echo "ERROR: usage: $0 <install-prefix> <uvm-version> [uvm-source-url]" >&2
    exit 1
fi

DPI_DST="${INSTALL_PREFIX}/share/uvm/src/dpi"

if test ! -d "${DPI_DST}"; then
    echo "ERROR: installed UVM tree not found at ${DPI_DST}" >&2
    echo "       The 'uvm' target must run before this script." >&2
    exit 1
fi

#--------------------------------------------------------------------
# 1. The Verilator backend must be present. If a future UVM release
#    drops it, fail the build loudly rather than shipping a package
#    whose UVM silently falls back to glob-only regex matching.
#--------------------------------------------------------------------
if test ! -f "${DPI_DST}/uvm_hdl_verilator.c"; then
    echo "ERROR: ${DPI_DST}/uvm_hdl_verilator.c is missing." >&2
    echo "       Accellera UVM ${UVM_VERSION} was expected to ship a Verilator" >&2
    echo "       backend for uvm_hdl_*. Without it uvm_dpi.cc cannot compile" >&2
    echo "       under Verilator and consumers are forced onto UVM_NO_DPI," >&2
    echo "       which downgrades uvm_re_match to glob-only matching." >&2
    echo "       Verilator carries a copy under test_regress/t/uvm/<ver>/dpi;" >&2
    echo "       restoring the overlay this script replaced is the fix." >&2
    exit 1
fi

if ! grep -q "VERILATOR" "${DPI_DST}/uvm_hdl.c"; then
    echo "ERROR: ${DPI_DST}/uvm_hdl.c has no VERILATOR branch, so the backend" >&2
    echo "       in uvm_hdl_verilator.c is never included." >&2
    exit 1
fi

#--------------------------------------------------------------------
# 2. macOS portability. uvm_dpi.h includes <malloc.h>, which does not
#    exist on macOS (it is <malloc/malloc.h> there). UVM's own escape
#    hatch is -DUVM_NO_MALLOC, but requiring every consumer to pass a
#    define on one platform is a trap: the symptom is a compile error
#    deep inside uvm_dpi.cc, and dv-flow-libhdlsim releases that
#    predate the change would break on macOS.
#
#    Nothing in the DPI sources needs malloc.h -- malloc/free come from
#    <stdlib.h>, which uvm_dpi.h already includes -- so make the include
#    compile-time conditional instead. Applied on every platform so the
#    shipped tree is identical everywhere; only the preprocessor cares.
#--------------------------------------------------------------------
MALLOC_PATCH="not needed"
if grep -q '^#ifndef UVM_NO_MALLOC' "${DPI_DST}/uvm_dpi.h"; then
    sed -i.bak 's/^#ifndef UVM_NO_MALLOC$/#if !defined(UVM_NO_MALLOC) \&\& !defined(__APPLE__)/' \
        "${DPI_DST}/uvm_dpi.h"
    rm -f "${DPI_DST}/uvm_dpi.h.bak"
    MALLOC_PATCH="applied (guarded <malloc.h> with !defined(__APPLE__))"
elif grep -q '^#if !defined(UVM_NO_MALLOC) && !defined(__APPLE__)' "${DPI_DST}/uvm_dpi.h"; then
    MALLOC_PATCH="already applied"
elif grep -q 'malloc.h' "${DPI_DST}/uvm_dpi.h"; then
    echo "ERROR: ${DPI_DST}/uvm_dpi.h includes malloc.h in an unrecognized form." >&2
    echo "       Update the patch in $0 -- an unpatched include breaks macOS." >&2
    grep -n 'malloc' "${DPI_DST}/uvm_dpi.h" >&2
    exit 1
fi

#--------------------------------------------------------------------
# 3. Provenance. Makes "what exactly is this DPI layer?" answerable
#    from a released tarball, and gives the build tests something
#    cheap to assert on.
#--------------------------------------------------------------------
# UVM stamps each source with the release hash it was cut from.
UVM_HASH=$(sed -n 's/^\/\/ \$Hash: *\([0-9a-f]*\).*/\1/p' \
    "${DPI_DST}/uvm_hdl_verilator.c" | head -1)
test -n "${UVM_HASH}" || UVM_HASH="unknown"

{
    echo "UVM DPI layer shipped by verilator-bin"
    echo ""
    echo "Accellera UVM ${UVM_VERSION} ships the Verilator backend for uvm_hdl_*"
    echo "(uvm_hdl_verilator.c) natively, so these files are upstream's, not ours."
    echo "verilator-bin only checks that the backend is present and applies the"
    echo "macOS include fix noted below. See docs/design/uvm-dpi.md."
    echo ""
    echo "uvm_version:       ${UVM_VERSION}"
    echo "uvm_source_url:    ${UVM_URL}"
    echo "uvm_release_hash:  ${UVM_HASH}"
    echo "verilator_backend: native (uvm_hdl_verilator.c from Accellera UVM)"
    echo "malloc_h_patch:    ${MALLOC_PATCH}"
} > "${DPI_DST}/VERILATOR_DPI_PROVENANCE.txt"

echo "Prepared UVM DPI layer in ${DPI_DST}"
echo "  uvm_version:       ${UVM_VERSION}"
echo "  verilator_backend: native"
echo "  malloc_h_patch:    ${MALLOC_PATCH}"
