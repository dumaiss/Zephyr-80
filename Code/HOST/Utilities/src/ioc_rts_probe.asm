; IOC_RTS_PROBE.COM -- slow SIO1 RTS pin probe.
;
; This intentionally does not call IOCALL and does not require the MCU to clock.
; It is an ELECTRICAL PROBE, not a protocol diagnostic.  It writes SIO registers
; behind the BIOS and therefore invalidates both lanes' persistent-sync state.
; Cold boot after running it; do not run PING, BULK, SDREC or SDSOAK in the same
; session and interpret the result as a transport failure.
; It writes SIO WR5 directly and slowly toggles:
;
;   1. SIO1/B Command control port 33h with Phase 1 SDLC WR5 values 6Dh/6Fh
;   2. SIO1/B Command control port 33h with legacy async WR5 values E8h/EAh
;   3. SIO1/A Bulk    control port 31h with External-Sync WR5 values 00h/6Ah
;   4. SIO1/A Bulk    control port 31h with TX-enabled idle/assert values 00h/EAh
;   5. SIO1/A Bulk    control port 31h with legacy async WR5 values E8h/EAh
;   6. SIO1/A Bulk    control port 31h with DTR-only WR5 values 00h/80h
;   7. WR5 DTR-only scan on ports 30h, 31h, 32h, 33h.
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
SIO1_PORT_30    = 0x30
SIO1_PORT_31    = 0x31
SIO1_PORT_32    = 0x32
SIO1_PORT_33    = 0x33

WR5_SELECT      = 0x05

WR5_CMD_OFF     = 0x6d
WR5_CMD_ON      = 0x6f
WR5_IDLE_OFF    = 0x00
WR5_DTR_ON      = 0x80
WR5_SYNC_ON     = 0x6a
WR5_LEGACY_IDLE_ON = 0xea
WR5_LEGACY_OFF  = 0xe8
WR5_LEGACY_ON   = 0xea

start:
	; Private stack.
	;
	; CP/M enters a .COM through CALL TBASE, on the CCP's own stack -- sixteen
	; bytes total, several of them already spent getting here.  The BIOS
	; transport nests roughly twenty-five bytes deep and runs with interrupts
	; enabled while it waits for the MCU, so calling it from here used to run
	; off the bottom of that stack and into the CCP's own code.  Nothing
	; repaired it: a .COM exits through RET, not a warm boot, so WBOOT's
	; restore_ccp_from_rom never ran and the next CCP command died.
	;
	; The BIOS shims for IOCALL/IOCBULK/IOCBULKW now switch stacks themselves,
	; so this is no longer the only thing standing between here and a wedged
	; machine -- but BDOS nesting and an interrupt frame still land on whatever
	; stack this program is running on, and sixteen bytes is not enough for
	; those either.
	;
	; Entered through CALL so every RET in the body below lands back here and
	; the CCP's stack pointer is put back exactly once.
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	ld sp,(entry_sp)
	ret

main:
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

        ld de,#msg_a_sync
        call print
        ld b,#8
probe_a_sync_loop:
        call sio1a_sync_on
        call delay_visible
        call sio1a_idle_off
        call delay_visible
        djnz probe_a_sync_loop

        ld de,#msg_a_idle_legacy
        call print
        ld b,#8
probe_a_idle_legacy_loop:
        call sio1a_legacy_idle_on
        call delay_visible
        call sio1a_idle_off
        call delay_visible
        djnz probe_a_idle_legacy_loop

        ld de,#msg_a_legacy
        call print
        ld b,#8
probe_a_legacy_loop:
        call sio1a_legacy_on
        call delay_visible
        call sio1a_legacy_off
        call delay_visible
        djnz probe_a_legacy_loop

        ld de,#msg_a_dtr
        call print
        ld b,#8
probe_a_dtr_loop:
        call sio1a_dtr_on
        call delay_visible
        call sio1a_idle_off
        call delay_visible
        djnz probe_a_dtr_loop

        ld de,#msg_scan_30
        call print
        call probe_dtr_port_30

        ld de,#msg_scan_31
        call print
        call probe_dtr_port_31

        ld de,#msg_scan_32
        call print
        call probe_dtr_port_32

        ld de,#msg_scan_33
        call print
        call probe_dtr_port_33

        call sio1b_cmd_off
        call sio1a_idle_off

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

sio1a_sync_on:
        ld a,#WR5_SELECT
        out (SIO1A_CTRL),a
        ld a,#WR5_SYNC_ON
        out (SIO1A_CTRL),a
        ret

sio1a_idle_off:
        ld a,#WR5_SELECT
        out (SIO1A_CTRL),a
        ld a,#WR5_IDLE_OFF
        out (SIO1A_CTRL),a
        ret

sio1a_dtr_on:
        ld a,#WR5_SELECT
        out (SIO1A_CTRL),a
        ld a,#WR5_DTR_ON
        out (SIO1A_CTRL),a
        ret

sio1a_legacy_idle_on:
        ld a,#WR5_SELECT
        out (SIO1A_CTRL),a
        ld a,#WR5_LEGACY_IDLE_ON
        out (SIO1A_CTRL),a
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

probe_dtr_port_30:
        ld b,#8
probe_dtr_port_30_loop:
        call sio_wr5_dtr_on_30
        call delay_visible
        call sio_wr5_idle_off_30
        call delay_visible
        djnz probe_dtr_port_30_loop
        ret

probe_dtr_port_31:
        ld b,#8
probe_dtr_port_31_loop:
        call sio_wr5_dtr_on_31
        call delay_visible
        call sio_wr5_idle_off_31
        call delay_visible
        djnz probe_dtr_port_31_loop
        ret

probe_dtr_port_32:
        ld b,#8
probe_dtr_port_32_loop:
        call sio_wr5_dtr_on_32
        call delay_visible
        call sio_wr5_idle_off_32
        call delay_visible
        djnz probe_dtr_port_32_loop
        ret

probe_dtr_port_33:
        ld b,#8
probe_dtr_port_33_loop:
        call sio_wr5_dtr_on_33
        call delay_visible
        call sio_wr5_idle_off_33
        call delay_visible
        djnz probe_dtr_port_33_loop
        ret

sio_wr5_dtr_on_30:
        ld a,#WR5_SELECT
        out (SIO1_PORT_30),a
        ld a,#WR5_DTR_ON
        out (SIO1_PORT_30),a
        ret

sio_wr5_idle_off_30:
        ld a,#WR5_SELECT
        out (SIO1_PORT_30),a
        ld a,#WR5_IDLE_OFF
        out (SIO1_PORT_30),a
        ret

sio_wr5_dtr_on_31:
        ld a,#WR5_SELECT
        out (SIO1_PORT_31),a
        ld a,#WR5_DTR_ON
        out (SIO1_PORT_31),a
        ret

sio_wr5_idle_off_31:
        ld a,#WR5_SELECT
        out (SIO1_PORT_31),a
        ld a,#WR5_IDLE_OFF
        out (SIO1_PORT_31),a
        ret

sio_wr5_dtr_on_32:
        ld a,#WR5_SELECT
        out (SIO1_PORT_32),a
        ld a,#WR5_DTR_ON
        out (SIO1_PORT_32),a
        ret

sio_wr5_idle_off_32:
        ld a,#WR5_SELECT
        out (SIO1_PORT_32),a
        ld a,#WR5_IDLE_OFF
        out (SIO1_PORT_32),a
        ret

sio_wr5_dtr_on_33:
        ld a,#WR5_SELECT
        out (SIO1_PORT_33),a
        ld a,#WR5_DTR_ON
        out (SIO1_PORT_33),a
        ret

sio_wr5_idle_off_33:
        ld a,#WR5_SELECT
        out (SIO1_PORT_33),a
        ld a,#WR5_IDLE_OFF
        out (SIO1_PORT_33),a
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
msg_a_sync:
        .ascii "SIO1/A 31h WR5 00/6A"
        .db 0x0d,0x0a,'$'
msg_a_idle_legacy:
        .ascii "SIO1/A 31h WR5 00/EA"
        .db 0x0d,0x0a,'$'
msg_a_legacy:
        .ascii "SIO1/A 31h WR5 E8/EA"
        .db 0x0d,0x0a,'$'
msg_a_dtr:
        .ascii "SIO1/A 31h WR5 00/80 DTR"
        .db 0x0d,0x0a,'$'
msg_scan_30:
        .ascii "SCAN port 30h WR5 00/80 DTR"
        .db 0x0d,0x0a,'$'
msg_scan_31:
        .ascii "SCAN port 31h WR5 00/80 DTR"
        .db 0x0d,0x0a,'$'
msg_scan_32:
        .ascii "SCAN port 32h WR5 00/80 DTR"
        .db 0x0d,0x0a,'$'
msg_scan_33:
        .ascii "SCAN port 33h WR5 00/80 DTR"
        .db 0x0d,0x0a,'$'
msg_done:
        .ascii "Done"
        .db 0x0d,0x0a,'$'

; Private stack, and the CCP stack pointer parked while it is in use.
; Reserved, not emitted: the .COM image ends at the last byte above.
entry_sp:	.ds 2
	.ds 128				; BDOS nesting plus an interrupt frame
stack_top:
