# Source

ColecoGo Z80/CP/M source code will live in this directory.

Expected initial implementation areas:

- CP/M command-tail parsing and file I/O
- BIOS and cartridge validation
- cross-bank staging through Zephyr extended BIOS services
- common-memory Stage A trampoline
- target-bank Stage B takeover routine
- V9958 Coleco palette and NMI-routing setup
- final transfer to the ColecoVision BIOS at `0000h`
