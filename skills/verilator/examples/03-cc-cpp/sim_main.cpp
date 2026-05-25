// Hand-written C++ harness around Vcounter.  Demonstrates the
// canonical eval loop, VCD tracing, and clean shutdown.
#include "Vcounter.h"
#include "verilated.h"
#include "verilated_vcd_c.h"
#include <cstdio>

int main(int argc, char** argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::traceEverOn(true);

    auto* top = new Vcounter;
    auto* tfp = new VerilatedVcdC;
    top->trace(tfp, 99);
    tfp->open("obj_dir/trace.vcd");

    vluint64_t t = 0;
    auto tick = [&](int n) {
        for (int i = 0; i < n; ++i) {
            top->clk = 0; top->eval(); tfp->dump(t++);
            top->clk = 1; top->eval(); tfp->dump(t++);
        }
    };

    top->rst_n = 0; tick(2);
    top->rst_n = 1; tick(257);

    int ok = (top->q == 1);
    std::printf("%s: q=%d (expected 1)\n", ok ? "PASS" : "FAIL", top->q);

    tfp->close();
    delete tfp;
    delete top;
    return ok ? 0 : 1;
}
