# verilator-bin

Binary build of Verilator for various platforms. This build also includes an 
installation of the [Bitwuzla](https://github.com/bitwuzla/bitwuzla) SMT solver
to support constrained randomization, and a compatible version of the 
[UVM](https://www.accellera.org/downloads/standards/uvm) library.

## Release Scheme

Releases come from two automatic tracks.

**Release track** — when Verilator publishes a tag newer than the last one we
built, CI builds it from that tag. The version matches upstream exactly
(`5.050`, tagged `v5.050`), it is published as a full release, its notes are
Verilator's own release notes for that version, and it becomes `latest`.
Verilator tags roughly every 6–8 weeks.

**Snapshot track** — a weekly build of Verilator top-of-trunk, versioned
`<upstream in-development version>.<CI run id>` (e.g. `5.051.32639969514`) and
tagged `v5.051.32639969514`. These are marked pre-release and never become
`latest`. A build is published only when an input actually changed since the
previous snapshot.

The two tracks never both build in the same run: when a new upstream release is
available, the release track builds it and the snapshot stands down, since the
release covers the same code.

So `latest` always points at a build of a tagged Verilator release. Use
`latest` for stable work and a pre-release tag for top-of-trunk.

Both tracks build the same platform set and can be run by hand from the CI
workflow's *Run workflow* button, which takes a track selector.

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

