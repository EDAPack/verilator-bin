#!/bin/bash
# Verifies that the UVM DPI layer we ship in share/uvm compiles and works.
#
# This is the guard against silently regressing to +define+UVM_NO_DPI: if the
# overlay stops being installed (eg upstream moves test_regress/t/uvm), the
# link fails here rather than in a user's UVM testbench months later.

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/uvm_dpi_work"

echo "=== Verilator UVM DPI Test ==="

VERILATOR_CMD="verilator"
if ! command -v verilator >/dev/null 2>&1; then
    if command -v verilator.exe >/dev/null 2>&1; then
        VERILATOR_CMD="verilator.exe"
    else
        echo "ERROR: verilator not found in PATH"
        echo "PATH: $PATH"
        exit 1
    fi
fi

# Locate share/uvm relative to the verilator on PATH, checking the same two
# candidates dv-flow-libhdlsim checks.
VERILATOR_BIN=$(command -v "${VERILATOR_CMD}")
VERILATOR_ROOT_DIR=$(cd "$(dirname "${VERILATOR_BIN}")/.." && pwd)

UVM_HOME=""
for sub in share/uvm share/verilator/uvm; do
    if test -d "${VERILATOR_ROOT_DIR}/${sub}"; then
        UVM_HOME="${VERILATOR_ROOT_DIR}/${sub}"
        break
    fi
done

if test -z "${UVM_HOME}"; then
    echo "ERROR: no UVM installation found under ${VERILATOR_ROOT_DIR}"
    exit 1
fi

echo "UVM_HOME: ${UVM_HOME}"

# The overlay must be present, and must carry its provenance record.
if test ! -f "${UVM_HOME}/src/dpi/uvm_hdl_verilator.c"; then
    echo "ERROR: ${UVM_HOME}/src/dpi/uvm_hdl_verilator.c is missing."
    echo "       The Verilator UVM DPI overlay was not installed; UVM would"
    echo "       fall back to glob-only regex matching."
    exit 1
fi

PROVENANCE="${UVM_HOME}/src/dpi/VERILATOR_DPI_PROVENANCE.txt"
if test ! -s "${PROVENANCE}"; then
    echo "ERROR: ${PROVENANCE} is missing or empty (half-applied overlay?)"
    exit 1
fi
echo "--- DPI provenance ---"
cat "${PROVENANCE}"
echo "----------------------"

echo "Cleaning work directory..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

# --vpi is mandatory: uvm_dpi.cc compiles uvm_hdl_verilator.c and
# uvm_svcmd_dpi.c into one translation unit, and both call into VPI.
# Note there is deliberately no +define+UVM_NO_DPI here.
echo "Compiling UVM DPI testcase..."
$VERILATOR_CMD --binary --vpi --timing -Wno-fatal -j 0 -o simv \
    "+incdir+${UVM_HOME}/src" \
    "${UVM_HOME}/src/uvm_pkg.sv" \
    "${UVM_HOME}/src/dpi/uvm_dpi.cc" \
    "${SCRIPT_DIR}/uvm_dpi_smoke.sv" \
    --top-module t

SIMV="obj_dir/simv"
if test ! -f "$SIMV" && test -f "obj_dir/simv.exe"; then
    SIMV="obj_dir/simv.exe"
fi
if test ! -f "$SIMV"; then
    echo "ERROR: simulation binary was not created"
    exit 1
fi

echo "Running simulation..."
if command -v timeout >/dev/null 2>&1; then
    timeout 60s "$SIMV" > output.log 2>&1 || {
        EXIT_CODE=$?
        if test $EXIT_CODE -eq 124; then
            echo "ERROR: Simulation timed out after 60 seconds"
            exit 1
        fi
    }
else
    "$SIMV" > output.log 2>&1
fi

echo "Checking output..."
if grep -q "UVM DPI SMOKE PASSED" output.log; then
    cat output.log
    cd "${SCRIPT_DIR}"
    rm -rf "${WORK_DIR}"
    echo "=== UVM DPI Test PASSED ==="
    exit 0
else
    echo "ERROR: 'UVM DPI SMOKE PASSED' not found in output"
    echo "Output was:"
    cat output.log
    exit 1
fi
