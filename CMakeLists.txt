cmake_minimum_required(VERSION 3.15)
project(verilator-bin)

include(ExternalProject)
include(ProcessorCount)
ProcessorCount(NPROC)

# Check CMake version for DOWNLOAD_EXTRACT_TIMESTAMP support (added in 3.24)
if(CMAKE_VERSION VERSION_GREATER_EQUAL "3.24")
  set(EXTRACT_TIMESTAMP_ARG DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
else()
  set(EXTRACT_TIMESTAMP_ARG "")
endif()

# Options to control build behavior
option(USE_LATEST_BRANCH "Use latest main branch instead of tagged release" ON)
set(VERILATOR_TAG "" CACHE STRING "Specific Verilator tag to use (overrides USE_LATEST_BRANCH)")
set(Z3_TAG "" CACHE STRING "Specific Z3 tag to use (overrides USE_LATEST_BRANCH)")

# Set install prefix if not specified
if(CMAKE_INSTALL_PREFIX_INITIALIZED_TO_DEFAULT)
  set(CMAKE_INSTALL_PREFIX "${CMAKE_BINARY_DIR}/install" CACHE PATH "Installation directory" FORCE)
endif()

# Detect Windows/MSYS2/Cygwin environment
set(IS_MINGW FALSE)
set(IS_CYGWIN FALSE)
set(IS_WINDOWS FALSE)

if(WIN32 OR MSYS OR CYGWIN)
  set(IS_WINDOWS TRUE)
  # Find bash for running configure scripts on Windows
  find_program(BASH_EXECUTABLE bash REQUIRED)
  message(STATUS "Using bash: ${BASH_EXECUTABLE}")
  
  # Detect if we're in MinGW or Cygwin
  execute_process(
    COMMAND ${BASH_EXECUTABLE} -c "uname -s"
    OUTPUT_VARIABLE UNAME_OUTPUT
    OUTPUT_STRIP_TRAILING_WHITESPACE
  )
  
  if(UNAME_OUTPUT MATCHES "MINGW" OR UNAME_OUTPUT MATCHES "MSYS")
    set(IS_MINGW TRUE)
    message(STATUS "Detected MinGW/MSYS environment")
  elseif(UNAME_OUTPUT MATCHES "CYGWIN")
    set(IS_CYGWIN TRUE)
    message(STATUS "Detected Cygwin environment")
  endif()
endif()

# Z3 (Verilator's bundled SMT solver, for constrained randomize()) is not
# built on MinGW: the Windows build exists to test pyhdl-if, which needs no
# constraint solving. Without it Verilator falls back to a solver found on
# PATH at run time. See docs/design/windows.md (D9).
#
# Z3 is Verilator's preferred solver: its configure picks `z3 --in` first when
# it probes for one. Verilator runs the solver as a separate process, so only
# the `z3` executable is shipped (in bin/, beside verilator); libz3, its
# headers and the language bindings are not.
if(IS_MINGW)
  set(_with_z3_default OFF)
else()
  set(_with_z3_default ON)
endif()
option(WITH_Z3 "Build Z3 and configure Verilator with it" ${_with_z3_default})
if(WITH_Z3)
  # One argument with a space in it. The _SH form is for the bash -c strings.
  set(VERILATOR_SOLVER_ARG "--with-solver=z3 --in")
  set(VERILATOR_SOLVER_SH "'--with-solver=z3 --in'")
  set(VERILATOR_DEPENDS_ARG DEPENDS z3)
else()
  set(VERILATOR_SOLVER_ARG "")
  set(VERILATOR_SOLVER_SH "")
  set(VERILATOR_DEPENDS_ARG "")
endif()
message(STATUS "WITH_Z3: ${WITH_Z3}")

# Determine Z3 version/branch
if(Z3_TAG)
  set(Z3_GIT_TAG ${Z3_TAG})
elseif(USE_LATEST_BRANCH)
  set(Z3_GIT_TAG "master")
else()
  set(Z3_GIT_TAG "z3-4.15.4")
endif()

# Determine Verilator version/branch
if(VERILATOR_TAG)
  set(VERILATOR_GIT_TAG ${VERILATOR_TAG})
elseif(USE_LATEST_BRANCH)
  set(VERILATOR_GIT_TAG "master")
else()
  # Will be set to latest release tag via environment variable or default
  set(VERILATOR_GIT_TAG "v5.030")
endif()

message(STATUS "Building with Z3: ${Z3_GIT_TAG}")
message(STATUS "Building with Verilator: ${VERILATOR_GIT_TAG}")

if(WITH_Z3)
# Build only Z3's `shell` target (the z3 executable). It links Z3's object
# libraries in directly, so it has no libz3 dependency, and needs no GMP.
ExternalProject_Add(z3
  GIT_REPOSITORY https://github.com/Z3Prover/z3.git
  GIT_TAG ${Z3_GIT_TAG}
  CMAKE_ARGS
    -DCMAKE_BUILD_TYPE=Release
    -DZ3_BUILD_EXECUTABLE=ON
    -DZ3_BUILD_LIBZ3_SHARED=OFF
    -DZ3_BUILD_TEST_EXECUTABLES=OFF
    -DZ3_ENABLE_EXAMPLE_TARGETS=OFF
    -DZ3_BUILD_PYTHON_BINDINGS=OFF
    -DZ3_BUILD_DOCUMENTATION=OFF
  BUILD_COMMAND ${CMAKE_COMMAND} --build <BINARY_DIR> --target shell -j${NPROC}
  INSTALL_COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_INSTALL_PREFIX}/bin
    COMMAND ${CMAKE_COMMAND} -E copy <BINARY_DIR>/z3${CMAKE_EXECUTABLE_SUFFIX} ${CMAKE_INSTALL_PREFIX}/bin/
)
endif() # WITH_Z3

# Build Verilator
if(IS_MINGW)
  # MinGW-specific build
  #
  # CXXFLAGS=-std=gnu++17 for the same reason as the Unix branch below.
  #
  # LDFLAGS=-static links libstdc++/libgcc/winpthread into verilator_bin.exe,
  # so bin/ ships no runtime DLLs. A bundled libstdc++-6.dll on PATH would be
  # loaded by the user's own simv.exe in place of their toolchain's, and fail
  # with "entry point not found". Both go on the build, not configure (see the
  # Unix branch): src/Makefile_obj.in appends to the environment values.
  ExternalProject_Add(verilator
    ${VERILATOR_DEPENDS_ARG}
    GIT_REPOSITORY https://github.com/verilator/verilator.git
    GIT_TAG ${VERILATOR_GIT_TAG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && autoconf && ./configure --prefix=${CMAKE_INSTALL_PREFIX} ${VERILATOR_SOLVER_SH}"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && CXXFLAGS=-std=gnu++17 LDFLAGS=-static make -j${NPROC}"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make install"
    BUILD_IN_SOURCE 1
  )
elseif(IS_CYGWIN)
  # Cygwin-specific build
  # Note: Cygwin has issues with jobserver semaphores when make is nested
  # Use single-threaded make to avoid "invalid --jobserver-auth" errors
  ExternalProject_Add(verilator
    ${VERILATOR_DEPENDS_ARG}
    GIT_REPOSITORY https://github.com/verilator/verilator.git
    GIT_TAG ${VERILATOR_GIT_TAG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && autoconf && ./configure --prefix=${CMAKE_INSTALL_PREFIX} ${VERILATOR_SOLVER_SH}"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make install"
    BUILD_IN_SOURCE 1
  )
else()
  # Unix/Linux/macOS build
  #
  # CXXFLAGS=-std=gnu++17 at build time: Verilator's configure only injects a
  # -std= flag when the compiler cannot do C++14 by default, so on
  # manylinux2014 (el7 / devtoolset-10, gcc 10, default gnu++14) Verilator's
  # own sources build as C++14 while every newer image gets gnu++17 for free.
  # Master then fails to link -- eg V3AssertNfa.cpp odr-uses `static constexpr
  # int kDepthUnreachable`, which needs an out-of-line definition before C++17.
  # gnu++17 is the newest standard Verilator regularly tests, and is already
  # what every other compiler we build with ends up using, so this only changes
  # manylinux2014.
  #
  # It must go on the build, not on configure: that -std= probe keys off
  # whether CXXFLAGS already suffices, and its answer also decides
  # CFG_CXXFLAGS_STD, which is what include/verilated.mk.in passes to generated
  # models. Setting CXXFLAGS for configure makes the probe succeed, blanking
  # CFG_CXXFLAGS_STD and leaving macOS models with no -std= at all. Passing it
  # via the environment at build time instead leaves configure untouched:
  # src/Makefile_obj.in does `CXXFLAGS += @CXXFLAGS@`, which appends to the
  # environment value rather than replacing it, and only Verilator's own
  # sources are compiled here.
  ExternalProject_Add(verilator
    ${VERILATOR_DEPENDS_ARG}
    GIT_REPOSITORY https://github.com/verilator/verilator.git
    GIT_TAG ${VERILATOR_GIT_TAG}
    CONFIGURE_COMMAND autoconf COMMAND <SOURCE_DIR>/configure --prefix=${CMAKE_INSTALL_PREFIX} ${VERILATOR_SOLVER_ARG}
    BUILD_COMMAND ${CMAKE_COMMAND} -E env CXXFLAGS=-std=gnu++17 make -j${NPROC}
    INSTALL_COMMAND make install
    BUILD_IN_SOURCE 1
  )
endif()

# Fetch and install UVM
#
# 1800.2-2020.3.2 (2026-08-10) is the first Accellera release to ship the
# Verilator backend for uvm_hdl_* itself, which is why we are on it: before it,
# verilator-bin had to overlay Verilator's test_regress copy to make uvm_dpi.cc
# compile at all. See docs/design/uvm-dpi.md.
#
# Accellera's download URLs are not uniformly named -- older releases are
# 'Accellera-<version>.tar.gz', 2020.3.2 is '<version>%20Release.gz' -- so the
# URL is its own variable rather than being derived from the version.
set(UVM_VERSION "1800.2-2020.3.2" CACHE STRING "Accellera UVM version to ship")
set(UVM_URL "https://www.accellera.org/images/downloads/standards/uvm/1800.2-2020.3.2%20Release.gz"
    CACHE STRING "Download URL for the Accellera UVM release named by UVM_VERSION")

ExternalProject_Add(uvm
  URL ${UVM_URL}
  # The 2020.3.2 asset is a tarball served with a bare '.gz' name; give it a
  # name CMake will recognize as one so it is extracted rather than just
  # decompressed.
  DOWNLOAD_NAME uvm-${UVM_VERSION}.tar.gz
  ${EXTRACT_TIMESTAMP_ARG}
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_INSTALL_PREFIX}/share/uvm
    COMMAND ${CMAKE_COMMAND} -E copy_directory <SOURCE_DIR>/src ${CMAKE_INSTALL_PREFIX}/share/uvm/src
)

# Prepare the installed UVM tree's DPI layer for Verilator: assert the backend
# is present, apply the macOS <malloc.h> fix, and write the provenance file.
#
# This used to overlay Verilator's own copy of the DPI sources; as of 2020.3.2
# Verilator's copy is byte-identical to Accellera's apart from the release
# stamp, so there is nothing left to overlay -- only to check and record.
ExternalProject_Add(uvm-dpi
  DEPENDS uvm
  DOWNLOAD_COMMAND ""
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/prepare-uvm-dpi.sh
          ${CMAKE_INSTALL_PREFIX}
          ${UVM_VERSION}
          ${UVM_URL}
)

# Post-install cleanup and modifications
if(IS_WINDOWS)
  ExternalProject_Add(post-install
    DEPENDS verilator uvm uvm-dpi
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND 
      ${CMAKE_COMMAND} -E echo "Running post-install cleanup..."
      COMMAND ${BASH_EXECUTABLE} -c "test -f ${CMAKE_INSTALL_PREFIX}/bin/verilator_bin && strip ${CMAKE_INSTALL_PREFIX}/bin/* 2>/dev/null || true"
      COMMAND ${BASH_EXECUTABLE} -c "test -d ${CMAKE_INSTALL_PREFIX}/share/verilator/bin && strip ${CMAKE_INSTALL_PREFIX}/share/verilator/bin/* 2>/dev/null || true"
      COMMAND ${BASH_EXECUTABLE} -c "rm -f ${CMAKE_INSTALL_PREFIX}/share/verilator/bin/*_dbg 2>/dev/null || true"
      # PYTHON3 ?= (not =): models run verilator_includer with it, and on a stock
      # Windows machine `python3` may be the Microsoft Store stub. `?=` lets a
      # PYTHON3 environment variable name the interpreter (docs/windows.md).
      COMMAND ${BASH_EXECUTABLE} -c "sed -i 's%^PYTHON3 =.*$%PYTHON3 ?= python3%' ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk && grep -q '^PYTHON3 ?= python3' ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk"
      # Models default to gnu++17. MSYS2's GCC 16.2 defaults to gnu++20, and at
      # -Os (which verilated.mk uses for the runtime) leaves the std::string
      # move constructor undefined at link time -- even for a trivial program,
      # and with MSYS2's own verilator package too. gnu++17 links. Verilator's
      # configure leaves CFG_CXXFLAGS_STD empty when the compiler's default
      # already suffices, so pin it here. A user -CFLAGS -std= still wins.
      COMMAND ${BASH_EXECUTABLE} -c "sed -i 's%^CFG_CXXFLAGS_STD =.*$%CFG_CXXFLAGS_STD = -std=gnu++17%' ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk && grep -q '^CFG_CXXFLAGS_STD = -std=gnu++17' ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk"
      # A copy, not a symlink: a symlink does not survive extraction on a
      # Windows machine without symlink privilege.
      COMMAND ${CMAKE_COMMAND} -E echo "Creating include copy for Windows Verilator compatibility..."
      COMMAND ${BASH_EXECUTABLE} -c "cd ${CMAKE_INSTALL_PREFIX} && rm -rf include && cp -r share/verilator/include include"
      # verilator.cmd lets cmd, PowerShell and native Python (shutil.which,
      # subprocess) run the extensionless Perl `verilator` script.
      COMMAND ${BASH_EXECUTABLE} -c "cp -f ${CMAKE_SOURCE_DIR}/scripts/verilator.cmd ${CMAKE_INSTALL_PREFIX}/bin/verilator.cmd"
      COMMAND ${CMAKE_COMMAND} -E echo "Copying Verilator helper scripts to bin directory..."
      COMMAND ${BASH_EXECUTABLE} -c "cd ${CMAKE_INSTALL_PREFIX}/bin && cp -f ../share/verilator/bin/verilator_includer ../share/verilator/bin/verilator_ccache_report . 2>/dev/null || true"
  )
  
  # Add smoke test to validate the installation
  # On Windows with MSYS/MinGW, convert Windows path to Unix format to avoid : being treated as separator
  ExternalProject_Add(smoke-test
    DEPENDS post-install
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd ${CMAKE_SOURCE_DIR}/tests && PATH=$(${BASH_EXECUTABLE} -c 'cd ${CMAKE_INSTALL_PREFIX}/bin && pwd'):$PATH ./run_smoke_test.sh"
  )

  # The UVM DPI tests are not run on MinGW/Cygwin: uvm_dpi.h requires POSIX
  # <regex.h>, which mingw-w64 does not ship. The DPI sources are still
  # installed (they are just sources), so nothing is lost by shipping them.
  message(STATUS "Skipping UVM DPI tests on Windows (no POSIX regex.h)")
else()
  ExternalProject_Add(post-install
    DEPENDS verilator uvm uvm-dpi
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND
      ${CMAKE_COMMAND} -E echo "Running post-install cleanup..."
      COMMAND bash ${CMAKE_SOURCE_DIR}/scripts/linux-post-install.sh
              ${CMAKE_INSTALL_PREFIX} ${CMAKE_BINARY_DIR}
  )
  
  # Add smoke test to validate the installation
  ExternalProject_Add(smoke-test
    DEPENDS post-install
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND bash -c "export PATH=${CMAKE_INSTALL_PREFIX}/bin:$PATH && ${CMAKE_SOURCE_DIR}/tests/run_smoke_test.sh"
  )

  # Validate constrained randomize() through the bundled z3.
  if(WITH_Z3)
    ExternalProject_Add(solver-test
      DEPENDS post-install
      DOWNLOAD_COMMAND ""
      CONFIGURE_COMMAND ""
      BUILD_COMMAND ""
      INSTALL_COMMAND bash -c "export PATH=${CMAKE_INSTALL_PREFIX}/bin:$PATH && ${CMAKE_SOURCE_DIR}/tests/solver/run_solver_test.sh"
    )
  endif()

  # Validate that the shipped UVM's DPI layer actually compiles and works
  # under Verilator. Guards against silently regressing to +define+UVM_NO_DPI,
  # which downgrades UVM's uvm_re_match to glob-only matching.
  ExternalProject_Add(uvm-dpi-test
    DEPENDS post-install
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND bash -c "export PATH=${CMAKE_INSTALL_PREFIX}/bin:$PATH && ${CMAKE_SOURCE_DIR}/tests/uvm_dpi/run_uvm_dpi_test.sh"
  )

  # Validate the same thing through dv-flow-mgr / dv-flow-libhdlsim, ie the
  # way the package is actually consumed. Covers UVM discovery from the
  # installed layout and SimLibUVM's DPI wiring, not just raw verilator.
  # Set VERILATOR_BIN_SKIP_DFM_TEST=1 for an offline build.
  ExternalProject_Add(uvm-dpi-dfm-test
    DEPENDS uvm-dpi-test
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND bash -c "export PATH=${CMAKE_INSTALL_PREFIX}/bin:$PATH && ${CMAKE_SOURCE_DIR}/tests/uvm_dpi_dfm/run_dfm_test.sh"
  )
endif()
