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
  * terminal input bytes as `TERMINAL_INPUT` packets

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
| 0x05  | `TERMINAL_INPUT`  | Terminal input bytes forwarded to Zephyr |
| 0x06  | `RESET`           | Reset VDP state                      |
| 0x07  | `PING`            | Debug / keepalive                    |
| 0x08  | `FRAME_MARK`      | Frame boundary marker (replay pacing)|
| 0x09  | `CURSOR_COMMAND`  | Proxy-side text cursor overlay command |
| 0x0A  | `PROXY_READY`     | Proxy startup readiness marker       |
| 0x0B  | `VDP_DATA_BLOCK`  | Block write to VDP data port         |
| 0x0C  | `VDP_SCROLL`      | Proxy-assisted text scroll command   |
| 0x0D  | `STORAGE_READ_REQ` | Read a 128-byte storage record      |
| 0x0E  | `STORAGE_READ_REPLY` | Reply to a storage read request   |
| 0x0F  | `STORAGE_WRITE_REQ` | Write a 128-byte storage record    |
| 0x10  | `STORAGE_WRITE_REPLY` | Reply to a storage write request |
| 0x11  | `TERMINAL_TX`     | PTY console output: Z80 -> proxy PTY |
| 0x12  | `TERMINAL_RX`     | PTY console input: proxy PTY -> Z80  |

👉 Important design choice:

```text
The protocol transports VDP operations, NOT pixels.
```

### `TERMINAL_INPUT` payload

Legacy packetized keyboard payload. The current default live proxy path sends
VNC keyboard bytes as raw serial terminal input for the built-in VDrip console.
PTY console mode uses `TERMINAL_RX` instead.

### PTY console packets

`TERMINAL_TX` payload bytes are written unchanged to the PTY master. `TERMINAL_RX`
payload bytes are raw bytes read from the PTY master and wrapped unchanged for
the Z80 console input FIFO. The proxy does not parse ANSI/VT100, translate keys,
track a cursor, or maintain a terminal screen buffer in PTY console mode.

The matching CP/M BIOS backend is selected at build time:

```bash
make CONSOLE_DRIVER=pt_vdrip
```

The default CP/M build remains:

```bash
make CONSOLE_DRIVER=vdrip
```

For the default VNC keyboard path, key-down events map to raw terminal bytes:

Minimal key mapping:

| Key | Bytes |
| --- | ----- |
| Printable ASCII | `20`..`7E` |
| Enter | `0D` |
| Backspace | `08` |
| Tab | `09` |
| Escape | `1B` |
| Up / Down / Right / Left | `1B 5B 41` / `1B 5B 42` / `1B 5B 43` / `1B 5B 44` |
| Home / End / Delete | `1B 5B 48` / `1B 5B 46` / `1B 5B 33 7E` |

### Packet input sources

```bash
# File replay: decode packets, then serve the resulting framebuffer
./build/virtual-vdp --file tests/packets/50_g2_three_bands.bin

# Live serial input
./build/virtual-vdp --serial /dev/ttyUSB0 115200

# Live serial input with an explicit drive A image
./build/virtual-vdp --serial /dev/ttyUSB0 115200 --disk-a zephyr_a.img

# Live serial input with storage transaction logging
./build/virtual-vdp --serial /dev/ttyUSB0 115200 --disk-a zephyr_a.img --log-storage

# Packetized PTY console bridge for a PTY-console CP/M BIOS build
./build/virtual-vdp --serial /dev/ttyUSB0 115200 --console-pty

# No input: serve a blank VNC framebuffer
./build/virtual-vdp
```

Supported baud rates: **9600, 19200, 38400, 57600, 115200, 230400**.

Serial mode uses kernel-managed hardware RTS/CTS flow control. Virtual Drip
enables `CRTSCTS` and disables software XON/XOFF; the serial driver gates
physical proxy-to-Z80 transmission on peer CTS. Storage replies also use an
inter-byte delay for the Z80-side parser.

In serial mode, `--disk-a PATH` selects the local flat 8 MiB image backing CP/M drive A.
A missing image is created and filled with `0xE5`; an existing image with any other size is rejected.

---

## ⏱ Timing Model

* No VBlank or sync signal is transmitted over serial
* Zephyr generates timing locally via the CTC
* The proxy renders asynchronously after each received write
* `FRAME_MARK` packets are a pacing tool for replay scripts only — they are not a hardware VBlank signal

---

## ⌨️ Input Model

```text
Default VNC mode:
VNC Client → LibVNCServer callback → Keyboard mapper → raw terminal bytes → Serial → Zephyr

PTY console mode:
terminal emulator → PTY master → TERMINAL_RX packet → Serial → Zephyr
Zephyr → TERMINAL_TX packet → PTY master → terminal emulator
```

* Immediate key events (no block mode)
* Key-down events become terminal input bytes
* Key-up events do not generate packets
* Arrow keys use minimal ANSI CSI sequences
* Enable/disable with `--no-keyboard`
* Debug with `--log-keys` (logs terminal packet payload bytes)
* Enable PTY console bridging with `--console-pty` in serial mode

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
│   ├── input_keyboard.c / .h     # Keysym → terminal input packet mapper
│   ├── main.c                    # Orchestration
│   ├── packet_dispatch.c / .h    # Route packets to VideoDevice
│   ├── packet_parser.c / .h      # Streaming CRC-validated packet decoder
│   ├── packet_replay.c / .h      # Binary file replay
│   ├── protocol.c / .h           # Wire format, CRC8, packet types
│   ├── protocol_debug.c / .h     # Human-readable packet logging
│   ├── serial_port.c / .h        # POSIX serial port with TX mutex
│   ├── serial_reader.c / .h      # Threaded serial byte consumer
│   ├── storage_backend.c / .h    # Flat 8 MiB drive A image backend
│   ├── storage_protocol.c / .h   # Virtual Drip storage request handling
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

# Live serial input with an explicit drive A disk image
./build/virtual-vdp --serial /dev/ttyUSB0 115200 --disk-a zephyr_a.img

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
