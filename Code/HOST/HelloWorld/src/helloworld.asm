; Zephyr-80 SIOB Hello World
;
; Wiring:
;   A0 -> SIO C/D
;   A1 -> SIO B/A
;
; Port map:
;   $20 = Channel A data
;   $21 = Channel A control
;   $22 = Channel B data
;   $23 = Channel B control
;
; Serial:
;   115200 8N1 if SIO TX/RX clock = 1.8432 MHz and WR4 = x16
;
; Flow control:
;   WR3 Auto Enables enabled.
;   /CTS gates transmitter when Auto Enables is set.
;   /DCD gates receiver when Auto Enables is set.
;   WR5 asserts RTS and DTR.
;
; Walkthrough:
;   1. Start at 0000h, disable interrupts, and move the stack to FFFFh.
;   2. Reset SIO channel B and configure it for 115200 8N1-style async serial.
;   3. Enable receive, transmit, RTS, DTR, and SIO auto-enables.
;   4. Repeatedly point HL at hello_message and call sio_puts.
;   5. sio_puts reads bytes until the terminating 00h.
;   6. sio_putc polls RR0 bit 2 until the TX buffer is empty, then writes the
;      byte to SIO data port 22h.

SIO_DATA:           equ 022h       ; Channel B data
SIO_CTRL:           equ 023h       ; Channel B control

SIO_RR0_TX_EMPTY:   equ 004h       ; RR0 bit 2: Tx Buffer Empty

                    org 0000h

start:
                    di
                    ld sp,0FFFFh

                    call sio_init

print_message:
                    ld hl, hello_message
                    call sio_puts
                    jr print_message


; Initialize SIO channel B for async 8N1 with hardware flow control.
sio_init:
                    ; WR0: Channel reset
                    ld a,018h
                    out (SIO_CTRL),a

                    ; WR4: x16 clock, 1 stop bit, no parity
                    ld a,004h
                    out (SIO_CTRL),a
                    ld a,044h
                    out (SIO_CTRL),a

                    ; WR3: Rx enable, 8-bit RX, Auto Enables enabled
                    ; Previous value was C1h.
                    ; Add bit 5 = Auto Enables -> E1h.
                    ld a,003h
                    out (SIO_CTRL),a
                    ld a,0E1h
                    out (SIO_CTRL),a

                    ; WR5: DTR, 8-bit TX, TX enable, RTS
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


; Write a null-terminated string pointed to by HL.
sio_puts:
                    ld a,(hl)
                    or a
                    ret z
                    call sio_putc
                    inc hl
                    jr sio_puts


; Write A to SIO after waiting for Tx Buffer Empty.
sio_putc:
                    push af

sio_putc_wait:
                    ; Force/default control read to RR0.
                    ; This is a safe WR0 no-op / register pointer reset.
                    xor a
                    out (SIO_CTRL),a

                    in a,(SIO_CTRL)
                    and SIO_RR0_TX_EMPTY
                    jr z,sio_putc_wait

                    pop af
                    out (SIO_DATA),a
                    ret


hello_message:
                    defb "Hello, World!", 00Dh, 00Ah, 000h
