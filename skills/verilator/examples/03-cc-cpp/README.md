# 03-cc-cpp

Intent: `--cc` plus a hand-written C++ main. Shows the canonical
`eval()`-driven testbench loop and how to attach a VCD trace.

```
./run.sh
```

Expected: prints `PASS: q=1 (expected 1)` and produces
`obj_dir/trace.vcd` — open in GTKWave.

Use this template when:
- Your testbench needs to talk to C/C++ models (memory, peripheral
  models, ELF loaders).
- You need cycle-accurate stepping under a debugger.
- You're integrating with cocotb or another C++-driven framework.
