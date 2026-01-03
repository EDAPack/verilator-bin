#!/bin/bash
set -x

echo "=== Debug MinGW Environment ==="
echo "Current directory: $(pwd)"
echo "uname -s: $(uname -s)"
echo "uname -m: $(uname -m)"

echo ""
echo "=== PATH ==="
echo "$PATH"

echo ""
echo "=== Checking for compilers ==="
which gcc
which g++
which cc
gcc --version || echo "gcc not found"
g++ --version || echo "g++ not found"

echo ""
echo "=== Testing simple compilation ==="
cat > /tmp/test.c <<'EOF'
#include <stdio.h>
int main() {
    printf("Hello World\n");
    return 0;
}
EOF

gcc -o /tmp/test /tmp/test.c && /tmp/test && echo "gcc works!" || echo "gcc failed!"

echo ""
echo "=== Testing GMP configure directly ==="
cd /tmp
if [ ! -d gmp-test ]; then
    mkdir gmp-test
    cd gmp-test
    tar xf /d/a/verilator-bin/verilator-bin/deps/gmp-6.3.0.tar.xz || tar xf $GITHUB_WORKSPACE/deps/gmp-6.3.0.tar.xz
    cd gmp-6.3.0
    
    echo "Trying configure with minimal options..."
    CC=gcc CXX=g++ ABI=64 ./configure --prefix=/tmp/gmp-install --enable-cxx --disable-assembly 2>&1 | head -50
    
    echo ""
    echo "=== Checking config.log ==="
    if [ -f config.log ]; then
        echo "Last 100 lines of config.log:"
        tail -100 config.log
    fi
fi
