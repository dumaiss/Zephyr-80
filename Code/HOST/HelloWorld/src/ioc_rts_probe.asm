; IOC_RTS_PROBE.COM -- slow SIO1 RTS pin probe.
;
; This intentionally does not call IOCALL and does not require the MCU to clock.
; It writes SIO WR5 directly and slowly toggles:
;
;   1. SIO1/B Command control port 33h with Phase 1 SDLC WR5 values 6Dh/6Fh
;   2. SIO1/B Command control port 33h with legacy async WR5 values E8h/EAh
;   3. SIO1/A Bulk    control port 31h with legacy async WR5 values E8h/EAh
;
; Scope the SIO package RTS pins first, then RF1/RF2 at the MCU.  If the SIO
; package pin moves but RF does not, the issue is wiring/mapping.  If the SIO
; package pin does not move, the issue is before or at SIO port programming.

        .module ioc_rts_probe
        .area CODE (ABS)
        .org 0x0100

BDOS            = 0x0005
BDOS_PRINT      = 0x09

SIO1A_CTRL      = 0x31
SIO1B_CTRL      = 0x33

WR5_SELECT      = 0x05

WR5_CMD_OFF     = 0x6d
WR5_CMD_ON      = 0x6f
WR5_LEGACY_OFF  = 0xe8
WR5_LEGACY_ON   = 0xea

start:
        ld de,#msg_banner
        call print

        ld de,#msg_b_cmd
        call print
        ld b,#8
probe_b_cmd_loop:
        call sio1b_cmd_on
        call delay_visible
        call sio1b_cmd_off
        call delay_visible
        djnz probe_b_cmd_loop

        ld de,#msg_b_legacy
        call print
        ld b,#8
probe_b_legacy_loop:
        call sio1b_legacy_on
        call delay_visible
        call sio1b_legacy_off
        call delay_visible
        djnz probe_b_legacy_loop

        ld de,#msg_a_legacy
        call print
        ld b,#8
probe_a_legacy_loop:
        call sio1a_legacy_on
        call delay_visible
        call sio1a_legacy_off
        call delay_visible
        djnz probe_a_legacy_loop

        call sio1b_cmd_off
        call sio1a_legacy_off

        ld de,#msg_done
        call print
        ret

print:
        ld c,#BDOS_PRINT
        call BDOS
        ret

sio1b_cmd_on:
        ld a,#WR5_SELECT
        out (SIO1B_CTRL),a
        ld a,#WR5_CMD_ON
        out (SIO1B_CTRL),a
        ret

sio1b_cmd_off:
        ld a,#WR5_SELECT
        out (SIO1B_CTRL),a
        ld a,#WR5_CMD_OFF
        out (SIO1B_CTRL),a
        ret

sio1b_legacy_on:
        ld a,#WR5_SELECT
        out (SIO1B_CTRL),a
        ld a,#WR5_LEGACY_ON
        out (SIO1B_CTRL),a
        ret

sio1b_legacy_off:
        ld a,#WR5_SELECT
        out (SIO1B_CTRL),a
        ld a,#WR5_LEGACY_OFF
        out (SIO1B_CTRL),a
        ret

sio1a_legacy_on:
        ld a,#WR5_SELECT
        out (SIO1A_CTRL),a
        ld a,#WR5_LEGACY_ON
        out (SIO1A_CTRL),a
        ret

sio1a_legacy_off:
        ld a,#WR5_SELECT
        out (SIO1A_CTRL),a
        ld a,#WR5_LEGACY_OFF
        out (SIO1A_CTRL),a
        ret

delay_visible:
        push bc
        push de
        ld b,#0x08
delay_outer:
        ld de,#0xffff
delay_inner:
        dec de
        ld a,d
        or e
        jr nz,delay_inner
        djnz delay_outer
        pop de
        pop bc
        ret

msg_banner:
        .ascii "IOC RTS probe"
        .db 0x0d,0x0a,'$'
msg_b_cmd:
        .ascii "SIO1/B 33h WR5 6D/6F"
        .db 0x0d,0x0a,'$'
msg_b_legacy:
        .ascii "SIO1/B 33h WR5 E8/EA"
        .db 0x0d,0x0a,'$'
msg_a_legacy:
        .ascii "SIO1/A 31h WR5 E8/EA"
        .db 0x0d,0x0a,'$'
msg_done:
        .ascii "Done"
        .db 0x0d,0x0a,'$'
