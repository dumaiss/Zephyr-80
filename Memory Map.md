
### Memory

#### Memory Banking

Memory Banking is configured by writing to port 0x00:

| Data  | Function                                                                                           |
| ----- | -------------------------------------------------------------------------------------------------- |
| D0-D2 | RAM Bank Selection A16-A18                                                                         |
| D3    | Full Shadow RAM (All 64KiB are Read from ROM, Write to RAM)<br>0 = Disable (Default)<br>1 = Enable |
| D4    | 0 = Enable ROM (Default)<br>1 = Disable ROM                                                        |
| D5-D7 | ROM Bank Selection A16-A18                                                                         |

Memory Map at boot (without a cartridge : CART_MEM_EN low)

| Start | End   | Description                                       |
| ----- | ----- | ------------------------------------------------- |
| 00000 | 01FFF | BIOS ROM / RAM (Writes go to RAM, Reads from ROM) |
| 02000 | 03FFF | BIOS ROM / RAM (Writes go to RAM, Reads from ROM) |
| 04000 | 05FFF | BIOS ROM / RAM (Writes go to RAM, Reads from ROM) |
| 06000 | 07FFF | RAM                                               |
| 08000 | 09FFF | RAM                                               |
| 0A000 | 0BFFF | RAM                                               |
| 0C000 | 0DFFF | RAM                                               |
| 0E000 | 0FFFF | RAM                                               |

Memory Map at boot (with a cartridge: CART_MEM_EN high)

| Start | End   | Description                                       |
| ----- | ----- | ------------------------------------------------- |
| 00000 | 01FFF | BIOS ROM / RAM (Writes go to RAM, Reads from ROM) |
| 02000 | 03FFF | BIOS ROM / RAM (Writes go to RAM, Reads from ROM) |
| 04000 | 05FFF | BIOS ROM / RAM (Writes go to RAM, Reads from ROM) |
| 06000 | 07FFF | RAM                                               |
| 08000 | 09FFF | Cartridge                                         |
| 0A000 | 0BFFF | Cartridge                                         |
| 0C000 | 0DFFF | Cartridge                                         |
| 0E000 | 0FFFF | Cartridge                                         |

```
Name     Z80_MEM_DECODE;
Partno   004;
Date     2026-01-17;
Revision 04;
Designer HomeBrew;
Company  Z80 Project;
Assembly Memory Board;
Location U_MEM_GAL;
Device   g22v10;

/* ----------------------------------------------------------- */
/* Inputs */
/* ----------------------------------------------------------- */
Pin 1  = A15;
Pin 2  = A14;
Pin 3  = A13;
Pin 4  = MREQ;        /* Active Low */

/* Control Signals */
Pin 5  = RAM_SHADOW;  /* 1 = Full Shadow Mode (Read ROM / Write RAM globally) */
Pin 6  = ROM_DIS;     /* 1 = Disable ROM globally */
Pin 7  = CART_DETECT; /* 1 = Cartridge Inserted (Overrides RAM in Upper 32K) */
Pin 8  = PROG;        /* 1 = Programming Mode (Force ROM Read/Write, Disable RAM/Cart) */
Pin 9  = RD;          /* Active Low */
Pin 10 = WR;          /* Active Low */

/* ----------------------------------------------------------- */
/* Outputs (Active Low Chip Selects) */
/* ----------------------------------------------------------- */
Pin 23 = !SRAM_CS;
Pin 22 = !ROM_CS;
Pin 21 = !CART_CS;

/* ----------------------------------------------------------- */
/* Address Range Definitions */
/* ----------------------------------------------------------- */

/* BIOS_RANGE: 0x0000 - 0x5FFF (24KB) */
/* Active when A15=0 AND we are NOT in the 0x6000-0x7FFF range (011) */
BIOS_RANGE = !A15 & (!A14 # !A13);

/* RAM_ONLY_RANGE: 0x6000 - 0x7FFF (8KB) */
/* Active when A15=0, A14=1, A13=1 */
RAM_ONLY_RANGE = !A15 & A14 & A13;

/* UPPER_32K: 0x8000 - 0xFFFF (32KB) */
/* Active when A15=1 */
UPPER_32K = A15;

/* ----------------------------------------------------------- */
/* Logic Equations */
/* ----------------------------------------------------------- */

/* ROM CHIP SELECT
   Active (Low) when MREQ is active AND:
   
   CASE A: Programming Mode (PROG=1)
      - Active on ALL cycles (Read and Write)
      - Active on ALL Addresses
      
   CASE B: Normal Operation (PROG=0)
      - Must be a READ cycle (RD)
      - ROM must be enabled (!D4_ROM_DIS)
      - Address must be BIOS_RANGE OR Shadow Mode must be Active
*/
ROM_CS = !MREQ & (
           PROG
         # (RD & !ROM_DIS & (RAM_SHADOW # BIOS_RANGE))
         );


/* CARTRIDGE CHIP SELECT
   Active (Low) when:
   1. MREQ is active
   2. Programming Mode is OFF (!PROG)
   3. Address is in Upper 32K
   4. Cartridge is Detected
   5. Full Shadow Mode is OFF (Shadow overrides Cart)
*/
CART_CS = !MREQ & !PROG & UPPER_32K & CART_DETECT & !RAM_SHADOW;


/* SRAM CHIP SELECT
   Active (Low) when MREQ is active AND Programming Mode is OFF (!PROG) AND:
   
   CASE A: Full Shadow Mode (D3=1)
      - Active only on WRITES (Read goes to ROM)
      
   CASE B: Normal Mode (D3=0)
      1. BIOS_RANGE:
         - Active on WRITE (Standard Shadow behavior)
         - OR if ROM is Disabled (D4=1) (RAM takes over)
      2. RAM_ONLY_RANGE:
         - Always Active
      3. UPPER_32K:
         - Active only if Cartridge is NOT detected
*/
SRAM_CS = !MREQ & !PROG & (
            (RAM_SHADOW & WR) 
          # (!RAM_SHADOW & (
               (BIOS_RANGE & (WR # ROM_DIS))
             # RAM_ONLY_RANGE
             # (UPPER_32K & !CART_DETECT)
            ))
          );
```


### IO Ports

| Start | End | Description                                                                                                                                                                                                                                                                   | Read/Write? |
| ----- | --- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------- |
| $00   | $1F | UNUSED                                                                                                                                                                                                                                                                        | R           |
| $00   | $1F | Memory Bank Switch                                                                                                                                                                                                                                                            | W           |
| $20   | $3F | SD Card / User Port<br><br>$20: SD Card Data<br>$21: User Port Data<br>$22: SD Card Control<br>$23: User Port Control                                                                                                                                                         | R           |
| $20   | $3F | SD Card / User Port<br><br>$20: SD Card Data<br>$21: User Port Data<br>$22: SD Card Control<br>$23: User Port Control                                                                                                                                                         | W           |
| $40   | $5F | CTC<br><br>$40: USR Port Baud Clk<br>$41: CTC Channel 1<br>$42: CTC Channel 2<br>$43: CTC Channel 3                                                                                                                                                                           | R           |
| $40   | $5F | CTC<br><br>$40: USR Port Baud Clk<br>$41: CTC Channel 1<br>$42: CTC Channel 2<br>$43: CTC Channel 3                                                                                                                                                                           | W           |
| $60   | $7F | Cart (IO)                                                                                                                                                                                                                                                                     | R           |
| $60   | $7F | Cart (IO)                                                                                                                                                                                                                                                                     | W           |
| $80   | $9F | UNUSED                                                                                                                                                                                                                                                                        | R           |
| $80   | $9F | UNUSED                                                                                                                                                                                                                                                                        | W           |
| $A0   | $BF | Video (VDC) registers                                                                                                                                                                                                                                                         | R           |
| $A0   | $BF | Video (VDC) registers                                                                                                                                                                                                                                                         | W           |
| $C0   | $DF | USB \/ Console \/ GPIO<br><br>$C0: USB/GPIO Data Port<br>$C1: Console Data Port<br>$C2: USB/GPIO Control Port<br>$C3: Console Control Port<br><br>GPIO works by sending commands<br>over $C0 and includes software<br>RESET and POWER OFF commands                            | R           |
| $C0   | $DF | USB \/ Console \/ GPIO<br><br>$C0: USB/GPIO Data Port<br>$C1: Console Data Port<br>$C2: USB/GPIO Control Port<br>$C3: Console Control Port<br><br>GPIO works by sending commands                                                                                              | W           |
| $E0   | $FF | USB \/ Console \/ GPIO<br><br>$C0: USB/GPIO Data Port<br>$C1: Console Data Port<br>$C2: USB/GPIO Control Port<br>$C3: Console Control Port<br><br>GPIO works by sending commands<br><br>Read Only -- for compatibility with ColecoVision.<br>Controllers are visible from $E0 | R           |
| $E0   | $FF | Sound<br><br>$FE: Channel 1 <br>$FF: Channel 0<br><br>* There are 2 SN76489N sound generators*                                                                                                                                                                                | W           |

```
Name     Z80_IO_DECODE;
Partno   005;
Date     2026-01-17;
Revision 01;
Designer HomeBrew;
Company  Z80 Project;
Assembly IO Board;
Location U_IO_GAL;
Device   g22v10;

/* ----------------------------------------------------------- */
/* Inputs */
/* ----------------------------------------------------------- */

/* Address Bus (A7..A5 are sufficient for 32-byte blocks) */
Pin 1  = A7;
Pin 2  = A6;
Pin 3  = A5;

/* Control Signals */
Pin 4  = !IORQ;      /* Active Low Input */
Pin 5  = !M1;        /* Active Low Input (Must be High for Valid I/O) */
Pin 6  = !RD;        /* Active Low Input */
Pin 7  = !WR;        /* Active Low Input */
Pin 8  = RESET;      /* Active Low Reset (Forces all outputs off) */

/* ----------------------------------------------------------- */
/* Outputs (Active Low Chip Selects) */
/* ----------------------------------------------------------- */

Pin 23 = !CS_MEMBANK;    /* $00-$1F (Write Only) */
Pin 22 = !CS_SIO1;       /* $20-$3F */
Pin 21 = !CS_CTC;        /* $40-$5F */
Pin 20 = !CS_CART_IO;    /* $60-$7F */
Pin 19 = !CS_VDP;        /* $A0-$BF (Note: $80-$9F is skipped/unused) */
Pin 18 = !CS_SIO0;       /* $C0-$DF (R/W) AND $E0-$FF (Read Only) */
Pin 17 = !CS_SOUND;      /* $E0-$FF (Write Only) */

/* ----------------------------------------------------------- */
/* Intermediate Definitions */
/* ----------------------------------------------------------- */

/* A Valid I/O Cycle occurs when:
   1. IORQ is Active (Low)
   2. M1 is Inactive (High) -> Distinguishes I/O from IntAck
   3. RESET is Inactive (Low)
*/
ValidIO = IORQ & !M1 & !RESET;

/* Address Block Definitions (32 Bytes each) */
/* A7 A6 A5 */
Block_00 = !A7 & !A6 & !A5;  /* $00 - $1F */
Block_20 = !A7 & !A6 &  A5;  /* $20 - $3F */
Block_40 = !A7 &  A6 & !A5;  /* $40 - $5F */
Block_60 = !A7 &  A6 &  A5;  /* $60 - $7F */
/* Block_80 =  A7 & !A6 & !A5;  $80 - $9F (Unused) */
Block_A0 =  A7 & !A6 &  A5;  /* $A0 - $BF */
Block_C0 =  A7 &  A6 & !A5;  /* $C0 - $DF */
Block_E0 =  A7 &  A6 &  A5;  /* $E0 - $FF */

/* ----------------------------------------------------------- */
/* Logic Equations */
/* ----------------------------------------------------------- */

/* $00 - $1F: Memory Bank Switch 
   WRITE ONLY. Reads are unused. 
*/
CS_MEMBANK = ValidIO & Block_00 & WR;

/* $20 - $3F: SD Card & User Port 
   Read/Write 
*/
CS_SIO1 = ValidIO & Block_20;

/* $40 - $5F: CTC (Counter Timer)
   Read/Write
*/
CS_CTC = ValidIO & Block_40;

/* $60 - $7F: Cartridge I/O Expansion
   Read/Write
*/
CS_CART_IO = ValidIO & Block_60;

/* $A0 - $BF: Video (VDC)
   Read/Write
*/
CS_VDP = ValidIO & Block_A0;

/* $C0 - $DF: USB / Console / GPIO
   $E0 - $FF: Mirror of above (READ ONLY)
   
   Logic: Select if we are in Block C0 OR (Block E0 AND Reading)
*/
CS_SIO0 = ValidIO & (Block_C0 # (Block_E0 & RD));

/* $E0 - $FF: Sound Generators
   WRITE ONLY. (Reads go to USB Mirror above)
*/
CS_SOUND = ValidIO & Block_E0 & WR;
```