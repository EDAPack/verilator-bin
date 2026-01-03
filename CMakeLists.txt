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
set(BITWUZLA_TAG "" CACHE STRING "Specific Bitwuzla tag to use (overrides USE_LATEST_BRANCH)")

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

# Determine Bitwuzla version/branch
if(BITWUZLA_TAG)
  set(BITWUZLA_GIT_TAG ${BITWUZLA_TAG})
elseif(USE_LATEST_BRANCH)
  set(BITWUZLA_GIT_TAG "main")
else()
  # Will be set to latest release tag via environment variable or default
  set(BITWUZLA_GIT_TAG "0.6.0")
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

message(STATUS "Building with Bitwuzla: ${BITWUZLA_GIT_TAG}")
message(STATUS "Building with Verilator: ${VERILATOR_GIT_TAG}")

# Create a Python virtual environment for meson/ninja
if(IS_WINDOWS)
  ExternalProject_Add(python-venv
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "python3 -m venv <BINARY_DIR>/venv || python -m venv <BINARY_DIR>/venv"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "<BINARY_DIR>/venv/bin/pip install meson ninja || <BINARY_DIR>/venv/Scripts/pip install meson ninja"
    INSTALL_COMMAND ""
    BUILD_IN_SOURCE 1
  )
else()
  ExternalProject_Add(python-venv
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND python3 -m venv <BINARY_DIR>/venv
    BUILD_COMMAND <BINARY_DIR>/venv/bin/pip install meson ninja
    INSTALL_COMMAND ""
    BUILD_IN_SOURCE 1
  )
endif()

# Build GMP (required by MPFR and Bitwuzla)
# Use local cached copy to avoid network issues
# Build both static and shared libraries so meson can find them
if(IS_MINGW)
  # MinGW-specific: Use system-installed GMP from MSYS2 packages
  # Building GMP from source on MinGW has long-standing reliability test issues
  # We already install mingw-w64-*-gmp in the workflow
  ExternalProject_Add(gmp
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND ${CMAKE_COMMAND} -E echo "Using system GMP from MSYS2"
  )
elseif(IS_CYGWIN)
  # Cygwin-specific build
  # Note: Cygwin has issues with jobserver semaphores when make is nested
  # Use single-threaded make to avoid "invalid --jobserver-auth" errors
  ExternalProject_Add(gmp
    URL ${CMAKE_SOURCE_DIR}/deps/gmp-6.3.0.tar.xz
    URL_HASH SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
    ${EXTRACT_TIMESTAMP_ARG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && ./configure --prefix=${CMAKE_INSTALL_PREFIX} --enable-cxx"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make install"
    BUILD_IN_SOURCE 1
  )
else()
  # Unix/Linux/macOS build
  ExternalProject_Add(gmp
    URL ${CMAKE_SOURCE_DIR}/deps/gmp-6.3.0.tar.xz
    URL_HASH SHA256=a3c2b80201b89e68616f4ad30bc66aee4927c3ce50e33929ca819d5c43538898
    ${EXTRACT_TIMESTAMP_ARG}
    CONFIGURE_COMMAND <SOURCE_DIR>/configure --prefix=${CMAKE_INSTALL_PREFIX} --enable-cxx
    BUILD_COMMAND make -j${NPROC}
    INSTALL_COMMAND make install
    BUILD_IN_SOURCE 1
  )
endif()

# Build MPFR (required by Bitwuzla, depends on GMP)
# Use local cached copy to avoid network issues
# Build both static and shared libraries so meson can find them
if(IS_MINGW)
  # MinGW-specific: Use system-installed MPFR from MSYS2 packages  
  # We already install mingw-w64-*-mpfr in the workflow
  ExternalProject_Add(mpfr
    DEPENDS gmp
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND ${CMAKE_COMMAND} -E echo "Using system MPFR from MSYS2"
  )
elseif(IS_CYGWIN)
  # Cygwin-specific build
  # Note: Cygwin has issues with jobserver semaphores when make is nested
  # Use single-threaded make to avoid "invalid --jobserver-auth" errors
  ExternalProject_Add(mpfr
    DEPENDS gmp
    URL ${CMAKE_SOURCE_DIR}/deps/mpfr-4.2.2.tar.xz
    URL_HASH SHA256=b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01
    ${EXTRACT_TIMESTAMP_ARG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && ./configure --prefix=${CMAKE_INSTALL_PREFIX} --with-gmp=${CMAKE_INSTALL_PREFIX}"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make install"
    BUILD_IN_SOURCE 1
  )
else()
  # Unix/Linux/macOS build
  ExternalProject_Add(mpfr
    DEPENDS gmp
    URL ${CMAKE_SOURCE_DIR}/deps/mpfr-4.2.2.tar.xz
    URL_HASH SHA256=b67ba0383ef7e8a8563734e2e889ef5ec3c3b898a01d00fa0a6869ad81c6ce01
    ${EXTRACT_TIMESTAMP_ARG}
    CONFIGURE_COMMAND <SOURCE_DIR>/configure --prefix=${CMAKE_INSTALL_PREFIX} --with-gmp=${CMAKE_INSTALL_PREFIX}
    BUILD_COMMAND make -j${NPROC}
    INSTALL_COMMAND make install
    BUILD_IN_SOURCE 1
  )
endif()

# Build Bitwuzla
# Use meson directly with --wrap-mode=nofallback to prevent fallback to wrap for GMP/MPFR
# Pass pkg-config-path and native-file for proper library detection on macOS
if(IS_MINGW)
  # MinGW-specific: Use shared libraries and system GMP/MPFR
  # GMP and MPFR are already installed from MSYS2 packages in /mingw64
  ExternalProject_Add(bitwuzla
    DEPENDS python-venv gmp mpfr
    GIT_REPOSITORY https://github.com/bitwuzla/bitwuzla.git
    GIT_TAG ${BITWUZLA_GIT_TAG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "export PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:${CMAKE_BINARY_DIR}/python-venv-prefix/venv/Scripts:$PATH && meson setup <SOURCE_DIR>/build <SOURCE_DIR> --prefix=${CMAKE_INSTALL_PREFIX} -Dfpexp=false --default-library=shared"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR>/build && export PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:${CMAKE_BINARY_DIR}/python-venv-prefix/venv/Scripts:$PATH && meson compile"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR>/build && export PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:${CMAKE_BINARY_DIR}/python-venv-prefix/venv/Scripts:$PATH && meson install"
    BUILD_IN_SOURCE 1
  )
elseif(IS_CYGWIN)
  # Cygwin-specific build
  ExternalProject_Add(bitwuzla
    DEPENDS python-venv gmp mpfr
    GIT_REPOSITORY https://github.com/bitwuzla/bitwuzla.git
    GIT_TAG ${BITWUZLA_GIT_TAG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "export PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:$PATH && export PKG_CONFIG_PATH=${CMAKE_INSTALL_PREFIX}/lib/pkgconfig:$PKG_CONFIG_PATH && meson setup <SOURCE_DIR>/build <SOURCE_DIR> --prefix=${CMAKE_INSTALL_PREFIX} -Dfpexp=false --default-library=shared --pkg-config-path=${CMAKE_INSTALL_PREFIX}/lib/pkgconfig"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR>/build && export PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:$PATH && meson compile"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR>/build && export PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:$PATH && meson install"
    BUILD_IN_SOURCE 1
  )
else()
  # Unix/Linux/macOS build
  ExternalProject_Add(bitwuzla
    DEPENDS python-venv gmp mpfr
    GIT_REPOSITORY https://github.com/bitwuzla/bitwuzla.git
    GIT_TAG ${BITWUZLA_GIT_TAG}
    CONFIGURE_COMMAND ${CMAKE_COMMAND} -E env 
      PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:$ENV{PATH}
      PKG_CONFIG_PATH=${CMAKE_INSTALL_PREFIX}/lib/pkgconfig:$ENV{PKG_CONFIG_PATH}
      LD_LIBRARY_PATH=${CMAKE_INSTALL_PREFIX}/lib:$ENV{LD_LIBRARY_PATH}
      DYLD_LIBRARY_PATH=${CMAKE_INSTALL_PREFIX}/lib:$ENV{DYLD_LIBRARY_PATH}
      LIBRARY_PATH=${CMAKE_INSTALL_PREFIX}/lib:$ENV{LIBRARY_PATH}
      meson setup <SOURCE_DIR>/build <SOURCE_DIR> 
        --prefix=${CMAKE_INSTALL_PREFIX} 
        -Dfpexp=false 
        --default-library=shared
        --pkg-config-path=${CMAKE_INSTALL_PREFIX}/lib/pkgconfig
        -Dc_args=-I${CMAKE_INSTALL_PREFIX}/include
        -Dcpp_args=-I${CMAKE_INSTALL_PREFIX}/include
        -Dc_link_args=-L${CMAKE_INSTALL_PREFIX}/lib
        -Dcpp_link_args=-L${CMAKE_INSTALL_PREFIX}/lib
    BUILD_COMMAND ${CMAKE_COMMAND} -E chdir <SOURCE_DIR>/build ${CMAKE_COMMAND} -E env 
      PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:$ENV{PATH}
      LD_LIBRARY_PATH=${CMAKE_INSTALL_PREFIX}/lib:$ENV{LD_LIBRARY_PATH}
      DYLD_LIBRARY_PATH=${CMAKE_INSTALL_PREFIX}/lib:$ENV{DYLD_LIBRARY_PATH}
      meson compile
    INSTALL_COMMAND ${CMAKE_COMMAND} -E chdir <SOURCE_DIR>/build ${CMAKE_COMMAND} -E env 
      PATH=${CMAKE_BINARY_DIR}/python-venv-prefix/venv/bin:$ENV{PATH}
      LD_LIBRARY_PATH=${CMAKE_INSTALL_PREFIX}/lib:$ENV{LD_LIBRARY_PATH}
      DYLD_LIBRARY_PATH=${CMAKE_INSTALL_PREFIX}/lib:$ENV{DYLD_LIBRARY_PATH}
      meson install
    BUILD_IN_SOURCE 1
  )
endif()

# Build Verilator
if(IS_MINGW)
  # MinGW-specific build  
  ExternalProject_Add(verilator
    DEPENDS bitwuzla
    GIT_REPOSITORY https://github.com/verilator/verilator.git
    GIT_TAG ${VERILATOR_GIT_TAG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && autoconf && ./configure --prefix=${CMAKE_INSTALL_PREFIX} --with-solver=bitwuzla"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make -j${NPROC}"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make install"
    BUILD_IN_SOURCE 1
  )
elseif(IS_CYGWIN)
  # Cygwin-specific build
  # Note: Cygwin has issues with jobserver semaphores when make is nested
  # Use single-threaded make to avoid "invalid --jobserver-auth" errors
  ExternalProject_Add(verilator
    DEPENDS bitwuzla
    GIT_REPOSITORY https://github.com/verilator/verilator.git
    GIT_TAG ${VERILATOR_GIT_TAG}
    CONFIGURE_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && autoconf && ./configure --prefix=${CMAKE_INSTALL_PREFIX} --with-solver=bitwuzla"
    BUILD_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make"
    INSTALL_COMMAND ${BASH_EXECUTABLE} -c "cd <SOURCE_DIR> && make install"
    BUILD_IN_SOURCE 1
  )
else()
  # Unix/Linux/macOS build
  ExternalProject_Add(verilator
    DEPENDS bitwuzla
    GIT_REPOSITORY https://github.com/verilator/verilator.git
    GIT_TAG ${VERILATOR_GIT_TAG}
    CONFIGURE_COMMAND autoconf COMMAND <SOURCE_DIR>/configure --prefix=${CMAKE_INSTALL_PREFIX} --with-solver=bitwuzla
    BUILD_COMMAND make -j${NPROC}
    INSTALL_COMMAND make install
    BUILD_IN_SOURCE 1
  )
endif()

# Fetch and install UVM
ExternalProject_Add(uvm
  URL https://www.accellera.org/images/downloads/standards/uvm/Accellera-1800.2-2017-1.0.tar.gz
  ${EXTRACT_TIMESTAMP_ARG}
  CONFIGURE_COMMAND ""
  BUILD_COMMAND ""
  INSTALL_COMMAND ${CMAKE_COMMAND} -E make_directory ${CMAKE_INSTALL_PREFIX}/share/uvm
    COMMAND ${CMAKE_COMMAND} -E copy_directory <SOURCE_DIR>/src ${CMAKE_INSTALL_PREFIX}/share/uvm/src
)

# Post-install cleanup and modifications
if(IS_WINDOWS)
  ExternalProject_Add(post-install
    DEPENDS verilator uvm
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND 
      ${CMAKE_COMMAND} -E echo "Running post-install cleanup..."
      COMMAND ${BASH_EXECUTABLE} -c "test -f ${CMAKE_INSTALL_PREFIX}/bin/verilator_bin && strip ${CMAKE_INSTALL_PREFIX}/bin/* 2>/dev/null || true"
      COMMAND ${BASH_EXECUTABLE} -c "test -d ${CMAKE_INSTALL_PREFIX}/share/verilator/bin && strip ${CMAKE_INSTALL_PREFIX}/share/verilator/bin/* 2>/dev/null || true"
      COMMAND ${BASH_EXECUTABLE} -c "rm -f ${CMAKE_INSTALL_PREFIX}/share/verilator/bin/*_dbg 2>/dev/null || true"
      COMMAND ${BASH_EXECUTABLE} -c "test -f ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk && sed -i 's%PYTHON3 =.*$%PYTHON3 = python3%g' ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk || true"
      COMMAND ${CMAKE_COMMAND} -E echo "Creating include symlink for Windows Verilator compatibility..."
      COMMAND ${BASH_EXECUTABLE} -c "cd ${CMAKE_INSTALL_PREFIX} && rm -rf include && ln -s share/verilator/include include"
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
else()
  ExternalProject_Add(post-install
    DEPENDS verilator uvm
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND 
      ${CMAKE_COMMAND} -E echo "Running post-install cleanup..."
      COMMAND bash -c "test -f ${CMAKE_INSTALL_PREFIX}/bin/verilator_bin && strip ${CMAKE_INSTALL_PREFIX}/bin/* 2>/dev/null || true"
      COMMAND bash -c "test -d ${CMAKE_INSTALL_PREFIX}/share/verilator/bin && strip ${CMAKE_INSTALL_PREFIX}/share/verilator/bin/* 2>/dev/null || true"
      COMMAND ${CMAKE_COMMAND} -E rm -rf ${CMAKE_INSTALL_PREFIX}/lib
      COMMAND bash -c "rm -f ${CMAKE_INSTALL_PREFIX}/share/verilator/bin/*_dbg 2>/dev/null || true"
      COMMAND bash -c "test -f ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk && sed -i 's%PYTHON3 =.*$%PYTHON3 = python3%g' ${CMAKE_INSTALL_PREFIX}/share/verilator/include/verilated.mk || true"
  )
  
  # Add smoke test to validate the installation
  ExternalProject_Add(smoke-test
    DEPENDS post-install
    DOWNLOAD_COMMAND ""
    CONFIGURE_COMMAND ""
    BUILD_COMMAND ""
    INSTALL_COMMAND bash -c "export PATH=${CMAKE_INSTALL_PREFIX}/bin:$PATH && ${CMAKE_SOURCE_DIR}/tests/run_smoke_test.sh"
  )
endif()
