# verilator-bin

Binary build of Verilator for various platforms. This build also includes an 
installation of the [Bitwuzla](https://github.com/bitwuzla/bitwuzla) SMT solver
to support constrained randomization, and a compatible version of the 
[UVM](https://www.accellera.org/downloads/standards/uvm) library.

## Release Scheme
verilator-bin provides weekly builds of Verilator top-of-trunk. These releases
are generally marked as pre-release.

verilator-bin also provides tagged builds of Verilator releases.

The latest most-stable build is tagged 'latest'.

## Testing
Each build automatically runs a smoke test to validate the installation. The test:
1. Compiles a simple SystemVerilog module (`tests/smoke.sv`) using `verilator --binary`
2. Runs the resulting simulation executable with a 5-second timeout
3. Verifies that "Hello World" is displayed in the output

You can manually run the smoke test after installing Verilator:
```bash
cd tests
./run_smoke_test.sh
```

