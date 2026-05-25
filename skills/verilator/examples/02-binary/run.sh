#!/bin/sh
# --binary mode: verilator generates a runnable executable with its
# own main() from a self-checking SV testbench.  The simplest possible
# "verify this RTL change" loop.
set -e
cd "$(dirname "$0")"
verilator --binary -j 0 -Wall --top-module tb_counter tb_counter.sv
./obj_dir/Vtb_counter
