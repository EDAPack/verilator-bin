#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/smoke_test_work"

echo "=== Verilator Smoke Test ==="
echo "Compiling smoke.sv with Verilator..."

# Find verilator - check both with and without .exe extension
VERILATOR_CMD="verilator"
if ! command -v verilator >/dev/null 2>&1; then
    if command -v verilator.exe >/dev/null 2>&1; then
        VERILATOR_CMD="verilator.exe"
    else
        echo "ERROR: verilator not found in PATH"
        echo "PATH: $PATH"
        echo "Checking for verilator in PATH directories:"
        IFS=':' read -ra PATHARRAY <<< "$PATH"
        for dir in "${PATHARRAY[@]}"; do
            if [ -d "$dir" ]; then
                echo "  $dir:"
                ls -la "$dir" 2>/dev/null | grep -i veril || echo "    (no verilator found)"
            fi
        done
        exit 1
    fi
fi

$VERILATOR_CMD --version

echo "Cleaning work directory..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

$VERILATOR_CMD --binary "${SCRIPT_DIR}/smoke.sv" -o simv

if [ ! -f "obj_dir/simv" ] && [ ! -f "obj_dir/simv.exe" ]; then
    echo "ERROR: Binary obj_dir/simv was not created"
    exit 1
fi

# Find the simulation binary (with or without .exe extension)
SIMV="obj_dir/simv"
if [ ! -f "$SIMV" ] && [ -f "obj_dir/simv.exe" ]; then
    SIMV="obj_dir/simv.exe"
fi

echo "Running simulation..."
# Use timeout if available, otherwise run directly (simulations should exit quickly)
if command -v timeout >/dev/null 2>&1; then
    timeout 5s "$SIMV" > output.log 2>&1 || {
        EXIT_CODE=$?
        if [ $EXIT_CODE -eq 124 ]; then
            echo "ERROR: Simulation timed out after 5 seconds"
            exit 1
        fi
    }
else
    # No timeout available (e.g., macOS), run directly
    "$SIMV" > output.log 2>&1
fi

echo "Checking output..."
if grep -q "Hello World" output.log; then
    echo "✓ SUCCESS: Found 'Hello World' in output"
    cat output.log
    cd "${SCRIPT_DIR}"
    rm -rf "${WORK_DIR}"
    echo "=== Smoke Test PASSED ==="
    exit 0
else
    echo "ERROR: 'Hello World' not found in output"
    echo "Output was:"
    cat output.log
    exit 1
fi
