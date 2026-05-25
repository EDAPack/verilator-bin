#!/bin/sh
# Strict lint only — no build, no run.  Treats every standard warning
# as fatal so an agent can use lint as a gating check.
set -e
cd "$(dirname "$0")"
verilator --lint-only -Wall --top-module counter design.sv
echo "lint: OK"
