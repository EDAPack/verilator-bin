#!/bin/sh
# --cc + --exe + --build: verilator generates a C++ class for the DUT,
# adds sim_main.cpp to the build, and runs make.  This is how virtually
# every CPU/SoC regression that uses verilator is structured.
set -e
cd "$(dirname "$0")"
verilator --cc --exe --build -j 0 \
    --trace \
    --top-module counter \
    counter.v sim_main.cpp
./obj_dir/Vcounter
ls -l obj_dir/trace.vcd
