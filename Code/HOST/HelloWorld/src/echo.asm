; Zephyr-80 SIOB RX Echo Test with hardware flow control
;
; Serial:
;   SIO channel B
;   $22 = data
;   $23 = control
;   115200 8N1 with 1.8432 MHz SIO clock and x16 mode
;
; Flow control:
;   WR5 asserts RTS and DTR.
;
; Walkthrough:
;   1. Start at 0000h, disable interrupts, and move the stack to FFFFh.
;   2. Reset SIO channel B and configure it for 115200 8N1-style async serial.
;   3. Enable receive and transmit; RTS and DTR are asserted through WR5.
;   4. Wait for one received byte before printing the banner so the terminal is
;      already open.
;   5. In the main loop, poll RR0 bit 0 until RX data is available, read the
;      byte from SIO data port 22h, then poll RR0 bit 2 until TX is ready.
;   6. Echo the byte back to port 22h. If the byte is CR, also send LF.

SIO_DATA:           equ 022h
SIO_CTRL:           equ 023h

RR0_RX_AVAILABLE:   equ 001h
RR0_TX_EMPTY:       equ 004h

                    org 0000h

start:
                    di
                    ld sp,0FFFFh

                    call sio_init

                    ; Wait for terminal/user so banner is not lost
                    call sio_getc

                    ld hl,banner
                    call sio_puts

main_loop:
                    call sio_getc

                    ; Echo received character
                    call sio_putc

                    ; Optional: make CR also send LF
                    cp 00Dh
                    jr nz,main_loop
                    ld a,00Ah
                    call sio_putc
                    jr main_loop


; Initialize SIOB for 115200 8N1 with hardware flow control.
sio_init:
                    ; WR0: channel reset
                    ld a,018h
                    out (SIO_CTRL),a

                    ; WR4: x16 clock, 1 stop bit, no parity
                    ld a,004h
                    out (SIO_CTRL),a
                    ld a,044h
                    out (SIO_CTRL),a

                    ; WR3: Rx enable, 8-bit RX
                    ; C1h = 1100 0001b
                    ; D7-D6 = 11 = 8-bit RX
                    ; D0    = 1  = RX enable
                    ld a,003h
                    out (SIO_CTRL),a
                    ld a,0C1h
                    out (SIO_CTRL),a

                    ; WR5: DTR, 8-bit TX, TX enable, RTS
                    ; EAh = 1110 1010b
                    ; includes Tx Enable and asserts RTS/DTR.
                    ld a,005h
                    out (SIO_CTRL),a
                    ld a,0EAh
                    out (SIO_CTRL),a

                    ; WR1: interrupts disabled
                    ld a,001h
                    out (SIO_CTRL),a
                    xor a
                    out (SIO_CTRL),a

                    ret


; Wait for received character.
; Returns:
;   A = received byte
sio_getc:
.wait_rx:
                    ; Select/read RR0
                    xor a
                    out (SIO_CTRL),a

                    in a,(SIO_CTRL)
                    and RR0_RX_AVAILABLE
                    jr z,.wait_rx

                    in a,(SIO_DATA)
                    ret


; Send character in A.
sio_putc:
                    push af

.wait_tx:
                    ; Select/read RR0
                    xor a
                    out (SIO_CTRL),a

                    in a,(SIO_CTRL)
                    and RR0_TX_EMPTY
                    jr z,.wait_tx

                    pop af
                    out (SIO_DATA),a
                    ret


; Print null-terminated string at HL.
sio_puts:
                    ld a,(hl)
                    or a
                    ret z
                    call sio_putc
                    inc hl
                    jr sio_puts


banner:
                    defb "Zephyr-80 RX echo test with RTS/CTS",00Dh,00Ah
                    defb "Type characters. They should echo.",00Dh,00Ah,000h
