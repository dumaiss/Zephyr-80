Here is the updated **Z80 Peripherals Controller** document, revised to match the hardware implementation found in the provided KiCad schematics.

### **Z80 I/O Subsystem — SD + Dual-USB-HID via SIO + PIC18 Micro Controller**

## **1) Overall Architecture**

### **1.1 Goals**

- **Decoupled I/O:** The PIC18 acts as an I/O co-processor, managing the "chunky" (SD Card) and "urgent" (USB HID) tasks via SPI, isolating the Z80 from complex protocols.
    
- **Simple Z80 Integration:** The Z80 interacts with these peripherals strictly through standard Z80 SIO UART links, treating the modern subsystems as simple serial streams.
    


### **1.2 Major Blocks**

- **Z80 Host:** Driven by a **14.7456 MHz** system clock oscillator (`Y1`).    
- **Clock Management:** A 4040 counter (`U8`) derives the system and peripheral clocks from the main oscillator.
    
    - **7.3728 MHz** for high-speed SIO links.        
    - **3.6864 MHz** for the CTC and CPU system clock.        
    - **1.8432 MHz** for standard baud rate generation (115.2k).
        
- **2× Z80 SIO/0:** Providing 4 serial channels total (`IC2`, `IC3`).      
- **Z80 CTC:** Used for the User Port baud rate generation and system timing (`IC1`).    
- **PIC18F57Q84:** The 5V I/O co-processor (`U15`). It connects to the SIOs via bit-banged UART links on **Port C** and manages peripherals via hardware SPI on **Port D**11.    

---

## **2) Channel Assignment & Addressing**

The hardware implementation uses the following channel mapping. Note that the MCU communicates with the SIOs using **Port C** pins.

### **2.1 SIO 0 (`IC2`) — Base Address 0x20**

Driven by a **1.8432 MHz** clock, providing fixed **115,200 baud** (x16 divisor).

| **Channel** | **Role**       | **Description**                         | **I/O Address (Data / Ctrl)** |
| ----------- | -------------- | --------------------------------------- | ----------------------------- |
| **A**       | **USB / GPIO** | Link to MCU for Keyboard/Mouse HID data | **0x20 / 0x22**               |
| **B**       | **Console**    | Main user terminal (FTDI/Serial header) | **0x21 / 0x23**               |

### **2.2 SIO 1 (`IC2`) — Base Address 0x30**

Driven by mixed clocks for high-speed and variable rate support.

| **Channel** | **Role**      | **Description**                                   | **I/O Address (Data / Ctrl)** |
| ----------- | ------------- | ------------------------------------------------- | ----------------------------- |
| **A**       | **SD Card**   | High-speed link to MCU for Disk I/O (460.8k baud) | **0x20 / 0x22**               |
| **B**       | **User Port** | External serial port (Clocked by CTC Ch 0)        | **0x21 / 0x23**               |

### **2.3 Z80 CTC (`IC3`) — Base Address 0x40**

Driven by **3.6864 MHz**.

| **Channel** | **Function**                                       | **I/O Address** |
| ----------- | -------------------------------------------------- | --------------- |
| **0**       | **User UART Baud** (Generates clock for SIO1 Ch B) | **0x40**        |
| **1**       | General Purpose / Header Output (`TO1`)            | **0x41**        |
| **2**       | General Purpose / Header Output (`TO2`)            | **0x42**        |
| **3**       | General Purpose                                    | **0x43**        |

---

## **3) MCU & Data Paths**

### **3.1 MCU Pin Usage (`U15` PIC18F57Q84)**

The MCU uses its hardware SPI port to act as the master for the SD Card and USB Host Controller (MAX3421E), while using Port C to emulate serial links to the Z80.

- **SPI Bus (Port D):**
    
    - `PD1` (Pin 15): **~USB_CS** (Chip Select for USB).        
    - `PD2` (Pin 16): **~SD_CS** (Chip Select for SD Card).        
    - `PD3` (Pin 17): **SPI_MOSI**.        
    - `PD4` (Pin 18): **SPI_MISO**.        
    - `PD5` (Pin 19): **SPI_CLK**.
    
- **Control Signals:**
    
    - `PD0` (Pin 14): **USB_INT** (Interrupt from USB Controller).        
    - `PD6` (Pin 20): **~USB_RST** (Reset USB Controller).        
    - `PD7` (Pin 21): **~POWER_OFF** (Signal to power manager).
        
- **Z80 Link (Port C):**
    
    - **Port C (`PC0`–`PC7`)** handles the TX/RX/CTS/RTS signals connecting to the SIO chips (`IC1`/`IC2`).        

### **3.2 Clocks & Baud Rates**

- **SD Card Link (SIO1 A):**
    
    - Clock Source: **7.3728 MHz** (`CLK_7M3728`).        
    - Divisor: x16.        
    - Resulting Baud Rate: **460,800 baud**.
        
- **Console & USB Link (SIO0 A/B):**    
    - Clock Source: **1.8432 MHz** (`CLK_1M8432`).        
    - Divisor: x16.        
    - Resulting Baud Rate: **115,200 baud**.
        

---

## **4) Hardware Notes**

- **SD Card Presence:** The `SD_PRESENT` signal is routed to the MCU34, allowing it to detect card insertion before attempting initialization via SPI.
    
- **User Port:** The User UART (SIO1 B) baud rate is fully programmable via CTC Channel 0, allowing for non-standard or legacy baud rates independent of the fixed system clocks.
    
- **Expansion:** `TO1` and `TO2` from the CTC are routed to headers/expansion, available for external timing or triggering applications.

## 5) Programming model for Z80  

### 5.1 HID (USART0 / SIO_USB): 2-byte event records (commandless)

HID is a pure **byte stream** from MCU to Z80. Z80 reads it via SIO RX ISR. 

#### Record format (2 bytes)

- **Byte0 = META**
- `b7..b4 TYPE` (0..15)
- `b3..b2 PORT` (00=port1, 01=port2)
- `b1..b0 FLAGS` (currently 00)
- **Byte1 = DATA**
- “which key / which button / which modifier bitfield”
  

Suggested TYPE values:

- `0x0 KEY_DOWN` DATA = keycode
- `0x1 KEY_UP` DATA = keycode
- `0x2 MODS` DATA = mods bitfield
- `0x3 DPAD_STATE` DATA = bitfield
- `0x4 DEV_PRESENT` DATA = 0/1  

MODS bitfield (DATA for TYPE=MODS):

- b0 LCTRL, b1 LSHIFT, b2 LALT, b3 LGUI, b4 RCTRL, b5 RSHIFT, b6 RALT, b7 RGUI

#### Z80 ISR sketch (ring buffer)

```asm

; Called from IM2 when SIO_USB RX interrupt fires.

; Goal: drain SIO RX FIFO quickly, store bytes into ring.

  

SIO_USB_ISR:

.loop:

in a,(SIO_USB_RR0)

bit 0,a ; RX char available?

jr z,.done

in a,(SIO_USB_DATA)

call RING_PUSH_A

jr .loop

.done:

ei

reti

````

  
Foreground parser consumes in 2-byte chunks:
 

```asm

; if ring has >=2 bytes:

; meta = pop(); data = pop();

; switch(meta>>4) ...

```

  
---

### 5.2 SD (USART1 / SIO_SD): single-sector RAM buffer protocol

#### Key idea

- MCU holds **one sector** in RAM.
- Host decides when to load, read sequentially, patch, write sequentially, and flush.
- MCU never emits unsolicited status bytes.

#### Opcodes (1 byte each)  

- `0x10 LOAD` + `LBA32` (5 bytes total)
- `0x11 READSEQ` (1 byte cmd, MCU sends 512 bytes)
- `0x12 READRND` + `IDX16` (3 bytes cmd, MCU sends 1 byte)
- `0x13 WRITESEQ` + `LEN16` + data (3+LEN bytes)
- `0x14 WRITERND` + `IDX16` + data8 (4 bytes)
- `0x15 FLUSH` (1 byte)
- `0x16 GETSTAT` (1 byte, MCU sends 1 status byte)  

Status byte (`GETSTAT` response):
- `0x00 OK`
- nonzero = error (pick a tiny set; example)
- `0x01 NOSECTOR`
- `0x02 RANGE`
- `0x10 SD_IO` (read/write failure)  

Policy:  

- On `LOAD(new_lba)`: if current buffer is dirty → **flush it** → then load new.
- `READSEQ`: sends exactly **512 bytes**; host counts; no trailer.  

#### Z80 helper routines (sketch)

Assume you already have `SIO_SD_PUTC` and `SIO_SD_GETC` for the channel.

**LOAD** 

```asm

; HL:DE = LBA32 (little-endian or your choice; just be consistent)

SD_LOAD:
ld a,0x10
call SIO_SD_PUTC
ld a,l : call SIO_SD_PUTC
ld a,h : call SIO_SD_PUTC
ld a,e : call SIO_SD_PUTC
ld a,d : call SIO_SD_PUTC
ret

```

  **GETSTAT** 

```asm

SD_GETSTAT:
ld a,0x16
call SIO_SD_PUTC
call SIO_SD_GETC ; returns A=status
ret

```

  **READSEQ → buffer[512]**  

```asm

; IX points to destination buffer

SD_READSEQ_512:
ld a,0x11
call SIO_SD_PUTC
ld b,0 ; 256
ld c,2 ; 2 blocks of 256 = 512

.next256:
push bc
ld b,0

.loop256:
call SIO_SD_GETC
ld (ix+0),a
inc ix
djnz .loop256
pop bc
dec c
jr nz,.next256
ret

```

  
**WRITESEQ (512) from buffer**
 

```asm

; IX points to source buffer
SD_WRITESEQ_512:
ld a,0x13
call SIO_SD_PUTC

; LEN16 = 0x0200
xor a
call SIO_SD_PUTC ; LEN lo = 0x00
ld a,0x02
call SIO_SD_PUTC ; LEN hi = 0x02
ld b,0
ld c,2

.next256w:
push bc
ld b,0

.loop256w:
ld a,(ix+0)
inc ix
call SIO_SD_PUTC
djnz .loop256w
pop bc
dec c
jr nz,.next256w

ret

```

  

**FLUSH**

  
```asm

SD_FLUSH:
ld a,0x15
call SIO_SD_PUTC
ret

```

  

**Recommended calling pattern**

- Read sector:
- `SD_LOAD(lba)` → `SD_GETSTAT()` (optional check)
- `SD_READSEQ_512()` → (use data)

- Write whole sector:
- `SD_LOAD(lba)` (optional if you want read-modify-write)
- `SD_WRITESEQ_512()`
- `SD_FLUSH()` → `SD_GETSTAT()` (check)

---

## 6) MCU firmware notes (non-normative, just to align expectations)

  
- FreeRTOS is optional; with ATmega1284P it’s feasible.
- Priority rule:
- HID task is “fast + frequent” (driven by MAX3421E INT)
- SD task is “slow + chunky” (SPI block transfers)
- Since HID and SD have **separate UARTs**, you don’t get priority inversion on the Z80 side.

---

## 7) What’s deliberately _not_ specified

- Exact keycode mapping (ASCII vs HID usages vs your own table): **software choice**
- Any checksum/CRC/framing on UART: **nope**
- Fancy caches: **nope** (only one working sector)
- “Perfect reliability under abuse”: **nope** (bench machine, not a product)