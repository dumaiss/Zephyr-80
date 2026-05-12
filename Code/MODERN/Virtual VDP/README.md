# ☕ Virtual Drip — Remote VDP for Zephyr-80

**Part of the *Percolator Pixels* series**
*“All the flavor, zero hardware.”*

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
TMS9928A emulator (software)
  ↓
Framebuffer
  ↓
RFB (VNC server)
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

  * keyboard input events

❗ Zephyr does **NOT**:

* render pixels
* implement RFB
* maintain a framebuffer

---

### ☕ Virtual Drip Proxy

Runs on a modern system.

Responsibilities:

* Serial packet decoding
* VDP state emulation
* VRAM + register tracking
* Framebuffer generation
* RFB server implementation
* Keyboard event forwarding

---

### 📺 VDP Emulation

Backed by a software implementation such as:

* vrEmuTms9918
* pico9918
* or equivalent

Emulates:

* VRAM
* registers
* tile rendering
* sprites (optional phase)
* status flags

---

### 🌐 Display Output

* Uses **RFB (VNC)**
* Compatible with:

  * RealVNC
  * TightVNC
  * TigerVNC
  * etc.

No custom client required.

---

## 📡 Protocol Design

Virtual Drip uses a **packetized serial protocol** carrying VDP semantics.

### Packet format (v1)

```text
[SYNC=0xA5][LEN][TYPE][PAYLOAD...][CRC8]
```

`LEN` is the payload length in bytes. `CRC8` is calculated over `LEN`,
`TYPE`, and `PAYLOAD` using polynomial `0x07` with initial value `0x00`.

### Core packet types

| Type              | Description             |
| ----------------- | ----------------------- |
| `VDP_CTRL_WRITE`  | Write to control port   |
| `VDP_DATA_WRITE`  | Write to data port      |
| `VDP_STATUS_READ` | Read status register    |
| `VDP_DATA_READ`   | Read VRAM               |
| `KEY_EVENT`       | Key input from client   |
| `RESET`           | Reset VDP state         |
| `PING`            | Debug / keepalive       |
| `FRAME_MARK`      | Optional frame boundary |

👉 Important design choice:

```text
The protocol transports VDP operations, NOT pixels.
```

### Packet input sources

The proxy can decode packets from a binary file, feed them into the VDP
emulator, and then keep running the VNC server with the resulting
framebuffer:

```bash
./build/virtual-vdp packets.bin
./build/virtual-vdp --file packets.bin
```

It can also read the same packet stream from a serial device:

```bash
./build/virtual-vdp --serial /dev/ttyUSB0 115200
```

The video chip personality is selected with `--video-backend`. The only
backend currently implemented is `tms9928`, which uses `vrEmuTms9918`:

```bash
./build/virtual-vdp --video-backend tms9928
```

During file replay or serial input, decoded packets are dispatched to `vrEmuTms9918`.
`VDP_CTRL_WRITE` feeds the emulator control/address port,
`VDP_DATA_WRITE` feeds the emulator data port, and the VDP output is
rendered into the VNC framebuffer after each write. After replay
completes, connect a VNC client to `localhost:5900` to inspect the final
frame. In serial mode, the VNC server stays live while incoming packets
continue to update the framebuffer.

Packet type values currently used by the decoder:

| Value | Type              |
| ----- | ----------------- |
| 0x01  | `VDP_CTRL_WRITE`  |
| 0x02  | `VDP_DATA_WRITE`  |
| 0x03  | `VDP_STATUS_READ` |
| 0x04  | `VDP_DATA_READ`   |
| 0x05  | `KEY_EVENT`       |
| 0x06  | `RESET`           |
| 0x07  | `PING`            |
| 0x08  | `FRAME_MARK`      |

---

## ⏱ Timing Model

* No VBlank or sync over serial
* Zephyr generates timing locally (CTC)
* Proxy renders asynchronously

This avoids:

* timing coupling
* bandwidth waste
* synchronization complexity

---

## ⌨️ Input Model

```text
VNC Client → Proxy → Serial → Zephyr
```

* Immediate key events (no block mode)
* ASCII-first implementation
* Expandable to scan codes / modifiers

The proxy receives keyboard input through LibVNCServer's `kbdAddEvent`
callback and sends structured `KEY_EVENT` packets back over the same serial
port used for incoming VDP operations. This can be disabled with
`--no-keyboard` or debugged with `--log-keys`.

Current `KEY_EVENT` payload:

| Byte | Meaning |
| ---- | ------- |
| 0 | flags: bit 0 down, bit 1 up, bit 2 has ASCII, bit 3 has special key |
| 1 | ASCII value, or 0 |
| 2 | special key code, or 0 |
| 3 | modifiers: bit 0 shift, bit 1 ctrl, bit 2 alt, bit 3 meta/super |

Printable ASCII is sent directly. Enter is ASCII `0x0D`, Backspace is ASCII
`0x08`, Escape is ASCII `0x1B`, and Tab is ASCII `0x09`. Arrow keys, Insert,
Delete, Home, End, Page Up/Down, and F1-F12 use special key codes.
Modifier keysyms update an internal modifier state and are also emitted as
`KEY_EVENT` packets with no ASCII or special key code so the host can observe
modifier-only presses and releases.

---

## 🚀 Bring-Up Strategy

Virtual Drip is designed to be built incrementally:

### Phase 0

RFB server → test pattern

### Phase 1

VDP emulator → static rendering

### Phase 2

Packet decoding (file replay)

### Phase 3

Serial integration

### Phase 4

Zephyr VDP write shim

### Phase 5

Keyboard return path

### Phase 6

BIOS console integration

### Phase 7

Compatibility validation

---

## 🔍 Debugging Model

Virtual Drip supports deterministic debugging via:

* packet logging
* packet replay
* VDP state inspection
* framebuffer snapshots

👉 This makes it a **reference implementation**, not just a dev tool.

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

👉 All of them should conform to the same logical model.

---

## ⚠️ Limitations

* Serial bandwidth limits update rate
* Pixel-based RFB adds translation overhead
* Not cycle-accurate timing
* Sprites may be approximated in early versions
* Requires external proxy (not standalone)

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

## 🧩 Future Work

* Sprite support
* Dirty-region tracking
* 8bpp indexed framebuffer mode
* compression (optional)
* protocol versioning
* replay tooling UI
* integration with RX660-based video systems

---

## 🏷 Project Name

**Virtual Drip**
Part of **Percolator Pixels**
☕ *Fresh Graphics, One Brew at a Time.*



## Virtual VDP

Minimal C project scaffold for a virtual display server using
[LibVNCServer](https://libvnc.github.io/).

### Layout

```text
.
├── CMakeLists.txt
├── cmake/
│   └── FindLibVNCServer.cmake
└── src/
    ├── main.c
    ├── display_libvncserver.c
    └── display_libvncserver.h
```

### Dependencies

- CMake 3.16 or newer
- A C11-capable compiler
- LibVNCServer development headers and library
- Optional: pkg-config, used by CMake when available

On vcpkg-based Windows setups, install LibVNCServer first and configure with
your vcpkg toolchain file.

### Build

```sh
cmake -S . -B build
cmake --build build
```

If LibVNCServer is installed in a non-standard location, point CMake at it:

```sh
cmake -S . -B build -DCMAKE_PREFIX_PATH=/path/to/libvncserver
```

### Run

```sh
./build/virtual-vdp
./build/virtual-vdp --file tests/packets.bin
./build/virtual-vdp --serial /dev/ttyUSB0 115200
./build/virtual-vdp --serial /dev/ttyUSB0 115200 --vnc-port 5901 --log-keys
./build/virtual-vdp --video-backend tms9928
```

Connect with a VNC client to `localhost:5900`. The serial input expects the
same framed packet stream as the binary replay fixtures, so a `pyserial`
sender can write packet bytes directly to the configured device.
