#!/bin/bash
echo "=== Checking for FlexLexer.h ===" 
find /mingw64 /mingw32 /usr -name "FlexLexer.h" 2>/dev/null || echo "FlexLexer.h not found"
echo ""
echo "=== Checking flex package ===" 
pacman -Ql flex | grep -i flexlexer || echo "No FlexLexer in flex package"
echo ""
echo "=== Searching for FlexLexer provider ==="
pacman -Ss flexlexer || echo "No package matches flexlexer"
pacman -Ss flex | head -20
