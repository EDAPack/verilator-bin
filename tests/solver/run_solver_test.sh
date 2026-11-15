#!/bin/bash
# Check that constrained randomize() works through the bundled z3, run the way
# a user runs it: verilator and z3 from the same bin/ on PATH.
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/solver_test_work"

echo "=== Solver Test ==="
VLT="$(command -v verilator)" || { echo "ERROR: verilator not on PATH"; exit 1; }
Z3="$(command -v z3)" || { echo "ERROR: z3 not on PATH"; exit 1; }
if [ "$(dirname "$VLT")" != "$(dirname "$Z3")" ]; then
    echo "ERROR: z3 on PATH ($Z3) is not the bundled one (beside $VLT)"
    exit 1
fi
"$Z3" --version
echo '(declare-const x Int)(assert (> x 3))(check-sat)' | "$Z3" --in | grep -qx sat \
    || { echo "ERROR: z3 --in did not answer sat"; exit 1; }

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"
cd "${WORK_DIR}"

unset VERILATOR_SOLVER
verilator --binary "${SCRIPT_DIR}/rand.sv" -o simv
./obj_dir/simv > output.log 2>&1 || { cat output.log; echo "ERROR: simulation failed"; exit 1; }
cat output.log
grep -q "SOLVER TEST PASSED" output.log || { echo "ERROR: no pass message"; exit 1; }

cd "${SCRIPT_DIR}"
rm -rf "${WORK_DIR}"
echo "=== Solver Test PASSED ==="
