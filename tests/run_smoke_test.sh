#!/bin/bash

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/smoke_test_work"

echo "=== Verilator Smoke Test ==="
echo "Cleaning work directory..."
rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

echo "Compiling smoke.sv with Verilator..."
verilator --version
verilator --binary "${SCRIPT_DIR}/smoke.sv" -o simv

if [ ! -f "obj_dir/simv" ]; then
    echo "ERROR: Binary obj_dir/simv was not created"
    exit 1
fi

echo "Running simulation..."
timeout 5s obj_dir/simv > output.log 2>&1 || {
    EXIT_CODE=$?
    if [ $EXIT_CODE -eq 124 ]; then
        echo "ERROR: Simulation timed out after 5 seconds"
        exit 1
    fi
}

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
