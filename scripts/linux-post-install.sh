#!/bin/bash -x
# Linux post-install: collect shared libs into lib64, fix rpaths, clean up.
# Usage: linux-post-install.sh <install-prefix> <cmake-binary-dir>

INSTALL_PREFIX="$1"
CMAKE_BINARY_DIR="$2"

set -e

#--------------------------------------------------------------------
# Strip binaries
#--------------------------------------------------------------------
test -f "${INSTALL_PREFIX}/bin/verilator_bin" && \
    strip "${INSTALL_PREFIX}/bin/"* 2>/dev/null || true
test -d "${INSTALL_PREFIX}/share/verilator/bin" && \
    strip "${INSTALL_PREFIX}/share/verilator/bin/"* 2>/dev/null || true

#--------------------------------------------------------------------
# Copy any bitwuzla-internal shared libraries that meson didn't
# install (libcadical, etc.) directly into lib64.
# On some systems meson installs to lib64, on others to lib — handle both.
#--------------------------------------------------------------------
mkdir -p "${INSTALL_PREFIX}/lib64"
BWZLA_BUILD="${CMAKE_BINARY_DIR}/bitwuzla-prefix/src/bitwuzla/build"
if test -d "${BWZLA_BUILD}"; then
    find "${BWZLA_BUILD}" -maxdepth 4 -type f -name 'lib*.so*' ! -name '*test*' | \
        while read -r f; do
            bn=$(basename "$f")
            if test ! -f "${INSTALL_PREFIX}/lib64/${bn}" && \
               test ! -f "${INSTALL_PREFIX}/lib/${bn}"; then
                cp -v "$f" "${INSTALL_PREFIX}/lib64/"
            fi
        done
fi

#--------------------------------------------------------------------
# If meson installed to lib/ (not lib64/), merge lib/ into lib64/
#--------------------------------------------------------------------
if test -d "${INSTALL_PREFIX}/lib"; then
    cp -a "${INSTALL_PREFIX}/lib/." "${INSTALL_PREFIX}/lib64/"
    rm -rf "${INSTALL_PREFIX}/lib"
fi

#--------------------------------------------------------------------
# Use patchelf to replace any existing rpath with an ORIGIN-relative
# one so binaries work from any install location.
#--------------------------------------------------------------------
for f in \
    "${INSTALL_PREFIX}/bin/"* \
    "${INSTALL_PREFIX}/share/verilator/bin/"*
do
    test -f "$f" || continue
    file "$f" 2>/dev/null | grep -q ELF || continue
    patchelf --set-rpath '$ORIGIN/../lib64' "$f" 2>/dev/null || true
done

# Fix rpaths on the shared libraries themselves so they find sibling
# libs in the same lib64 directory at runtime (not the build-time paths).
for f in "${INSTALL_PREFIX}/lib64/"*.so*; do
    test -f "$f" || continue
    file "$f" 2>/dev/null | grep -q ELF || continue
    patchelf --set-rpath '$ORIGIN' "$f" 2>/dev/null || true
done

#--------------------------------------------------------------------
# Remove debug binaries and fix verilated.mk python path
#--------------------------------------------------------------------
rm -f "${INSTALL_PREFIX}/share/verilator/bin/"*_dbg 2>/dev/null || true

if test -f "${INSTALL_PREFIX}/share/verilator/include/verilated.mk"; then
    sed -i 's%PYTHON3 =.*$%PYTHON3 = python3%g' \
        "${INSTALL_PREFIX}/share/verilator/include/verilated.mk" || true
fi
