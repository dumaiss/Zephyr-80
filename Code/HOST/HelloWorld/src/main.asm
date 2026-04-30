; Zephyr-80 Hello World skeleton.
;
; Assembles with z80asm-style syntax. The program initializes a Z80 SIO
; channel in asynchronous 8N1 mode and writes a null-terminated string.
;
; SIO channel:
;   Data port    0x20
;   Control port 0x22
;
; Baud rate:
;   WR4 selects x16 async clocking. A 1.8432 MHz SIO TX/RX clock gives
;   115200 bps.
;
; Modem/control signals:
;   CTS and DCD are enabled as hardware receive/transmit qualifiers through
;   WR3 auto-enables. WR5 asserts RTS and DTR while the channel is active.

SIO_DATA:       equ 020h
SIO_CTRL:       equ 022h

SIO_RR0_TX_EMPTY: equ 004h

                org 0000h

start:
                call sio_init

                ld hl, hello_message
                call sio_puts

halt_loop:
                halt
                jr halt_loop

; Initialize the SIO channel for async 8N1 operation.
;
; Register setup:
;   WR0 = channel reset
;   WR4 = x16 clock, 1 stop bit, no parity
;   WR3 = receiver enable, 8-bit RX, auto-enables for CTS/DCD
;   WR5 = transmitter enable, 8-bit TX, RTS/DTR asserted
;   WR1 = interrupts disabled for this polling example
sio_init:
                ld a,018h
                out (SIO_CTRL),a

                ld a,004h
                out (SIO_CTRL),a
                ld a,044h
                out (SIO_CTRL),a

                ld a,003h
                out (SIO_CTRL),a
                ld a,0E1h
                out (SIO_CTRL),a

                ld a,005h
                out (SIO_CTRL),a
                ld a,0EAh
                out (SIO_CTRL),a

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

; Write A to the SIO after waiting for transmitter empty.
sio_putc:
                push af
sio_putc_wait:
                in a,(SIO_CTRL)
                and SIO_RR0_TX_EMPTY
                jr z,sio_putc_wait
                pop af
                out (SIO_DATA),a
                ret

hello_message:
                defb "Hello, World!", 00Dh, 00Ah, 000h
