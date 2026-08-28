#!/bin/bash
# Verifies that the shipped UVM sources AND their Verilator DPI layer work
# when consumed through dv-flow-mgr / dv-flow-libhdlsim -- ie the way users
# actually consume this package, not just via a raw verilator command line.
#
# The flow uses SimLibUVM with dpi="true", so a missing or broken DPI overlay
# fails here rather than silently falling back to glob-only regex matching.
#
# Provisions its own venv from PyPI. Set VERILATOR_BIN_SKIP_DFM_TEST=1 to skip
# (eg for an offline build); set DFM_TEST_VENV to reuse an existing venv.
#
# The flow needs a dv-flow-libhdlsim whose SimLibUVM understands the `dpi`
# parameter and consumes the DPI overlay. Until that is on PyPI, point
# DFM_TEST_LIBHDLSIM_SPEC at a git ref or a local checkout, eg:
#   DFM_TEST_LIBHDLSIM_SPEC="git+https://github.com/dv-flow/dv-flow-libhdlsim@main"
#   DFM_TEST_LIBHDLSIM_SPEC="/path/to/dv-flow-libhdlsim"

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/dfm_test_work"

echo "=== Verilator UVM DPI + dv-flow-mgr Test ==="

if test -n "${VERILATOR_BIN_SKIP_DFM_TEST}"; then
    echo "VERILATOR_BIN_SKIP_DFM_TEST set -- skipping"
    exit 0
fi

if ! command -v verilator >/dev/null 2>&1 && ! command -v verilator.exe >/dev/null 2>&1; then
    echo "ERROR: verilator not found in PATH"
    exit 1
fi

PYTHON="${PYTHON:-python3}"
if ! command -v "${PYTHON}" >/dev/null 2>&1; then
    echo "ERROR: ${PYTHON} not found"
    exit 1
fi

rm -rf "${WORK_DIR}"
mkdir -p "${WORK_DIR}"

#--------------------------------------------------------------------
# Provision dv-flow-mgr + dv-flow-libhdlsim.
#--------------------------------------------------------------------
if test -n "${DFM_TEST_VENV}"; then
    VENV="${DFM_TEST_VENV}"
    echo "Reusing venv: ${VENV}"
else
    VENV="${WORK_DIR}/venv"
    echo "Creating venv: ${VENV}"
    "${PYTHON}" -m venv "${VENV}"
    VENV_PY="${VENV}/bin/python"
    test -x "${VENV_PY}" || VENV_PY="${VENV}/Scripts/python.exe"
    "${VENV_PY}" -m pip install --quiet --upgrade pip
    LIBHDLSIM_SPEC="${DFM_TEST_LIBHDLSIM_SPEC:-dv-flow-libhdlsim}"
    echo "Installing dv-flow-mgr and ${LIBHDLSIM_SPEC}..."
    "${VENV_PY}" -m pip install --quiet dv-flow-mgr "${LIBHDLSIM_SPEC}"
fi

VENV_PY="${VENV}/bin/python"
test -x "${VENV_PY}" || VENV_PY="${VENV}/Scripts/python.exe"

"${VENV_PY}" -c "import dv_flow.mgr, dv_flow.libhdlsim" || {
    echo "ERROR: dv-flow-mgr / dv-flow-libhdlsim not importable"
    exit 1
}

#--------------------------------------------------------------------
# Run the flow. UVM_HOME is deliberately left unset so SimLibUVM has to
# discover UVM the same way a user's flow would -- relative to the
# verilator on PATH. That exercises the installed layout, not a path we
# handed it.
#--------------------------------------------------------------------
cp "${SCRIPT_DIR}/flow.dv" "${SCRIPT_DIR}/uvm_dpi_tb.sv" "${WORK_DIR}/"
cd "${WORK_DIR}"

echo "Running dv-flow..."
set +e
env -u UVM_HOME "${VENV_PY}" -m dv_flow.mgr run run -u log > dfm.log 2>&1
DFM_STATUS=$?
set -e

cat dfm.log

if test ${DFM_STATUS} -ne 0; then
    echo "ERROR: dv-flow run failed (status ${DFM_STATUS})"
    # The console UI does not print task markers, so a bare failure says
    # nothing about why. Dig them out of the per-task exec data -- that is
    # where SimLibUVM's "no Verilator DPI backend" error lands.
    echo "--- task markers ---"
    "${VENV_PY}" - <<'PY' || true
import glob, json
for f in sorted(glob.glob('rundir/**/*exec_data.json', recursive=True)):
    try:
        d = json.load(open(f))
    except Exception:
        continue
    for m in (d.get('result') or {}).get('markers') or []:
        print("%-7s %s: %s" % (m.get('severity'), d.get('name'), m.get('msg')))
PY
    echo "--------------------"
    find rundir -name '*.log' -exec echo '--- {} ---' \; -exec cat {} \; 2>/dev/null || true
    exit 1
fi

SIM_LOG=$(find rundir -name 'sim.log' | head -1)
if test -z "${SIM_LOG}"; then
    echo "ERROR: no sim.log produced"
    exit 1
fi

echo "--- sim.log ---"
cat "${SIM_LOG}"
echo "---------------"

if ! grep -q "UVM DPI DFM TEST PASSED" "${SIM_LOG}"; then
    echo "ERROR: 'UVM DPI DFM TEST PASSED' not found in ${SIM_LOG}"
    exit 1
fi

# An actual report is "UVM_ERROR <file>(<line>) @ ..." or "UVM_ERROR @ ...".
# The report-summary count line is "UVM_ERROR :    0", so require that the
# token after the severity is not a colon.
if grep -qE "^UVM_(ERROR|FATAL) [^:]" "${SIM_LOG}"; then
    echo "ERROR: UVM reported errors"
    grep -E "^UVM_(ERROR|FATAL) [^:]" "${SIM_LOG}"
    exit 1
fi

# The report summary must show zero errors/fatals.
if ! grep -qE "UVM_ERROR :\s+0" "${SIM_LOG}"; then
    echo "ERROR: UVM report summary does not show 0 errors"
    exit 1
fi

cd "${SCRIPT_DIR}"
rm -rf "${WORK_DIR}"
echo "=== UVM DPI + dv-flow-mgr Test PASSED ==="
exit 0
