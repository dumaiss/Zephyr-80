
# Z80 HomeBrew Single-Board Computer

**Memory & I/O Architecture Reference Manual**

## 1. Architecture Overview

This system is a Z80-based single-board computer designed for flexibility, supporting both classic "ColecoVision-style" fixed memory maps and a modern "All-RAM" banked architecture suitable for CP/M or complex homebrew software.

### Core Specifications

- **CPU:** Z80 @ 3.68MHz (or up to 8MHz depending on parts).    
- **RAM:** 512KB Static RAM (Banked).    
- **ROM:** 512KB Flash/EEPROM (Banked).    
- **Memory Controller:** Hybrid design using a **74HC273 Latch** for state storage and a **GAL22V10** for address decoding and logic injection.
   

---

## 2. Memory Management

The memory management system is designed with a **safe power-on default**. At power-on, the banking latch initializes to $00, placing the system in **Standard Boot Mode** - a ColecoVision-compatible configuration requiring no initialization. The system boots directly into ROM BIOS and is immediately functional. Advanced features (bank switching, All-RAM mode, CP/M) are accessed by writing to the Banking Latch at I/O Port $00.

## 2.1 Usage Patterns

### Pattern A: Simple/ColecoVision Mode (Default - No Setup Required)

**Power-on state provides:**
- ROM BIOS at $0000-$5FFF
- Work RAM at $6000-$7FFF  
- Cartridge or upper RAM at $8000-$FFFF

**No MMU configuration needed** - system is immediately ready. This mode is 
compatible with ColecoVision software and simple applications that don't 
require bank switching.

---

### Pattern B: CP/M / Advanced Mode (Requires Initialization)

For CP/M or applications requiring full 512KB RAM access:

1. **Power-on**: System starts in Boot Mode (ROM_DIS=0)
2. **ROM BIOS executes** from $0000
3. **Enable Shadow Mode**: `OUT ($00), $08` 
4. **Copy BIOS to RAM**: Use `LDIR` to copy $0000-$5FFF to RAM
5. **Switch to All-RAM**: `OUT ($00), $10`
6. **Result**: 
   - Full 512KB RAM accessible via bank switching
   - Common area at $0000-$1FFF always mapped to Bank 0 (for interrupt safety)
   - $2000-$FFFF can access any of 8 banks

See Section 4 for detailed code examples.

### Configuration Port ($00)

The memory is managed by writing to the **Banking Latch** at I/O Port **`$00`**.

| **Bit**   | **Name**        | **Function**                                                                                                                                                            |
| --------- | --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **D0-D2** | **RAM Bank**    | Selects the active 64KB RAM Bank (`0-7`) for the swappable area.                                                                                                        |
| **D3**    | **Shadow**      | **0** = Normal Operation.<br><br>  <br><br>**1** = **Shadow Mode**. Writes to ROM addresses are redirected to RAM. Reads still come from ROM. Used to copy BIOS to RAM. |
| **D4**    | **ROM Disable** | **0** = ROM Enabled (Boot/Standard Mode).<br><br>  <br><br>**1** = ROM Disabled (All-RAM Mode).                                                                         |
| **D5-D7** | **ROM Page**    | Selects the active 64KB ROM Page (`0-7`) mapped into the BIOS area.                                                                                                     |

### Operational Modes

#### A. Standard Boot Mode (Default)

- **Condition:** `ROM_DIS = 0`.    
- **Layout:**
    
    - **$0000 - $5FFF:** ROM (BIOS).        
    - **$6000 - $7FFF:** RAM (Fixed window).        
    - **$8000 - $FFFF:** Cartridge ROM (if present) OR Upper RAM.
        
- **Behavior:** The system behaves like a standard console. Vectors at `$0000` are served from ROM.
    

#### B. All-RAM Mode (CP/M Mode)

- **Condition:** `ROM_DIS = 1` AND `No Cartridge`.    
- **Layout:**
    
    - **$0000 - $1FFF:** **Common RAM (Forced Bank 0)**.        
    - **$2000 - $FFFF:** Swappable RAM (Selected by `D0-D2`).
        
- **Safety Feature:** The "Common Area" logic in the GAL ensures that the bottom 8KB (`$0000-$1FFF`) **always points to Physical Bank 0**, regardless of the Bank Select bits. This prevents system crashes during interrupts (Vectors at `$0066`/`$0038` stay accessible).
   

---

## 3. Memory Maps

### Boot Mode (Standard)

|**Address**|**Size**|**Description**|**Physical Source**|
|---|---|---|---|
|**$0000 - $5FFF**|24KB|BIOS ROM|ROM Page `D5-D7`|
|**$6000 - $7FFF**|8KB|Work RAM|RAM Bank `D0-D2`|
|**$8000 - $FFFF**|32KB|Cartridge / RAM|Cartridge OR RAM Bank `D0-D2`|

**Note:** In Standard Boot Mode, the full 24KB ROM is accessible. When transitioning to All-RAM mode, the Common Area safety feature restricts the bottom 8KB to Bank 0.

### All-RAM Mode (ROM Disabled)

|**Address**|**Size**|**Description**|**Physical Source**|
|---|---|---|---|
|**$0000 - $1FFF**|8KB|**Common RAM**|**RAM Bank 0** (Hardware Forced)|
|**$2000 - $FFFF**|56KB|Swappable RAM|RAM Bank `D0-D2`|

> **Note:** In All-RAM Mode, if you select Bank 1 (`D0-D2 = 1`), you access Bank 1's memory from `$2000` upwards. The bottom 8KB of Bank 1 is effectively "hidden" behind the Common Area.

### External Programming (PROG Signal)
The PROG signal enables in-system programming of the Flash ROM via an external 
programmer. When PROG is asserted:
- The external programmer takes control via CPU bus mastering signals (BUSREQ/BUSACK)
- ROM_CS is enabled, SRAM_CS and CART_CS are disabled
- This allows direct Flash programming without removing the chip

**Note:** PROG is intended for development/manufacturing use only.

### Cartridge Detection
The CART_DETECT signal (active HIGH) indicates when a physical cartridge is 
inserted. This signal:
- Is pulled HIGH when a cartridge with the detection pin is inserted
- Modifies memory mapping in Standard Boot Mode to enable cartridge ROM at $8000-$FFFF
- Should be tied LOW (via pull-down) if no cartridge slot is implemented

---

## 4. Programming Model

### Example: Copying BIOS to RAM (Shadowing)

To boot CP/M, you must copy the ROM code into RAM and then switch the ROM off.

Code snippet

```
    ; 1. Enable Shadow Mode (Bit 3 = 1)
    ;    Keep ROM enabled (Bit 4 = 0)
    LD  A, %00001000   ; D3=1
    OUT ($00), A

    ; 2. Copy ROM to RAM
    ;    Reads come from ROM, Writes go to RAM (because of Shadow bit)
    LD  HL, $0000      ; Source
    LD  DE, $0000      ; Destination
    LD  BC, $6000      ; Copy 24KB
    LDIR

    ; 3. Disable ROM and Shadow Mode (Switch to All-RAM)
    ;    Bit 4 = 1 (Disable ROM), Bit 3 = 0 (Shadow Off)
    LD  A, %00010000   ; D4=1
    OUT ($00), A

    ; System is now running purely from RAM Bank 0.
```

### Example: Switching Banks in All-RAM Mode

When running in All-RAM mode, code in the **Common Area** (`$0000-$1FFF`) can safely switch banks without crashing.

Code snippet

```
    ORG $1000          ; Code located in Common Area

SWITCH_TO_BANK1:
    LD  A, %00010001   ; D4=1 (Keep ROM Off), D0=1 (Select Bank 1)
    OUT ($00), A
    
    ; Now, memory from $2000-$FFFF belongs to Bank 1.
    ; Memory from $0000-$1FFF is STILL Bank 0.
    RET
```

---

## 5. I/O Map

| **Port Range** | **R/W** | **Function**                         |
| -------------- | ------- | ------------------------------------ |
| $00 - $0F      | R/W     | Memory Banking Latch (See Section 2) |
| $10 - $1F      | --      | Unused                               |
| $20 - $2F      | R/W     | Console / User Port (SIO0)           |
| $30 - $3F      | R/W     | SD Card / USB (SIO1)                 |
| $40 - $4F      | R/W     | CTC (Counter/Timer)                  |
| $50 - $5F      | --      | Unused                               |
| $60 - $6F      | R/W     | Cartridge I/O Expansion              |
| $70 - $7F      | --      | Unused                               |
| $80 - $8F      | R/W     | RESERVED (Coleco Compat)             |
| $90 - $9F      | R/W     | RESERVED (Coleco Compat)             |
| $A0 - $AF      | R/W     | Video VDP (TMS9928)                  |
| $B0 - $BF      | R/W     | Video VDP (TMS9928)                  |
| $C0 - $CF      | R/W     | RESERVED (Coleco Compat)             |
| $D0 - $DF      | R/W     | RESERVED (Coleco Compat)             |
| $E0 - $EF      | R       | Controller                           |
| $E0 - $EF      | W       | Sound Generators (SN76489 x2)        |
| $F0 - $FF      | R       | Controller                           |
| $F0 - $FF      | W       | Sound Generators (SN76489 x2)        |

---

## 6. Hardware Logic Definitions (WinCUPL)

These are the final logic definitions matching the architecture described above.

### A. Memory Decoder (`Z80_MEM_DECODE`)

_Implements the Banking, Shadowing, and "Common Area" safety logic._

Code snippet

```
Name     Z80_MEM_DECODE;
Partno   008;
Date     2026-01-17;
Revision 08;
Designer HomeBrew;
Company  Z80 Project;
Assembly Memory Board;
Location U_MEM_GAL;
Device   g22v10;

/* Inputs */
Pin 1  = A15;
Pin 2  = A14;
Pin 3  = A13;
Pin 4  = MREQ;        /* Active Low */
Pin 5  = RAM_SHADOW;  /* 1 = Shadow Mode */
Pin 6  = ROM_DIS;     /* 1 = Disable ROM */
Pin 7  = CART_DETECT; /* 1 = Cartridge Present */
Pin 8  = PROG;        /* 1 = Programming Mode */
Pin 9  = RD;          /* Active Low */
Pin 10 = WR;          /* Active Low */

/* Banking Latch Inputs (Reassigned to free pins) */
Pin 11 = BANK_Q0;
Pin 13 = BANK_Q1;
Pin 14 = BANK_Q2;

/* Outputs */
Pin 23 = !SRAM_CS;
Pin 22 = !ROM_CS;
Pin 21 = !CART_CS;

/* RAM Banking Address Lines (To RAM A16-A18) */
Pin 15 = RAM_A16;
Pin 16 = RAM_A17;
Pin 17 = RAM_A18;

/* Address Definitions */
BIOS_RANGE = !A15 & (!A14 # !A13);    /* $0000 - $5FFF */
COMMON_RAM = !A15 & !A14 & !A13;      /* $0000 - $1FFF (Bottom 8K) */
UPPER_32K  = A15;                     /* $8000 - $FFFF */
RAM_ONLY   = !A15 & A14 & A13;        /* $6000 - $7FFF */

/* Logic Conditions */
ALL_RAM_MODE = ROM_DIS & !CART_DETECT;
FORCE_BANK0  = COMMON_RAM & ALL_RAM_MODE;

/* Equations */
/* Force RAM Address to 0 in Common Area, otherwise pass Latch */
RAM_A16 = BANK_Q0 & !FORCE_BANK0;
RAM_A17 = BANK_Q1 & !FORCE_BANK0;
RAM_A18 = BANK_Q2 & !FORCE_BANK0;

ROM_CS = !MREQ & (PROG # (RD & !ROM_DIS & (RAM_SHADOW # BIOS_RANGE)));

CART_CS = !MREQ & !PROG & UPPER_32K & CART_DETECT & !RAM_SHADOW;

SRAM_CS = !MREQ & !PROG & (
            (RAM_SHADOW & WR) 
          # (!RAM_SHADOW & (
               (BIOS_RANGE & (WR # ROM_DIS))
             # RAM_ONLY
             # (UPPER_32K & !CART_DETECT)
            ))
          );
```

### B. I/O Decoder (`Z80_IO_DECODE`)

_Implements the I/O Map and Sound/Controller split._

_Correction:_ `RESET` logic updated to active-low input but active-high internal check.

Code snippet

```
Name     Z80_IO_DECODE;
Partno   006;
Date     2026-01-18;
Revision 03;
Designer HomeBrew;
Company  Z80 Project;
Assembly IO Board;
Location U_IO_GAL;
Device   g22v10;

/* ----------------------------------------------------------- */
/* Inputs */
/* ----------------------------------------------------------- */
Pin 1  = A7;
Pin 2  = A6;
Pin 3  = A5;
Pin 4  = A4;

/* Control Signals (Active Low on Bus) */
Pin 5  = !IORQ;
Pin 6  = !M1;
Pin 7  = !RD;
Pin 8  = !WR;

/* RESET Logic:
   The Z80 /RESET pin is Active Low.
   Pin 8 = !RESET means the variable 'RESET' is TRUE when Pin 8 is LOW.
*/
Pin 9  = !RESET; 

/* ----------------------------------------------------------- */
/* Outputs (Active Low Chip Selects) */
/* ----------------------------------------------------------- */

/* Memory Banking Latch Control */
Pin 23 = !CS_MEMBANK_WR; /* Write: Clocks the 74HC273 (Rising Edge) */
Pin 16 = !CS_MEMBANK_RD; /* Read:  Enables the 74HC244 (Active Low Level) */

/* Peripherals */
Pin 22 = !CS_SIO1;       /* SD Card / USB Port */
Pin 21 = !CS_CTC;        /* Counter/Timer */
Pin 20 = !CS_CART_IO;    /* Cartridge Expansion */
Pin 19 = !CS_VDP;        /* Video Processor */
Pin 18 = !CS_SIO0;       /* User Port / Console */
Pin 17 = !CS_SOUND;      /* Sound Generators (Write Only) */
	Pin 15 = !CS_CTRL;       /* Controller (Read Only) */

/* ----------------------------------------------------------- */
/* Logic Equations */
/* ----------------------------------------------------------- */

/* ValidIO: IORQ is Low (Active), M1 is High (Inactive), NOT in Reset */
ValidIO = IORQ & !M1 & !RESET;

/* Address Decoding Blocks */
Block_00 = !A7 & !A6 & !A5 & !A4; /* $00-$0F */
Block_10 = !A7 & !A6 & !A5 & A4;  /* $10-$1F */
Block_20 = !A7 & !A6 &  A5 & !A4; /* $20-$2F */
Block_30 = !A7 & !A6 &  A5 & A4;  /* $30-$3F */
Block_40 = !A7 &  A6 & !A5 & !A4; /* $40-$4F */
Block_50 = !A7 &  A6 & !A5 & A4;  /* $50-$5F */
Block_60 = !A7 &  A6 &  A5 & !A4; /* $60-$6F */
Block_70 = !A7 &  A6 &  A5 & A4;  /* $70-$7F */
Block_80 =  A7 & !A6 & !A5 & !A4; /* $80-$8F */
Block_90 =  A7 & !A6 & !A5 & A4;  /* $90-$9F */
Block_A0 =  A7 & !A6 &  A5 & !A4; /* $A0-$AF */
Block_B0 =  A7 & !A6 &  A5 & A4;  /* $B0-$BF */
Block_C0 =  A7 &  A6 & !A5 & !A4; /* $C0-$CF */
Block_D0 =  A7 &  A6 & !A5 & A4;  /* $D0-$DF */
Block_E0 =  A7 &  A6 &  A5 & !A4; /* $E0-$EF */
Block_F0 =  A7 &  A6 &  A5 & A4;  /* $F0-$FF */


/* 1. Memory Banking ($00-$1F) */
/* Write: ValidIO + Block00 + Write Strobe */
CS_MEMBANK_WR = ValidIO & Block_00 & WR;

/* Read: ValidIO + Block00 + Read Strobe */
CS_MEMBANK_RD = ValidIO & Block_00 & RD;


/* 2. Standard Peripherals */
CS_SIO0       = ValidIO & Block_20;
CS_SIO1       = ValidIO & Block_30;
CS_CTC        = ValidIO & Block_40;
CS_CART_IO    = ValidIO & Block_60;
CS_VDP        = ValidIO & Block_A0;
CS_VDP        = ValidIO & Block_B0;

/* CS_SOUND is selected for $E0-$FF (Write Only) */
CS_SOUND      = ValidIO & Block_E0 & WR;
CS_SOUND      = ValidIO & Block_F0 & WR;

/* CS_CTRL is selected for $E0-$FF (Read Only) */
CS_CTRL      = ValidIO & Block_E0 & RD;
CS_CTRL      = ValidIO & Block_F0 & RD;
```
