; zep_serial.asm -- polled SIO byte I/O with millisecond timeouts.
;
; The ports are given by their control address; the data port is one below.
; The poll loops are counted for the 10 MHz CPU, so timeouts are approximate.
; Transmit waits for TX buffer empty only: with WR3 Auto Enables on, the SIO
; itself holds the byte until /CTS, so TX empty already means "sent".

    SECTION code_user

    PUBLIC _zep__sio_getc
    PUBLIC _zep__sio_putc

RX_POLLS_PER_MS equ 204     ; 49 T-states per poll at 10 MHz
TX_POLLS_PER_MS equ 178     ; 56 T-states per poll

; int zep__sio_getc(uint8_t ctrl_port, uint16_t ms)   -1 on timeout
_zep__sio_getc:
    ld hl,2
    add hl,sp
    ld c,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
getc_try:
    in a,(c)
    rrca
    jr c,getc_have
    ld a,d
    or e
    jr z,getc_timeout
    ld hl,RX_POLLS_PER_MS
getc_poll:
    in a,(c)
    rrca
    jr c,getc_have
    dec hl
    ld a,h
    or l
    jr nz,getc_poll
    dec de
    jr getc_try
getc_have:
    dec c
    in l,(c)
    ld h,0
    ret
getc_timeout:
    ld hl,-1
    ret

; uint8_t zep__sio_putc(uint8_t ctrl_port, uint8_t byte, uint16_t ms)
; Returns 0 (ZEP_OK) or 3 (ZEP_ETIMEOUT).
_zep__sio_putc:
    ld hl,2
    add hl,sp
    ld c,(hl)
    inc hl
    ld b,(hl)
    inc hl
    ld e,(hl)
    inc hl
    ld d,(hl)
putc_try:
    in a,(c)
    and 4
    jr nz,putc_ready
    ld a,d
    or e
    jr z,putc_timeout
    ld hl,TX_POLLS_PER_MS
putc_poll:
    in a,(c)
    and 4
    jr nz,putc_ready
    dec hl
    ld a,h
    or l
    jr nz,putc_poll
    dec de
    jr putc_try
putc_ready:
    dec c
    out (c),b
    ld l,0
    ret
putc_timeout:
    ld l,3
    ret
