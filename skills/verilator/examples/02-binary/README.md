# 02-binary

Intent: `--binary` mode end-to-end. Self-checking SV TB →
executable → run → `PASS`/`$fatal`. The canonical
"run-this-when-RTL-changes" loop for verilator.

```
./run.sh
```

Expected output ends with `PASS: counter wrapped at 256 cycles`.
