#!/bin/sh -x

root=$(pwd)

#********************************************************************
#* Install required packages
#********************************************************************
if test $(uname -s) = "Linux"; then
    yum update -y
    # Install perl-core for complete Perl installation including FindBin module
    # which is required by Verilator wrapper scripts
    yum install -y glibc-static wget flex bison jq help2man \
        cmake3 autoconf make gcc gcc-c++ git perl-core

    if test -z $image; then
        image=linux
    fi
    export PATH=/opt/python/cp312-cp312/bin:$PATH
    
    # Install meson and ninja for bitwuzla build
    pip3 install meson ninja
    
    # Create cmake symlink if cmake3 exists
    if test -f /usr/bin/cmake3 && test ! -f /usr/bin/cmake; then
        ln -s /usr/bin/cmake3 /usr/bin/cmake
    fi
    
    rls_plat=${image}
elif test $(uname -s) = "Darwin"; then
    # macOS - dependencies installed via brew in CI
    if test -z $image; then
        image=macos-$(uname -m)
    fi
    
    # Install meson and ninja for bitwuzla build
    pip3 install meson ninja --break-system-packages || pip3 install meson ninja
    
    # Set flag to remove pregen files on macOS to avoid flex compatibility issues
    REMOVE_PREGEN=1
    
    rls_plat=${image}
elif echo $(uname -s) | grep -q "MINGW\|MSYS"; then
    # MinGW environment
    if test -z $image; then
        if test "$(uname -m)" = "x86_64"; then
            image=mingw64
        else
            image=mingw32
        fi
    fi
    
    # Ensure python is available
    which python3 || alias python3=python
    
    rls_plat=${image}
    IS_WINDOWS=1
elif echo $(uname -s) | grep -q "CYGWIN"; then
    # Cygwin environment
    if test -z $image; then
        if test "$(uname -m)" = "x86_64"; then
            image=cygwin64
        else
            image=cygwin32
        fi
    fi
    
    # Install meson and ninja if not present
    pip3 install meson ninja || python3 -m pip install meson ninja
    
    rls_plat=${image}
    IS_WINDOWS=1
fi

#********************************************************************
#* Validate environment variables
#********************************************************************
if test -z $vlt_latest_rls; then
  echo "vlt_latest_rls not set"
  env
  exit 1
fi

if test -z $bwz_latest_rls; then
  echo "bwz_latest_rls not set"
  env
  exit 1
fi

#********************************************************************
#* Calculate version information
#********************************************************************
if test -z ${rls_version}; then
    vlt_version=$(echo $vlt_latest_rls | sed -e 's/^v//')
    rls_version=${vlt_version}

    if test "x${BUILD_NUM}" != "x"; then
        rls_version="${rls_version}.${BUILD_NUM}"
    fi
fi

#********************************************************************
#* Build using CMake
#********************************************************************
cd ${root}

# Create build directory
rm -rf build
mkdir -p build
cd build

# Configure CMake with version information from GitHub workflow
# When vlt_latest_rls is "master", use USE_LATEST_BRANCH=ON for top-of-trunk builds
if test "${vlt_latest_rls}" = "master"; then
  cmake .. \
    -DUSE_LATEST_BRANCH=ON \
    -DBITWUZLA_TAG=${bwz_latest_rls} \
    -DCMAKE_INSTALL_PREFIX=${root}/release/verilator
else
  cmake .. \
    -DUSE_LATEST_BRANCH=OFF \
    -DVERILATOR_TAG=${vlt_latest_rls} \
    -DBITWUZLA_TAG=${bwz_latest_rls} \
    -DCMAKE_INSTALL_PREFIX=${root}/release/verilator
fi

if test $? -ne 0; then exit 1; fi

# On macOS, remove pregen lex files to force regeneration with homebrew flex
# This avoids compatibility issues with the system FlexLexer.h
if test "x${REMOVE_PREGEN}" = "x1"; then
    echo "Removing pregen lex files for macOS compatibility..."
    find . -name "*_pregen*" -delete 2>/dev/null || true
fi

# Build
cmake --build . -j$(nproc)
if test $? -ne 0; then exit 1; fi

#********************************************************************
#* Create release tarball
#********************************************************************
cd ${root}/release

# For Windows builds, we need to include the runtime libraries
if test "x${IS_WINDOWS}" = "x1"; then
    echo "Creating Windows release package with runtime libraries..."
    
    # Copy required DLLs for MinGW/Cygwin
    if echo $(uname -s) | grep -q "MINGW\|MSYS"; then
        # MinGW: Copy MinGW runtime DLLs
        mkdir -p verilator/bin
        cp -v /mingw*/bin/libgcc_s_*.dll verilator/bin/ 2>/dev/null || true
        cp -v /mingw*/bin/libstdc++-*.dll verilator/bin/ 2>/dev/null || true
        cp -v /mingw*/bin/libwinpthread-*.dll verilator/bin/ 2>/dev/null || true
        cp -v /mingw*/bin/libgmp-*.dll verilator/bin/ 2>/dev/null || true
        cp -v /mingw*/bin/libmpfr-*.dll verilator/bin/ 2>/dev/null || true
    elif echo $(uname -s) | grep -q "CYGWIN"; then
        # Cygwin: Dependencies are in /usr/bin
        mkdir -p verilator/bin
        cp -v /usr/bin/cyggcc_s-*.dll verilator/bin/ 2>/dev/null || true
        cp -v /usr/bin/cygstdc++-*.dll verilator/bin/ 2>/dev/null || true
        cp -v /usr/bin/cygwin1.dll verilator/bin/ 2>/dev/null || true
        cp -v /usr/bin/cyggmp-*.dll verilator/bin/ 2>/dev/null || true
        cp -v /usr/bin/cygmpfr-*.dll verilator/bin/ 2>/dev/null || true
    fi
fi

tar czf verilator-${rls_plat}-${rls_version}.tar.gz verilator
if test $? -ne 0; then exit 1; fi

echo "Build complete: verilator-${rls_plat}-${rls_version}.tar.gz"

