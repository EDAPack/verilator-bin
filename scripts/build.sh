#!/usr/bin/env bash
# verilator-bin build driver.
#
# Builds the exact verilator + bitwuzla commits resolved by edapack-common's
# resolve-inputs.py (passed in via $CANDIDATE_JSON, or resolved locally), so the
# shipped manifest.json truthfully records what was built. The heavy lifting is
# in CMakeLists.txt (ExternalProject fetch/build/install of verilator+bitwuzla);
# this script wires in the resolved refs and the shared release tail (skills,
# export.envrc, manifest, tarball).
#
# Runs both in CI (via edapack-common's reusable workflow) and locally (via
# edapack-common/scripts/local-build.sh). All transient state goes to WORK_DIR;
# the tarball + manifest land in OUT_DIR. Nothing is written into the source tree.
set -euo pipefail

# --- locate edapack-common --------------------------------------------------
if [ -z "${EC_COMMON:-}" ]; then
    # sibling checkout fallback for plain local runs
    _repo="$(cd "$(dirname "$0")/.." && pwd)"
    for _c in "$_repo/packages/edapack-common" "$_repo/../edapack-common"; do
        if [ -f "$_c/scripts/build-common.sh" ]; then EC_COMMON="$_c"; break; fi
    done
fi
if [ -z "${EC_COMMON:-}" ] || [ ! -f "$EC_COMMON/scripts/build-common.sh" ]; then
    echo "ERROR: edapack-common not found. Set EC_COMMON or place edapack-common beside verilator-bin." >&2
    exit 1
fi
# shellcheck source=/dev/null
source "$EC_COMMON/scripts/build-common.sh"

: "${EC_PACKAGE:=verilator-bin}"
export EC_PACKAGE
ec_init_dirs
ec_prepare_candidate

os="$(uname -s)"
plat="${EC_IMAGE_NAME:-}"

# --- provision the stock manylinux image (EC_INSTALL_DEPS=1 in CI/local) -----
if [ "${EC_INSTALL_DEPS:-0}" = "1" ] && [ "$os" = "Linux" ]; then
    yum install -y glibc-static wget flex bison jq help2man \
        cmake3 autoconf make gcc gcc-c++ git perl-core patchelf || true
    # prefer the manylinux cpython for meson/ninja (used by the bitwuzla build)
    [ -d /opt/python/cp312-cp312/bin ] && export PATH=/opt/python/cp312-cp312/bin:$PATH
    pip3 install meson ninja || true
    if [ -f /usr/bin/cmake3 ] && [ ! -f /usr/bin/cmake ]; then
        ln -s /usr/bin/cmake3 /usr/bin/cmake || true
    fi
fi

# --- platform label + per-OS quirks -----------------------------------------
REMOVE_PREGEN=0
IS_WINDOWS=0
case "$os" in
    Linux)  : "${plat:=linux}" ;;
    Darwin) : "${plat:=macos-$(uname -m)}"; REMOVE_PREGEN=1 ;;
    *)
        if echo "$os" | grep -q "MINGW\|MSYS"; then plat="${plat:-mingw64}"; IS_WINDOWS=1; fi
        if echo "$os" | grep -q "CYGWIN"; then plat="${plat:-cygwin64}"; IS_WINDOWS=1; fi
        ;;
esac

# --- resolved input commits -------------------------------------------------
vlt_sha="$(ec_input_get verilator resolved_sha)"
bwz_sha="$(ec_input_get bitwuzla resolved_sha)"
[ -n "$vlt_sha" ] && [ -n "$bwz_sha" ] || ec_die "missing resolved input SHAs in candidate"
ec_log "verilator @ $vlt_sha"
ec_log "bitwuzla  @ $bwz_sha"

# --- configure + build (CMake ExternalProject installs into the prefix) -----
release_root="$WORK_DIR/release/verilator"
build_dir="$WORK_DIR/build"
rm -rf "$release_root" "$build_dir"
mkdir -p "$build_dir"

cmake -S "$SRC_DIR" -B "$build_dir" \
    -DUSE_LATEST_BRANCH=OFF \
    -DVERILATOR_TAG="$vlt_sha" \
    -DBITWUZLA_TAG="$bwz_sha" \
    -DCMAKE_INSTALL_PREFIX="$release_root"

if [ "$REMOVE_PREGEN" = "1" ]; then
    find "$build_dir" -name "*_pregen*" -delete 2>/dev/null || true
fi

jobs="$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)"
cmake --build "$build_dir" -j"$jobs"

# --- Windows runtime DLLs ---------------------------------------------------
if [ "$IS_WINDOWS" = "1" ]; then
    mkdir -p "$release_root/bin"
    if echo "$os" | grep -q "MINGW\|MSYS"; then
        for pat in libgcc_s_ libstdc++- libwinpthread- libgmp- libmpfr-; do
            cp -v /mingw*/bin/${pat}*.dll "$release_root/bin/" 2>/dev/null || true
        done
    elif echo "$os" | grep -q "CYGWIN"; then
        for pat in cyggcc_s- cygstdc++- cygwin1 cyggmp- cygmpfr-; do
            cp -v /usr/bin/${pat}*.dll "$release_root/bin/" 2>/dev/null || true
        done
    fi
fi

# --- shared release tail ----------------------------------------------------
ec_finalize_release "$SRC_DIR" "$release_root" "$CANDIDATE_JSON"
tarball="verilator-${plat}-${EC_VERSION}.tar.gz"
ec_make_tarball "$release_root" "$tarball"
ec_log "build complete: $tarball"
