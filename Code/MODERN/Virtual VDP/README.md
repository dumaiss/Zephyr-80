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
├── include/
│   └── virtual_vdp/
│       └── vdp_server.h
└── src/
    ├── main.c
    └── vdp_server.c
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
```

Optional arguments are `width`, `height`, and `port`:

```sh
./build/virtual-vdp 1280 720 5901
```

Connect with a VNC client to `localhost:5900` by default. The sample server
draws a gradient framebuffer and updates a pointer marker when the client moves
the mouse.
