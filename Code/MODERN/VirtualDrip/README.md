# ☕ Virtual Drip — Remote VDP for Zephyr-80

**Part of the *Percolator Pixels* series**
*"All the flavor, zero hardware."*

---

## 🧠 Overview

**Virtual Drip** is a *software video card* for the Zephyr-80 homebrew computer.

Instead of driving a physical VDP (like the **TMS9928A**), Zephyr streams VDP operations over a serial link to a modern machine. A proxy application reconstructs the VDP state, renders the video output, and exposes it through a standard VNC client using the **Remote Framebuffer Protocol**.

👉 The key idea:

```text
Zephyr-80 behaves like it has a real VDP.
The modern PC *is* the VDP.
```

---

## 🎯 Goals

* Provide a **drop-in development video backend** before hardware exists
* Preserve **TMS9928A programming model compatibility**
* Avoid writing a custom client (reuse existing VNC viewers)
* Keep Zephyr-side implementation **lightweight and deterministic**
* Establish a **reference VDP behavior model** for future hardware cards

---

## 🧩 Architecture

```text
Zephyr-80 (Z80)
  ↓
VDP-style register + VRAM operations (serial packets)
  ↓
Virtual Drip Proxy (modern PC)
  ↓
TMS9928A emulator (vrEmuTms9918)
  ↓
256×192 Framebuffer (32-bit ARGB)
  ↓
RFB (VNC server — LibVNCServer)
  ↓
VNC Client (viewer)
```

---

## 🔧 Component Breakdown

### 🖥 Zephyr-80 (Host)

* Sends:
  * VDP control writes
  * VDP data writes
  * (optional) reads
* Receives:
  * keyboard input events as structured `KEY_EVENT` packets

❗ Zephyr does **NOT**:

* render pixels
* implement RFB
* maintain a framebuffer

---

### ☕ Virtual Drip Proxy

Runs on a modern system. Built in C11 using CMake.

Responsibilities:

* Serial packet decoding (streaming, CRC-validated)
* TMS9928A state emulation via vrEmuTms9918
* VRAM and register tracking
* 256×192 framebuffer generation (32-bit, `0x00RRGGBB`)
* RFB server via LibVNCServer (default port 5900)
* Keyboard event forwarding over serial

---

### 📺 VDP Emulation

Backed by **[vrEmuTms9918](https://github.com/visrealm/vrEmuTms9918)** — a C99 zero-dependency TMS9918A emulator.

Supported modes and features:

* Graphics I (tiles + sprites)
* Graphics II (tiles + sprites)
* Multicolor mode (tiles + sprites)
* Text mode (40×24 characters)
* Sprites: 8×8 and 16×16, with magnification, transparency, 5th-sprite flag, and collision detection
* Per-scanline rendering
* VSYNC interrupt flag

The `VideoDevice` abstraction in `src/video_device.h` provides a stable interface for future backends; `tms9928` is the only backend currently implemented.

---

### 🌐 Display Output

* Uses **RFB (VNC)** via LibVNCServer
* Default port: **5900** (override with `--vnc-port`)
* Compatible with: RealVNC, TightVNC, TigerVNC, and any standard VNC viewer
* Pixel format: 32 bpp, red at bits 16–23, green at 8–15, blue at 0–7
* Can be disabled entirely with `--no-vnc` / `--headless`

---

## 📡 Protocol Design

Virtual Drip uses a **packetized serial protocol** carrying VDP semantics.

### Packet format

```text
[SYNC0=0xA5][SYNC1=0x5A][LEN][TYPE][PAYLOAD...][CRC8]
```

`LEN` is the byte count of the complete packet body after the sync bytes, including `LEN`, `TYPE`, `PAYLOAD`, and `CRC8`. `CRC8` is calculated over `LEN`, `TYPE`, and `PAYLOAD` using polynomial `0x07` with initial value `0x00`. The sync bytes are not included in the CRC. Total encoded size is `2 + LEN` bytes.

### Packet types

| Value | Type              | Description                          |
| ----- | ----------------- | ------------------------------------ |
| 0x01  | `VDP_CTRL_WRITE`  | Write to VDP control/address port    |
| 0x02  | `VDP_DATA_WRITE`  | Write to VDP data port               |
| 0x03  | `VDP_STATUS_READ` | Read VDP status register             |
| 0x04  | `VDP_DATA_READ`   | Read from VRAM                       |
| 0x05  | `KEY_EVENT`       | Key input forwarded to Zephyr        |
| 0x06  | `RESET`           | Reset VDP state                      |
| 0x07  | `PING`            | Debug / keepalive                    |
| 0x08  | `FRAME_MARK`      | Frame boundary marker (replay pacing)|

👉 Important design choice:

```text
The protocol transports VDP operations, NOT pixels.
```

### `KEY_EVENT` payload (4 bytes)

| Byte | Meaning                                                       |
| ---- | ------------------------------------------------------------- |
| 0    | Flags: bit 0 = down, bit 1 = up, bit 2 = has ASCII, bit 3 = has special |
| 1    | ASCII value (printable 0x20–0x7E, or control: Enter=0x0D, Backspace=0x08, Tab=0x09, Escape=0x1B), or 0 |
| 2    | Special key code (arrows, F1–F12, Insert, Delete, Home, End, Page Up/Down), or 0 |
| 3    | Modifier bitfield: bit 0 = Shift, bit 1 = Ctrl, bit 2 = Alt, bit 3 = Meta/Super |

Modifier keysyms (Shift, Ctrl, Alt, Meta) update an internal state and are also emitted as `KEY_EVENT` packets so the host can observe modifier-only presses and releases.

### Packet input sources

```bash
# File replay: decode packets, then serve the resulting framebuffer
./build/virtual-vdp --file tests/packets/50_g2_three_bands.bin

# Live serial input
./build/virtual-vdp --serial /dev/ttyUSB0 115200

# No input: serve a blank VNC framebuffer
./build/virtual-vdp
```

Supported baud rates: **9600, 19200, 38400, 57600, 115200, 230400**.

---

## ⏱ Timing Model

* No VBlank or sync signal is transmitted over serial
* Zephyr generates timing locally via the CTC
* The proxy renders asynchronously after each received write
* `FRAME_MARK` packets are a pacing tool for replay scripts only — they are not a hardware VBlank signal

---

## ⌨️ Input Model

```text
VNC Client → LibVNCServer callback → Keyboard mapper → KEY_EVENT packet → Serial → Zephyr
```

* Immediate key events (no block mode)
* Printable ASCII sent directly
* Special keys and modifiers use structured fields
* Enable/disable with `--no-keyboard`
* Debug with `--log-keys` (logs keysym, mapping, and encoded packet bytes)

---

## 🔍 Debugging Model

Virtual Drip supports deterministic debugging via:

* Per-packet logging (type, offset, payload, CRC) to stdout
* Binary packet file replay (`--file`)
* Paced serial replay with `tools/serial_replay.py` (supports `--loop`, `--frame-delay-ms`, `--dry-run`, `--read-back`, `--verbose`)
* Test packet generators in `tests/generators/` covering all four VDP modes and sprite behaviour
* Headless mode (`--no-vnc`) for decoder smoke tests without a VNC client

---

## 🧠 Design Philosophy

Virtual Drip is intentionally **not**:

* a terminal emulator (VT/ANSI)
* a 3270-style block terminal
* a pixel streaming protocol

Instead, it is:

```text
A remote VDP device.
```

It combines:

* **VDP semantics** (like real hardware)
* **remote rendering** (like RFB)
* **immediate input** (like VT terminals)

---

## 🔄 Relationship to Hardware

Virtual Drip defines the contract for future cards:

| Card             | Role                   |
| ---------------- | ---------------------- |
| **Original Joe** | Real TMS9928A hardware |
| **Crema**        | V9958 enhanced VDP     |
| **Latte Art**    | Tile engine            |
| **Double Shot**  | Framebuffer GPU        |

👉 All of them should conform to the same logical model defined here.

---

## ⚠️ Limitations

* Serial bandwidth limits update rate
* Pixel-based RFB adds translation overhead
* Not cycle-accurate timing
* Requires an external proxy process (not standalone on Zephyr)

---

## 🔮 Future Work

* Dirty-region tracking (currently the full 256×192 framebuffer is marked dirty on every write)
* 8bpp indexed framebuffer mode
* Compression (optional bandwidth reduction)
* Protocol versioning
* Integration with RX660-based video systems

---

## 💡 Why This Exists

Because this is the worst possible alternative:

```text
Wait for hardware → then debug everything at once
```

Virtual Drip allows:

```text
Build software + validate video architecture first
```

---

## 🏷 Project Name

**Virtual Drip**
Part of **Percolator Pixels**
☕ *Fresh Graphics, One Brew at a Time.*

---

## Virtual VDP — Build Reference

### Layout

```text
Code/MODERN/VirtualDrip/
├── CMakeLists.txt
├── cmake/
│   └── FindLibVNCServer.cmake
├── src/
│   ├── app_config.c / .h         # CLI argument parsing
│   ├── app_runtime.c / .h        # Signal handling, process lifetime
│   ├── display_libvncserver.c / .h  # LibVNCServer RFB display backend
│   ├── input_keyboard.c / .h     # Keysym → KEY_EVENT packet mapper
│   ├── main.c                    # Orchestration
│   ├── packet_dispatch.c / .h    # Route packets to VideoDevice
│   ├── packet_parser.c / .h      # Streaming CRC-validated packet decoder
│   ├── packet_replay.c / .h      # Binary file replay
│   ├── protocol.c / .h           # Wire format, CRC8, packet types
│   ├── protocol_debug.c / .h     # Human-readable packet logging
│   ├── serial_port.c / .h        # POSIX serial port with TX mutex
│   ├── serial_reader.c / .h      # Threaded serial byte consumer
│   ├── video_device.c / .h       # Backend abstraction interface
│   └── video_device_tms9928.c / .h  # vrEmuTms9918 concrete backend
├── tests/
│   ├── generators/               # Python packet stream generators
│   │   ├── vdrip_packets.py      # Packet helpers (mirrors protocol.h)
│   │   ├── generate_all.py
│   │   └── gen_*.py              # One generator per test scenario
│   └── packets/                  # Generated binary fixtures (git-ignored)
├── tools/
│   └── serial_replay.py          # CLI serial/PTY replay tool
└── external/
    ├── include/
    │   ├── vrEmuTms9918.h
    │   └── vrEmuTms9918Util.h
    └── lib/
        └── libvrEmuTms9918.so    # Required — see below
```

### Dependencies

- CMake 3.16 or newer
- A C11-capable compiler
- **LibVNCServer** development headers and shared library
- **vrEmuTms9918** shared library (`libvrEmuTms9918.so`) placed in `external/lib/`
- POSIX threads (`pthread`)
- Optional: `pkg-config`, used by CMake when available

On Debian/Ubuntu:

```sh
sudo apt install libvncserver-dev cmake build-essential
```

Place `libvrEmuTms9918.so` and its headers in `external/`. Override the path if needed:

```sh
cmake -S . -B build -DVIRTUAL_VDP_VREmuTMS9918_LIBRARY=/path/to/libvrEmuTms9918.so
```

### Build

```sh
cmake -S . -B build
cmake --build build
```

If LibVNCServer is installed in a non-standard location:

```sh
cmake -S . -B build -DCMAKE_PREFIX_PATH=/path/to/libvncserver
```

### Run

```sh
# Blank VNC server on port 5900
./build/virtual-vdp

# File replay, then serve frozen framebuffer
./build/virtual-vdp --file tests/packets/50_g2_three_bands.bin

# Live serial input at 115200 baud
./build/virtual-vdp --serial /dev/ttyUSB0 115200

# Custom VNC port with keyboard debug logging
./build/virtual-vdp --serial /dev/ttyUSB0 115200 --vnc-port 5901 --log-keys

# Headless decoder smoke test (no VNC)
./build/virtual-vdp --file tests/packets/01_reset.bin --no-vnc

# Explicit backend selection (currently only tms9928 is available)
./build/virtual-vdp --video-backend tms9928
```

Connect with any VNC viewer to `localhost:5900` (or the configured port).

### Generating Test Packets

```sh
cd tests/generators
python3 generate_all.py
```

Outputs land in `tests/packets/`. Each generator covers a specific VDP mode or feature:

| File | Coverage |
|------|----------|
| `01_reset.bin` | RESET and PING control packets |
| `10_set_registers.bin` | Graphics I register initialization |
| `20_palette_all_colors_graphics1.bin` | All 16 TMS9918 color indices |
| `30_text_mode_ascii_grid.bin` | Text mode 40×24 rendering |
| `40_g1_name_table_grid.bin` | Graphics I tile/name table indexing |
| `50_g2_three_bands.bin` | Graphics II pattern and color table |
| `60_multicolor_64x48_grid.bin` | Multicolor mode coarse grid |
| `70_sprite_8x8_basic.bin` | 8×8 sprites with transparency |
| `77_sprite_4_per_scanline_limit.bin` | Four-sprite-per-scanline limit |
| `91_frame_mark_sprite_motion.bin` | Animated sprite motion with FRAME_MARK pacing |

### Paced Animation Replay

```sh
python3 tools/serial_replay.py tests/packets/91_frame_mark_sprite_motion.bin \
  --port /tmp/vdrip-host \
  --baud 115200 \
  --frame-delay-ms 16.67 \
  --verbose
```
