#ifndef CONFIG_H
#define CONFIG_H

/* PIC18F57Q84 HFINTOSC is configured to 64 MHz in platform_init(). */
#define _XTAL_FREQ 64000000UL

/* ===========================================================================
 * U15 PIC18F57Q84-I/PT pin map
 * ===========================================================================
 *
 * Net names below are the schematic net names.  Macro names keep the "HOST_"
 * prefix on RESET/NMI because <xc.h> already defines RESET() and NMI as
 * reserved identifiers.
 *
 * Polarity follows the schematic overbars.  The barred, active-low nets are the
 * five selects, USB_INT, /SYNCA, /SYNCB, /CTSA, /CTSB, /DCDA, /DCDB,
 * /SIO1A_INT, /SIO1B_INT, RESET and /NMI.  The unbarred, active-high nets are
 * NMI_RQ, RESET_HIGH, PWR_OFF and SHUTDOWN_RQ.
 *
 *   Pin  Port  Net             Dir  Notes
 *   ---  ----  --------------  ---  ---------------------------------------
 *    21  RA0   /USB_INT         I   from USB bridge
 *    22  RA1   /CTRL_LAT_CS     O   select / RCLK, controller latch
 *    23  RA2   /IO_SD_CS        O   select, SD card
 *    24  RA3   /IO_USB_CS       O   select, USB bridge
 *    25  RA4   /SIOB_CS         O   select, SIO1 channel B
 *    26  RA5   /SIOA_CS         O   select, SIO1 channel A
 *    33  RA6   /SYNCA           O   SIO1/A External Sync
 *    32  RA7   /SYNCB           O   SIO1/B External Sync
 *
 *     8  RB0   /CTSA            O   SIO1/A clear-to-send
 *     9  RB1   SIO_MOSI         O   shared bus data, PIC -> device
 *    10  RB2   SIO_MISO         I   shared bus data, device -> PIC
 *    11  RB3   SIO_SCK          O   shared bus clock
 *    16  RB4   /DCDA            O   SIO1/A data-carrier-detect
 *    17  RB5   /CTSB            O   SIO1/B clear-to-send
 *    18  RB6   ICSPCLK          -   programming
 *    19  RB7   ICSPDAT          -   programming
 *
 *    34  RC0   unassigned
 *    35  RC1   unassigned
 *    40  RC2   no connect
 *    41  RC3   no connect
 *    46  RC4   unassigned
 *    47  RC5   unassigned
 *    48  RC6   no connect
 *     1  RC7   no connect
 *
 *    42  RD0   GPIO7            -   general-purpose header, bit 7
 *    43  RD1   GPIO6            -
 *    44  RD2   GPIO5            -
 *    45  RD3   GPIO4            -
 *     2  RD4   GPIO3            -
 *     3  RD5   GPIO2            -
 *     4  RD6   GPIO1            -
 *     5  RD7   GPIO0            -   general-purpose header, bit 0
 *
 *    27  RE0   /DCDB            O   SIO1/B data-carrier-detect
 *    28  RE1   unassigned
 *    29  RE2   no connect
 *    20  RE3   VPP / /MCLR      -   programming
 *
 *    36  RF0   /SIO1B_INT       I   SIO1/B service request
 *    37  RF1   /SIO1A_INT       I   SIO1/A service request
 *    38  RF2   RESET            O   active-low host reset
 *    39  RF3   RESET_HIGH       O   active-high complementary host reset
 *    12  RF4   NMI_RQ           I   NMI request in
 *    13  RF5   /NMI             O   active-low NMI to the Z80
 *    14  RF6   PWR_OFF          O   LEVEL signal to the PMU (not a pulse)
 *    15  RF7   SHUTDOWN_RQ      I   shutdown request in
 *
 *     6  VSS      7 VDD      30 VDD      31 VSS
 * =========================================================================== */

/* ---------------------------------------------------------------------------
 * Host reset pair (RF2 / RF3)
 *
 * RESET       RF2  active-low  — drives Z80 and bus reset low
 * RESET_HIGH  RF3  active-high — complementary reset signal, driven high
 *             during the same 100 ms reset pulse, then low
 * --------------------------------------------------------------------------- */
#define HOST_RESET_TRIS          TRISFbits.TRISF2
#define HOST_RESET_ANSEL         ANSELFbits.ANSELF2
#define HOST_RESET_LAT           LATFbits.LATF2
#define HOST_RESET_ASSERTED      0
#define HOST_RESET_IDLE          1

#define HOST_RESET_HIGH_TRIS     TRISFbits.TRISF3
#define HOST_RESET_HIGH_ANSEL    ANSELFbits.ANSELF3
#define HOST_RESET_HIGH_LAT      LATFbits.LATF3
#define HOST_RESET_HIGH_ASSERTED 1
#define HOST_RESET_HIGH_IDLE     0

/* ---------------------------------------------------------------------------
 * Shared serial bus (RB1 / RB2 / RB3)
 *
 * One clock/data pair is shared by SIO1/A, SIO1/B, the SD card, the USB bridge
 * and the controller latch.  Exactly one of the *_CS lines below selects the
 * device that owns the bus for a transfer.
 *
 * SIO_MOSI  RB1  output   PIC -> selected device   (Z80 SIO1/B RXDB)
 * SIO_MISO  RB2  input    PIC <- selected device   (Z80 SIO1/B TXDB)
 * SIO_SCK   RB3  output   PIC -> '125 -> selected device; idle HIGH because
 *                         the gated SIO clocks have 100k pull-ups
 * --------------------------------------------------------------------------- */
#define SIO_MOSI_TRIS        TRISBbits.TRISB1
#define SIO_MOSI_ANSEL       ANSELBbits.ANSELB1
#define SIO_MOSI_LAT         LATBbits.LATB1
#define SIO_MOSI_PORT        PORTBbits.RB1

#define SIO_MISO_TRIS        TRISBbits.TRISB2
#define SIO_MISO_ANSEL       ANSELBbits.ANSELB2
#define SIO_MISO_LAT         LATBbits.LATB2
#define SIO_MISO_PORT        PORTBbits.RB2

#define SIO_SCK_TRIS         TRISBbits.TRISB3
#define SIO_SCK_ANSEL        ANSELBbits.ANSELB3
#define SIO_SCK_LAT          LATBbits.LATB3
#define SIO_SCK_PORT         PORTBbits.RB3

/* ---------------------------------------------------------------------------
 * SPI2 module mapping for the SIO bus
 *
 * SPI2 is the right module for this bus, not SPI1: the silicon's reset-default
 * PPS inputs for SPI2 are already SCK = RB3 and SDI = RB2, which is exactly how
 * this board is wired.  (SPI1's defaults are RC3/RC4 — the port C peripheral
 * bus — so leave SPI1 for the SD card, USB HID and controller latch.)
 *
 * Because of that, SPI2SCKPPS and SPI2SDIPPS need no configuration at all.
 * Only the two *output* routes have to be claimed, and master mode needs SCK
 * routed out as well as read back in.
 *
 * PPSLOCKED resets to 0 and this firmware never locks PPS, so no unlock
 * sequence is required.  PPS1WAY = OFF also permits re-mapping at run time,
 * which the hybrid transmit path relies on to hand RB1/RB3 back and forth
 * between the SPI module and LATB.
 * --------------------------------------------------------------------------- */
#define SIO_MOSI_PPS         RB1PPS   /* output route for SPI2 SDO */
#define SIO_SCK_PPS          RB3PPS   /* output route for SPI2 SCK */
#define SIO_PPS_SRC_LAT      0x00u    /* RxyPPS = 0 gives the pin back to LATxy */
/* PPS input encoding: port B = 001b, pin 3 = 011b -> 00 001 011b.
 * Timer1 uses this to count the actual RB3 pin edges, including any edge a PPS
 * handover or SPI enable transition might create outside a byte transfer. */
#define SIO_SCK_T1CKIPPS     0x0Bu

/* ---------------------------------------------------------------------------
 * Port C external peripheral bus (SPI1)
 *
 * Shared by the SD card, the USB HID bridge and the controller latch, with the
 * selects on port A (/IO_SD_CS, /IO_USB_CS, /CTRL_LAT_CS).
 *
 * SPI1 is the right module here for the same reason SPI2 is right for the SIO
 * bus: its reset-default PPS inputs are already SCK = RC3 and SDI = RC4, so
 * SPI1SCKPPS and SPI1SDIPPS need no configuration.  Only the two output routes
 * are claimed.
 *
 * PPS output source codes from Table 21-2 in DS40002213D; both SPI1 outputs are
 * available on port C for the 48-pin package:
 *
 *   0x32  SPI1 SDO   B, C
 *   0x31  SPI1 SCK   B, C
 * --------------------------------------------------------------------------- */
#define PERIPH_SCK_TRIS      TRISCbits.TRISC3
#define PERIPH_SCK_ANSEL     ANSELCbits.ANSELC3
#define PERIPH_SCK_LAT       LATCbits.LATC3
#define PERIPH_SCK_PPS       RC3PPS

#define PERIPH_MISO_TRIS     TRISCbits.TRISC4
#define PERIPH_MISO_ANSEL    ANSELCbits.ANSELC4
#define PERIPH_MISO_PORT     PORTCbits.RC4

#define PERIPH_MOSI_TRIS     TRISCbits.TRISC5
#define PERIPH_MOSI_ANSEL    ANSELCbits.ANSELC5
#define PERIPH_MOSI_LAT      LATCbits.LATC5
#define PERIPH_MOSI_PPS      RC5PPS

#define PERIPH_PPS_SRC_SPI1_SDO  0x32u
#define PERIPH_PPS_SRC_SPI1_SCK  0x31u

/* SD card status inputs, not used yet. */
#define SD_PRESENT_TRIS      TRISCbits.TRISC0
#define SD_PRESENT_ANSEL     ANSELCbits.ANSELC0
#define SD_PRESENT_PORT      PORTCbits.RC0

/* SD_BUSY is an OUTPUT driving an activity LED directly, active high.
 * The PIC raises it while it is talking to the card, so SD access is visible
 * without a debugger. */
#define SD_BUSY_TRIS         TRISCbits.TRISC1
#define SD_BUSY_ANSEL        ANSELCbits.ANSELC1
#define SD_BUSY_LAT          LATCbits.LATC1
#define SD_BUSY_ASSERTED     1
#define SD_BUSY_IDLE         0

/* ---------------------------------------------------------------------------
 * External Sync strobes (RA6 / RA7)
 *
 * The SIO is configured by the BIOS for External Sync, which makes /SYNC an
 * input on the SIO side.  The PIC provides the sync edge that tells the SIO
 * where character assembly starts.
 * --------------------------------------------------------------------------- */
#define SYNCA_TRIS           TRISAbits.TRISA6
#define SYNCA_ANSEL          ANSELAbits.ANSELA6
#define SYNCA_LAT            LATAbits.LATA6
#define SYNCA_ASSERTED       0
#define SYNCA_IDLE           1

#define SYNCB_TRIS           TRISAbits.TRISA7
#define SYNCB_ANSEL          ANSELAbits.ANSELA7
#define SYNCB_LAT            LATAbits.LATA7
#define SYNCB_ASSERTED       0
#define SYNCB_IDLE           1

/* ---------------------------------------------------------------------------
 * Shared bus selects (RA1 .. RA5) — all active-low, all idle high
 *
 * Every select is driven idle-high at boot so no inactive device sees a select
 * while SIO_SCK is clocking another one.
 *
 * CTRL_LAT_CS doubles as the 74HC595 RCLK.  The 595 latches on RCLK's rising
 * edge, which is the deselect edge: hold the select asserted for the shift,
 * then release it to commit the shift register to the outputs.
 * --------------------------------------------------------------------------- */
#define CTRL_LAT_CS_TRIS     TRISAbits.TRISA1
#define CTRL_LAT_CS_ANSEL    ANSELAbits.ANSELA1
#define CTRL_LAT_CS_LAT      LATAbits.LATA1
#define CTRL_LAT_CS_ASSERTED 0
#define CTRL_LAT_CS_IDLE     1

#define IO_SD_CS_TRIS        TRISAbits.TRISA2
#define IO_SD_CS_ANSEL       ANSELAbits.ANSELA2
#define IO_SD_CS_LAT         LATAbits.LATA2
#define IO_SD_CS_ASSERTED    0
#define IO_SD_CS_IDLE        1

#define IO_USB_CS_TRIS       TRISAbits.TRISA3
#define IO_USB_CS_ANSEL      ANSELAbits.ANSELA3
#define IO_USB_CS_LAT        LATAbits.LATA3
#define IO_USB_CS_ASSERTED   0
#define IO_USB_CS_IDLE       1

#define SIOB_CS_TRIS         TRISAbits.TRISA4
#define SIOB_CS_ANSEL        ANSELAbits.ANSELA4
#define SIOB_CS_LAT          LATAbits.LATA4
#define SIOB_CS_ASSERTED     0
#define SIOB_CS_IDLE         1

#define SIOA_CS_TRIS         TRISAbits.TRISA5
#define SIOA_CS_ANSEL        ANSELAbits.ANSELA5
#define SIOA_CS_LAT          LATAbits.LATA5
#define SIOA_CS_ASSERTED     0
#define SIOA_CS_IDLE         1

/* ---------------------------------------------------------------------------
 * USB bridge interrupt (RA0) — active-low input
 *
 * The bridge asserts this line when a new HID report is ready, so the firmware
 * does not have to poll the bridge while the keyboard is idle.
 * --------------------------------------------------------------------------- */
#define USB_INT_TRIS         TRISAbits.TRISA0
#define USB_INT_ANSEL        ANSELAbits.ANSELA0
#define USB_INT_PORT         PORTAbits.RA0
#define USB_INT_ACTIVE       0   /* low = bridge has data ready */

/* ---------------------------------------------------------------------------
 * SIO1 modem-control outputs (RB0 / RB4 / RB5 / RE0)
 *
 * /CTS and /DCD are inputs on the Z80 SIO, so the PIC drives all four.  They
 * are parked deasserted at boot; the Auto Enables configuration in the BIOS
 * decides what they gate.
 * --------------------------------------------------------------------------- */
#define CTSA_TRIS            TRISBbits.TRISB0
#define CTSA_ANSEL           ANSELBbits.ANSELB0
#define CTSA_LAT             LATBbits.LATB0
#define CTSA_ASSERTED        0
#define CTSA_IDLE            1

#define CTSB_TRIS            TRISBbits.TRISB5
#define CTSB_ANSEL           ANSELBbits.ANSELB5
#define CTSB_LAT             LATBbits.LATB5
#define CTSB_ASSERTED        0
#define CTSB_IDLE            1

#define DCDA_TRIS            TRISBbits.TRISB4
#define DCDA_ANSEL           ANSELBbits.ANSELB4
#define DCDA_LAT             LATBbits.LATB4
#define DCDA_ASSERTED        0
#define DCDA_IDLE            1

#define DCDB_TRIS            TRISEbits.TRISE0
#define DCDB_ANSEL           ANSELEbits.ANSELE0
#define DCDB_LAT             LATEbits.LATE0
#define DCDB_ASSERTED        0
#define DCDB_IDLE            1

/* ---------------------------------------------------------------------------
 * SIO1 service requests (RF0 / RF1) — active-low inputs
 *
 * The Z80 BIOS asserts the channel's interrupt line when it wants one command
 * transaction.  Channel B carries the IOCALL mailbox; channel A is wired but
 * unused by the current firmware.
 * --------------------------------------------------------------------------- */
#define SIO1B_INT_TRIS       TRISFbits.TRISF0
#define SIO1B_INT_ANSEL      ANSELFbits.ANSELF0
#define SIO1B_INT_PORT       PORTFbits.RF0
#define SIO1B_INT_ACTIVE     0   /* low = Z80 is requesting Command channel service */

#define SIO1A_INT_TRIS       TRISFbits.TRISF1
#define SIO1A_INT_ANSEL      ANSELFbits.ANSELF1
#define SIO1A_INT_PORT       PORTFbits.RF1
#define SIO1A_INT_ACTIVE     0

/* ---------------------------------------------------------------------------
 * NMI pair (RF4 / RF5)
 *
 * NMI_RQ is a request into the PIC; /NMI is the active-low line the PIC drives
 * to the Z80.  The PIC owns the policy between the two.
 * --------------------------------------------------------------------------- */
#define NMI_RQ_TRIS          TRISFbits.TRISF4
#define NMI_RQ_ANSEL         ANSELFbits.ANSELF4
#define NMI_RQ_PORT          PORTFbits.RF4
#define NMI_RQ_ACTIVE        1   /* high = something is requesting an NMI */

#define HOST_NMI_TRIS        TRISFbits.TRISF5
#define HOST_NMI_ANSEL       ANSELFbits.ANSELF5
#define HOST_NMI_LAT         LATFbits.LATF5
#define HOST_NMI_ASSERTED    0
#define HOST_NMI_IDLE        1

/* ---------------------------------------------------------------------------
 * Power control (RF6 / RF7)
 *
 * BOTH SIGNALS ARE ACTIVE LOW, deliberately and symmetrically.
 *
 * Inverted logic on both lets each end hold its own input at the deasserted
 * level with a programmed pull-up, so a net with an unpowered or high-Z partner
 * reads "nothing is being asked" rather than floating. Neither MCU has
 * programmable pull-downs -- the PIC has WPUA..WPUF and nothing else, the AVR
 * likewise -- so active low is the only polarity that can be made fail-safe in
 * firmware alone.
 *
 *   /PWR_OFF      out  HIGH = keep power on      LOW = remove power
 *   /SHUTDOWN_RQ  in   HIGH = nothing requested  LOW = please shut down
 *
 * /SHUTDOWN_RQ is ONLY a shutdown request. It does not gate whether the system
 * may run: the PMU powers the machine when PWR_OK is good and that is the whole
 * of the start-up story. An earlier reading of it as a run/reset gate is what
 * made the boot sequence look like it needed an arming step; it does not.
 * --------------------------------------------------------------------------- */
#define PWR_OFF_TRIS         TRISFbits.TRISF6
#define PWR_OFF_ANSEL        ANSELFbits.ANSELF6
#define PWR_OFF_LAT          LATFbits.LATF6
#define PWR_OFF_PORT         PORTFbits.RF6
#define PWR_OFF_ASSERTED     0   /* LOW  = remove power */
#define PWR_OFF_IDLE         1   /* HIGH = keep power on */

#define SHUTDOWN_RQ_TRIS     TRISFbits.TRISF7
#define SHUTDOWN_RQ_ANSEL    ANSELFbits.ANSELF7
#define SHUTDOWN_RQ_PORT     PORTFbits.RF7
#define SHUTDOWN_RQ_WPU      WPUFbits.WPUF7
#define SHUTDOWN_RQ_ACTIVE   0   /* LOW = the PMU is asking us to shut down */

/* ---------------------------------------------------------------------------
 * GPIO header (Port D)
 *
 * The header numbering runs opposite to the port bit numbering: GPIO0 is RD7
 * and GPIO7 is RD0.  Read or write the whole header through IOC_GPIO_PORT /
 * IOC_GPIO_LAT and reverse the bits, or use the per-line macros.
 * --------------------------------------------------------------------------- */
#define IOC_GPIO_TRIS        TRISD
#define IOC_GPIO_ANSEL       ANSELD
#define IOC_GPIO_LAT         LATD
#define IOC_GPIO_PORT        PORTD

#define GPIO0_TRIS           TRISDbits.TRISD7
#define GPIO0_LAT            LATDbits.LATD7
#define GPIO0_PORT           PORTDbits.RD7

#define GPIO1_TRIS           TRISDbits.TRISD6
#define GPIO1_LAT            LATDbits.LATD6
#define GPIO1_PORT           PORTDbits.RD6

#define GPIO2_TRIS           TRISDbits.TRISD5
#define GPIO2_LAT            LATDbits.LATD5
#define GPIO2_PORT           PORTDbits.RD5

#define GPIO3_TRIS           TRISDbits.TRISD4
#define GPIO3_LAT            LATDbits.LATD4
#define GPIO3_PORT           PORTDbits.RD4

#define GPIO4_TRIS           TRISDbits.TRISD3
#define GPIO4_LAT            LATDbits.LATD3
#define GPIO4_PORT           PORTDbits.RD3

#define GPIO5_TRIS           TRISDbits.TRISD2
#define GPIO5_LAT            LATDbits.LATD2
#define GPIO5_PORT           PORTDbits.RD2

#define GPIO6_TRIS           TRISDbits.TRISD1
#define GPIO6_LAT            LATDbits.LATD1
#define GPIO6_PORT           PORTDbits.RD1

#define GPIO7_TRIS           TRISDbits.TRISD0
#define GPIO7_LAT            LATDbits.LATD0
#define GPIO7_PORT           PORTDbits.RD0

#endif /* CONFIG_H */

#pragma config FEXTOSC = OFF
#pragma config RSTOSC = HFINTOSC_64MHZ
#pragma config CLKOUTEN = OFF
#pragma config JTAGEN = OFF
#pragma config PPS1WAY = OFF
#pragma config WDTE = OFF
#pragma config LVP = ON
