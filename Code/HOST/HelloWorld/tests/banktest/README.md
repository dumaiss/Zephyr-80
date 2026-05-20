# Zephyr-80 Banking Test

Monitor-launched SRAM banking test for the Zephyr-80.

Build:

```sh
make
```

Output:

- `build/banktest.ihx`: Intel HEX image loaded at `8000h`
- Stage 2 runtime address: `1000h`

Run from the monitor:

```text
L
G 8000
```

Expected output:

```text
Zephyr-80 banking test
Copying ROM shadow...
Copying stage2...
Switching ROM off...
Stage2 running from common RAM
Testing banks...
PASS
```

After `PASS`, the test selects bank 0, leaves `ROM_DIS=1`, restores the
monitor's original stack pointer, and returns to the monitor. At that point the
monitor is executing from the SRAM copy made under the boot ROM window.

Bank latch constants used by this test:

- `BANK_CTRL_PORT = 0x00`
- `BANK_BITS_MASK = 0x07`
- `ROM_DIS_BIT = 0x08`

Those values come from the local HDL/schematic text. `RAM_SHADOW` appears as a
memory decoder input, but no software-controlled latch bit for it was found in
this tree; this test assumes the reset/default value remains `0`.
