# Windows build

Superseded. The MinGW64/MinGW32 build this file described shipped from
January to March 2026, then broke and was disabled.

Windows is now built as the `windows-x86_64` target (MSYS2 UCRT64, x86_64
only, no Bitwuzla, `optional` so it never blocks a release). See
[docs/design/windows.md](docs/design/windows.md) for the design, decisions,
history and status.
