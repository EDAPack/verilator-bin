#!/bin/bash
# Overlay Verilator's UVM DPI sources onto the installed UVM tree.
#
# Verilator carries a complete, working UVM DPI source set under
# test_regress/t/uvm/<version>/dpi -- including the uvm_hdl_verilator.c VPI
# backend that Accellera UVM does not ship -- but `make install` installs
# nothing from test_regress. Without the overlay, uvm_dpi.cc cannot compile
# (stock uvm_hdl.c #errors with "hdl vendor backend is missing"), which forces
# consumers onto +define+UVM_NO_DPI. That downgrades uvm_re_match to glob-only
# matching and disables register backdoor access.
#
# Only three files differ substantively from Accellera's src/dpi:
#   uvm_hdl_verilator.c  new: VPI-based backdoor backend
#   uvm_hdl.c            adds the #ifdef VERILATOR branch
#   uvm_dpi.h            drops <malloc.h> (absent on macOS)
# The rest is clang-format whitespace. uvm_regex.cc is byte-identical modulo
# trailing whitespace -- the regex engine is stock UVM.
#
# Usage: install-uvm-dpi.sh <verilator-src-dir> <install-prefix> <uvm-version>

set -e

VERILATOR_SRC="$1"
INSTALL_PREFIX="$2"
UVM_VERSION="$3"

if test -z "${VERILATOR_SRC}" -o -z "${INSTALL_PREFIX}" -o -z "${UVM_VERSION}"; then
    echo "ERROR: usage: $0 <verilator-src-dir> <install-prefix> <uvm-version>" >&2
    exit 1
fi

#--------------------------------------------------------------------
# Map the UVM version we ship to Verilator's DPI directory for it.
# An unmapped version is a hard error: silently shipping a UVM whose
# DPI layer does not match is worse than failing the build.
#--------------------------------------------------------------------
case "${UVM_VERSION}" in
    1800.2-2017-1.0) DPI_SUBDIR="v2017_1_0" ;;
    1800.2-2020-3.1) DPI_SUBDIR="v2020_3_1" ;;
    *)
        echo "ERROR: no Verilator UVM DPI mapping for UVM '${UVM_VERSION}'." >&2
        echo "       Add a case here and verify the directory exists under" >&2
        echo "       ${VERILATOR_SRC}/test_regress/t/uvm/" >&2
        exit 1
        ;;
esac

DPI_SRC="${VERILATOR_SRC}/test_regress/t/uvm/${DPI_SUBDIR}/dpi"
DPI_DST="${INSTALL_PREFIX}/share/uvm/src/dpi"

#--------------------------------------------------------------------
# Hard-fail if upstream moved the sources. Verilator could rename or
# relocate test_regress/t/uvm at any time; failing loudly is correct,
# because the alternative is silently reverting every downstream user
# to glob-only regex matching.
#--------------------------------------------------------------------
if test ! -d "${DPI_SRC}"; then
    echo "ERROR: Verilator UVM DPI sources not found at:" >&2
    echo "       ${DPI_SRC}" >&2
    echo "       Upstream may have moved test_regress/t/uvm; update the" >&2
    echo "       mapping in $0." >&2
    exit 1
fi

if test ! -f "${DPI_SRC}/uvm_hdl_verilator.c"; then
    echo "ERROR: ${DPI_SRC} exists but has no uvm_hdl_verilator.c." >&2
    echo "       That file is the Verilator VPI backend and is the whole" >&2
    echo "       point of this overlay." >&2
    exit 1
fi

if test ! -d "${DPI_DST}"; then
    echo "ERROR: installed UVM tree not found at ${DPI_DST}" >&2
    echo "       The 'uvm' target must run before this script." >&2
    exit 1
fi

#--------------------------------------------------------------------
# Copy sources and headers, overwriting. Other vendors' backends
# (uvm_hdl_vcs.c, uvm_hdl_questa.c, uvm_hdl_xcelium.c) are left in
# place -- this is an overlay, not a replacement. .clang-format is
# deliberately excluded.
#--------------------------------------------------------------------
OVERLAID=""
for f in "${DPI_SRC}"/*.c "${DPI_SRC}"/*.cc "${DPI_SRC}"/*.h "${DPI_SRC}"/*.svh; do
    test -f "$f" || continue
    cp -f "$f" "${DPI_DST}/"
    OVERLAID="${OVERLAID} $(basename "$f")"
done

if test -z "${OVERLAID}"; then
    echo "ERROR: no files overlaid from ${DPI_SRC}" >&2
    exit 1
fi

#--------------------------------------------------------------------
# Record provenance so "which upstream commit is this from?" is
# answerable from a released tarball.
#--------------------------------------------------------------------
VERILATOR_SHA="unknown"
if command -v git >/dev/null 2>&1; then
    VERILATOR_SHA=$(git -C "${VERILATOR_SRC}" rev-parse HEAD 2>/dev/null || echo unknown)
fi

{
    echo "Verilator UVM DPI overlay"
    echo ""
    echo "These files were copied into the Accellera UVM tree by verilator-bin."
    echo "Accellera UVM does not ship a Verilator backend for uvm_hdl_*; Verilator"
    echo "does, but only inside its test suite, which 'make install' does not"
    echo "install. See docs/design/uvm-dpi.md."
    echo ""
    echo "uvm_version:     ${UVM_VERSION}"
    echo "verilator_sha:   ${VERILATOR_SHA}"
    echo "source_path:     test_regress/t/uvm/${DPI_SUBDIR}/dpi"
    echo "overlaid_files: ${OVERLAID}"
} > "${DPI_DST}/VERILATOR_DPI_PROVENANCE.txt"

echo "Overlaid Verilator UVM DPI sources (${DPI_SUBDIR}) into ${DPI_DST}"
echo "  files:${OVERLAID}"
