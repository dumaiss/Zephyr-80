; XFER.COM -- X/Y/ZMODEM file transfer over the serial console port (SIO0/B).
;
;   XFER ZR [d:]        ZMODEM receive; the sender names the files
;   XFER ZS [d:]afn     ZMODEM send, wildcards allowed
;   XFER YR [d:]        YMODEM batch receive
;   XFER YS [d:]afn     YMODEM batch send
;   XFER XR [d:]name    XMODEM receive (CRC or checksum, 128 or 1K blocks)
;   XFER XS [d:]name    XMODEM send (1K blocks with CRC, 128 with checksum)
;
; The PC side can be any program that speaks the protocol, as long as the port
; uses RTS/CTS flow control.  ESC or ^C on the keyboard aborts.
;
; V9958 console builds only.  In a VDrip build SIO0/B carries VDrip frames, and
; nothing a transient can read tells the two builds apart.
;
; ---------------------------------------------------------------------------
; Taking the port
; ---------------------------------------------------------------------------
;
; The BDOS console cannot carry a binary stream.  The serial console fallback
; (cbios_sercon.asm) keeps an eight-byte ring with no flow control, treats three
; ESCs as a takeover gesture, and mirrors CONOUT onto the same wire.  So for the
; length of a transfer this program owns SIO0/B outright:
;
;   - SIO0/B WR1 = 00h.  The BIOS SIO interrupt no longer fires for this
;     channel, so the sercon sink never sees a byte.  SIO1, the CTC and the
;     chip-wide WR9 enable are untouched: sio_core_disable_interrupts is NOT
;     the right tool, it takes the IO Controller link down with it.
;   - The sercon tee and input bits are cleared, so console output during the
;     transfer goes to the V9958 only and never touches the SIO.
;   - Bytes are polled from RR0 and the data port directly.
;
; Nothing here restores WR1.  Every exit is a warm boot, and warm boot already
; runs sio_core_init, sercon_install and sio_core_enable_interrupts.  That makes
; recovery independent of which path out of this program was taken.  Only the
; sercon flags byte is put back first, because sercon_install preserves it.
;
; ---------------------------------------------------------------------------
; Pacing
; ---------------------------------------------------------------------------
;
; The SIO has a 3-byte FIFO, and every BDOS disk write goes through IOCBULK,
; which masks interrupts for milliseconds and keeps this program from polling.
; Two things keep incoming bytes from landing on the floor during that time:
;
;   - the protocol: disk writes happen only where the sender is waiting for an
;     answer (an XMODEM/YMODEM ACK, a ZMODEM ZCRCW).  ZRINIT advertises a
;     receive buffer, which makes a compliant ZMODEM sender stop and wait at
;     least that often;
;   - RTS: it is released around every disk write and console call, so a PC
;     honouring RTS/CTS holds its output.  ZMODEM recovers anything that still
;     slips through with ZRPOS.
;
; RTS is software-managed on this port and the BIOS leaves it released in a
; V9958 build, so asserting it is this program's job.

	.module xfer
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_PAGE	= 0x0007		; high byte of the BDOS entry: top of TPA
FCB1		= 0x005c
FCB2		= 0x006c

C_CONIN	= 1
C_DIRIO		= 6
C_OPEN		= 15
C_CLOSE		= 16
C_SFIRST	= 17
C_SNEXT		= 18
C_DELETE	= 19
C_WRITE		= 21
C_MAKE		= 22
C_SETDMA	= 26
C_READR		= 33
C_SIZE		= 35

; SIO0/B.  platform_zephyr80.inc is the authority for the ports.
SIOB_DATA	= 0x22
SIOB_CTRL	= 0x23
RR0_RXA		= 0x01
RR0_TXREADY	= 0x24			; TX buffer empty and /CTS
WR0_ERR_RESET	= 0x30
WR5_RTS_OFF	= 0xe8			; DTR, 8-bit TX, TX enable
WR5_RTS_ON	= 0xea			; ... and RTS

; Timing.  The poll loop in getc is 48 T-states, 4.8 us at 10 MHz, so 2083
; polls make a 10 ms tick.  Timeouts below are in ticks.
POLLS_PER_TICK	= 2083
TICKS_1S	= 100
TX_TICKS	= 1000			; /CTS held off this long: the PC is gone
PURGE_TICKS	= 50

; RAM the program uses beyond its own image.  None of it is in the .COM file.
RXBUF		= 0x8000		; received data waiting to be written
RXBUF_END_PAGE	= 0xa0
SCRATCH		= 0xa000		; ZFILE/ZSINIT data, YMODEM block 0
SCRATCH_END_PAGE = 0xa4
TXBUF		= 0xa400		; one outgoing block
FLIST		= 0xa800		; batch send file names, 11 bytes each
MAX_FILES	= 200
CRCLO_PAGE	= 0xb2			; CRC-16 table, low bytes
CRCHI_PAGE	= 0xb3			; ... high bytes
MEM_TOP_PAGE	= 0xb4

; Write when this much is buffered.  ZRINIT advertises the same figure, so a
; compliant ZMODEM sender stops at a ZCRCW before the buffer gets here.
FLUSH_AT	= 4096
ZRX_BUFLEN	= 4096

PROGRESS_EVERY	= 8
MAX_ERRORS	= 10

; Characters.
SOH		= 0x01
STX		= 0x02
EOT		= 0x04
ACK		= 0x06
BS		= 0x08
NAK		= 0x15
CAN		= 0x18
CPMEOF		= 0x1a
XON		= 0x11
XOFF		= 0x13
ESC		= 0x1b

; ZMODEM framing.
ZPAD		= 0x2a
ZDLE		= 0x18
ZBIN		= 0x41
ZHEX		= 0x42
ZCRCE		= 0x68
ZCRCG		= 0x69
ZCRCQ		= 0x6a
ZCRCW		= 0x6b
ZRUB0		= 0x6c
ZRUB1		= 0x6d

ZRQINIT		= 0
ZRINIT		= 1
ZSINIT		= 2
ZACK		= 3
ZFILE		= 4
ZSKIP		= 5
ZNAK		= 6
ZFIN		= 8
ZRPOS		= 9
ZDATA		= 10
ZEOF		= 11
ZCRC		= 13
ZCHALLENGE	= 14

CANFDX		= 0x01			; ZRINIT ZF0
ESCCTL		= 0x40
ZCBIN		= 1			; ZFILE ZF0: binary, no conversion

; Internal error codes, returned in A with carry set.
ERR_TIMEOUT	= 1
ERR_CAN		= 2
ERR_BADESC	= 3
ERR_CRC		= 4
ERR_GARBAGE	= 5
ERR_LONG	= 6

; ===========================================================================
; Entry
; ===========================================================================

start:
	; The variables live past the end of the image, in RAM the loader did not
	; write, so nothing in them can be assumed.
	ld hl,#vars_start
	ld de,#vars_start + 1
	ld bc,#vars_end - vars_start - 1
	ld (hl),#0
	ldir
	ld sp,#stack_top

	ld hl,#FCB2
	ld de,#arg_fcb
	ld bc,#12
	ldir

	ld de,#msg_banner
	call puts

	ld a,(BDOS_PAGE)
	cp #MEM_TOP_PAGE
	jr nc,mem_ok
	ld de,#msg_memory
	jp fail_plain
mem_ok:
	call crc_init

	; The subcommand is the first word of the tail, which the CCP has packed
	; into FCB1.  Exactly two letters.
	ld a,(FCB1 + 3)
	cp #0x20
	jr nz,usage
	ld a,(FCB1 + 1)
	ld b,a
	ld a,(FCB1 + 2)
	ld c,a

	ld a,b
	cp #'Z
	jr nz,not_z
	ld a,c
	cp #'R
	ld hl,#prep_rx_batch
	ld de,#zm_recv
	jr z,dispatch
	cp #'S
	ld hl,#prep_tx_batch
	ld de,#zm_send
	jr z,dispatch
	jr usage
not_z:
	cp #'Y
	jr nz,not_y
	ld a,c
	cp #'R
	ld hl,#prep_rx_batch
	ld de,#ym_recv
	jr z,dispatch
	cp #'S
	ld hl,#prep_tx_batch
	ld de,#ym_send
	jr z,dispatch
	jr usage
not_y:
	cp #'X
	jr nz,usage
	ld a,c
	cp #'R
	ld hl,#prep_xr
	ld de,#xm_recv
	jr z,dispatch
	cp #'S
	ld hl,#prep_xs
	ld de,#xm_send
	jr z,dispatch
usage:
	ld de,#msg_usage
	call puts
	; Warm boot reinitialises the console and wipes the screen, so hold the
	; text up until it has been read.  BDOS 1 waits in the BIOS CONIN, the
	; same wait the CCP uses, rather than spinning here.
	ld de,#msg_anykey
	call puts
	ld c,#C_CONIN
	call BDOS
	call crlf
	jp 0

; HL = preparation, run before the port is taken so its messages are plain.
; DE = the protocol.  Both return NC on success, or C with DE = message.
dispatch:
	ld (proto_vec),de
	call call_hl
	jr c,fail_plain

	ld de,#msg_go
	call puts
	call raw_enter
	ld hl,(proto_vec)
	call call_hl
	push af
	push de
	call rts_off
	call wfile_abort		; still open means the transfer did not finish
	call raw_exit
	pop de
	pop af
	jr c,fail_report
	ld de,#msg_done
	call puts
	jp 0

fail_report:
	push de
	ld de,#msg_failed
	call puts
	pop de
fail_plain:
	call puts
	call crlf
	jp 0

call_hl:
	jp (hl)

; ---- preparation ----------------------------------------------------------

; ZR, YR: the argument is a drive, nothing more.
prep_rx_batch:
	ld a,(arg_fcb + 1)
	cp #0x20
	jr nz,prep_drive_only
	or a
	ret
prep_drive_only:
	ld de,#msg_driveonly
	scf
	ret

; ZS, YS: collect the matching files now, while BDOS search is safe to use.
prep_tx_batch:
	ld a,(arg_fcb + 1)
	cp #0x20
	jr z,prep_needname
	call collect
	ret nc
	ld de,#msg_nofiles
	ret

; XR: one explicit name, created now so a bad name fails before the PC starts.
prep_xr:
	call arg_single
	ret c
	call wfile_create
	ret nc
	ld de,#msg_nocreate
	ret

; XS: one explicit name that exists.
prep_xs:
	call arg_single
	ret c
	call rfile_open
	ret nc
	ld de,#msg_nofile
	ret

prep_needname:
	ld de,#msg_needname
	scf
	ret

; Copy a single, wildcard-free argument into fcb.  C with DE = message if not.
; A wildcard matters beyond usability: wfile_create deletes before it makes.
arg_single:
	ld a,(arg_fcb + 1)
	cp #0x20
	jr z,prep_needname
	ld hl,#arg_fcb + 1
	ld b,#11
as_scan:
	ld a,(hl)
	cp #'?
	jr z,as_wild
	inc hl
	djnz as_scan
	ld hl,#arg_fcb
	ld de,#fcb
	ld bc,#12
	ldir
	or a
	ret
as_wild:
	ld de,#msg_nowild
	scf
	ret

; ===========================================================================
; The port
; ===========================================================================

; Take SIO0/B from the BIOS.  See the header.
raw_enter:
	; The sercon flags byte, if this is a Zephyr BIOS.  Check the block rather
	; than trust it: an unknown BDOS function can return anything in HL.
	ld c,#ZB_SYSINFO
	call BDOS
	ld a,(hl)
	cp #1
	jr nz,re_port
	ld de,#ZB_SYSINFO_SERCON
	add hl,de
	ld e,(hl)
	inc hl
	ld d,(hl)
	ld a,d
	cp #0xfe			; BIOS runtime state page
	jr nz,re_port
	ld (sercon_ptr),de
	ld a,(de)
	ld (sercon_saved),a
	and #0xfc			; tee and input off
	ld (de),a
re_port:
	di
	ld a,#1
	out (SIOB_CTRL),a
	xor a
	out (SIOB_CTRL),a		; WR1: no SIO0/B interrupts
	ei
	ld a,#WR0_ERR_RESET
	out (SIOB_CTRL),a
	ld b,#16
re_drain:
	in a,(SIOB_CTRL)
	rrca
	jr nc,re_drained
	in a,(SIOB_DATA)
	djnz re_drain
re_drained:
	jp rts_on

; Put the sercon flags back.  The caller warm boots, which restores the rest.
raw_exit:
	ld hl,(sercon_ptr)
	ld a,h
	or l
	ret z
	ld a,(sercon_saved)
	ld (hl),a
	ret

; Clobbers AF.
rts_on:
	ld a,#5
	out (SIOB_CTRL),a
	ld a,#WR5_RTS_ON
	out (SIOB_CTRL),a
	ret

rts_off:
	ld a,#5
	out (SIOB_CTRL),a
	ld a,#WR5_RTS_OFF
	out (SIOB_CTRL),a
	ret

; Wait up to (rx_ticks) for a byte.
; Out: NC with A = byte, or C on timeout.  Clobbers AF only.
;
; The first test is the hot path: during a transfer a byte is usually already
; waiting, and that path must stay short -- a byte arrives every 87 us.
getc:
	in a,(SIOB_CTRL)
	rrca
	jr nc,getc_wait
	in a,(SIOB_DATA)
	or a
	ret
getc_wait:
	push bc
	push hl
	ld hl,(rx_ticks)
getc_tick:
	ld bc,#POLLS_PER_TICK
getc_poll:
	in a,(SIOB_CTRL)
	rrca
	jr c,getc_hit
	dec bc
	ld a,b
	or c
	jr nz,getc_poll
	dec hl
	ld a,h
	or l
	jr nz,getc_tick
	pop hl
	pop bc
	scf
	ret
getc_hit:
	pop hl
	pop bc
	in a,(SIOB_DATA)
	or a
	ret

; Send A.  Waits for the transmitter, which Auto Enables also gates on /CTS.
; If the PC holds /CTS off for TX_TICKS the link is declared dead and every
; later putc returns at once; the protocol then fails on its own timeouts.
; Preserves everything but F.
putc:
	push af
	ld a,(tx_dead)
	or a
	jr nz,putc_drop
	push bc
	push hl
	ld hl,#TX_TICKS
putc_tick:
	ld bc,#POLLS_PER_TICK
putc_poll:
	in a,(SIOB_CTRL)
	and #RR0_TXREADY
	cp #RR0_TXREADY
	jr z,putc_ready
	dec bc
	ld a,b
	or c
	jr nz,putc_poll
	dec hl
	ld a,h
	or l
	jr nz,putc_tick
	ld a,#1
	ld (tx_dead),a
	pop hl
	pop bc
putc_drop:
	pop af
	ret
putc_ready:
	pop hl
	pop bc
	pop af
	out (SIOB_DATA),a
	ret

; Discard input until the line has been quiet for PURGE_TICKS.
purge:
	ld hl,(rx_ticks)
	push hl
	ld hl,#PURGE_TICKS
	ld (rx_ticks),hl
	ld de,#0
purge_loop:
	call getc
	jr c,purge_done
	dec de
	ld a,d
	or e
	jr nz,purge_loop
purge_done:
	pop hl
	ld (rx_ticks),hl
	ld a,#WR0_ERR_RESET
	out (SIOB_CTRL),a
	ret

; HL = tick count.
set_ticks:
	ld (rx_ticks),hl
	ret

; Out: C if the operator pressed ESC or ^C.  RTS is released around the BDOS
; call, which can take long enough to overrun the FIFO.
kbcheck:
	call rts_off
	call kbabort
	push af
	call rts_on
	pop af
	ret

; Same, for callers that already hold RTS released.  Clobbers everything.
kbabort:
	ld e,#0xff
	ld c,#C_DIRIO
	call BDOS
	cp #3
	jr z,kb_yes
	cp #ESC
	jr z,kb_yes
	or a
	ret
kb_yes:
	scf
	ret

; Eight CANs and ten backspaces: the ZMODEM abort, which X/YMODEM also honour.
send_cancel:
	ld b,#8
sc_can:
	ld a,#CAN
	call putc
	djnz sc_can
	ld b,#10
sc_bs:
	ld a,#BS
	call putc
	djnz sc_bs
	ret

; ===========================================================================
; CRC-16/XMODEM (polynomial 1021h, initial 0), table-driven
; ===========================================================================

crc_init:
	ld c,#0
ci_entry:
	ld h,c
	ld l,#0
	ld b,#8
ci_bit:
	add hl,hl
	jr nc,ci_next
	ld a,h
	xor #0x10
	ld h,a
	ld a,l
	xor #0x21
	ld l,a
ci_next:
	djnz ci_bit
	ld b,#CRCLO_PAGE
	ld a,l
	ld (bc),a
	inc b
	ld a,h
	ld (bc),a
	inc c
	jr nz,ci_entry
	ret

; DE = CRC, A = byte.  Out: DE updated.  Clobbers AF, BC.
crc_upd:
	xor d
	ld c,a
	ld b,#CRCHI_PAGE
	ld a,(bc)
	xor e
	ld d,a
	dec b
	ld a,(bc)
	ld e,a
	ret

; ===========================================================================
; Console
; ===========================================================================

; DE = NUL-terminated string.  Direct console I/O throughout: BDOS 2 and 9
; check for ^S and can swallow the key kbabort is looking for.
puts:
	ld a,(de)
	or a
	ret z
	push de
	call putch
	pop de
	inc de
	jr puts

; A = character.  Preserves BC, DE, HL.
putch:
	push bc
	push de
	push hl
	ld e,a
	ld c,#C_DIRIO
	call BDOS
	pop hl
	pop de
	pop bc
	ret

crlf:
	ld a,#13
	call putch
	ld a,#10
	jp putch

; HL = 32-bit value.
print_dec32:
	ld de,#numbuf
	call fmt_dec32
	ld de,#numbuf
	jp puts

; "  NAME.EXT" on a fresh line, then the size if known.
show_file:
	call crlf
	ld de,#msg_indent
	call puts
	ld de,#namebuf
	ld c,#0
	call fcb_to_str
	ld de,#namebuf
	call puts
	ld a,#PROGRESS_EVERY
	ld (prog_cnt),a
	ld a,(size_known)
	or a
	jr z,sf_done
	ld de,#msg_open
	call puts
	ld hl,#fsize
	call print_dec32
	ld de,#msg_bytes_close
	call puts
sf_done:
	jp crlf

; Every PROGRESS_EVERY calls, overwrite the progress line.
progress_tick:
	ld hl,#prog_cnt
	dec (hl)
	ret nz
	ld (hl),#PROGRESS_EVERY
progress_show:
	ld a,#13
	call putch
	ld de,#msg_indent
	call puts
	ld hl,#pos
	call print_dec32
	ld de,#msg_bytes
	jp puts

; ===========================================================================
; Numbers
; ===========================================================================

; HL = 32-bit value, DE = destination.  Writes decimal digits and a NUL.
; Out: DE at the NUL.
fmt_dec32:
	push de
	ld de,#num_work
	ld bc,#4
	ldir
	pop de
	ld b,#0
fd_digit:
	push bc
	push de
	call div10
	pop de
	pop bc
	push af
	inc b
	ld hl,#num_work
	ld a,(hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	jr nz,fd_digit
fd_emit:
	pop af
	add a,#'0
	ld (de),a
	inc de
	djnz fd_emit
	xor a
	ld (de),a
	ret

; num_work /= 10.  Out: A = remainder.  Clobbers BC, HL.
div10:
	ld hl,#num_work + 3
	ld b,#4
	xor a
d10_byte:
	ld c,(hl)
	push bc
	ld b,#8
d10_bit:
	sla c
	rla
	cp #10
	jr c,d10_keep
	sub #10
	inc c
d10_keep:
	djnz d10_bit
	ld (hl),c
	pop bc
	dec hl
	djnz d10_byte
	ret

; Parse decimal digits at HL into parsed32.  Stops at the first non-digit.
parse_dec:
	xor a
	ld (parsed32),a
	ld (parsed32 + 1),a
	ld (parsed32 + 2),a
	ld (parsed32 + 3),a
pd_char:
	ld a,(hl)
	sub #'0
	ret c
	cp #10
	ret nc
	push hl
	call mul10_add
	pop hl
	inc hl
	jr pd_char

; parsed32 = parsed32 * 10 + A.
mul10_add:
	ld c,a
	ld hl,#parsed32
	ld b,#4
m10_byte:
	ld e,(hl)
	ld d,#0
	push hl
	ld h,d
	ld l,e
	add hl,hl
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,de
	ld e,c
	ld d,#0
	add hl,de
	ld c,h
	ld a,l
	pop hl
	ld (hl),a
	inc hl
	djnz m10_byte
	ret

; (HL) += BC, 32-bit.
add32_bc:
	ld a,(hl)
	add a,c
	ld (hl),a
	inc hl
	ld a,(hl)
	adc a,b
	ld (hl),a
	inc hl
	ld a,(hl)
	adc a,#0
	ld (hl),a
	inc hl
	ld a,(hl)
	adc a,#0
	ld (hl),a
	ret

; (HL) -= BC, 32-bit.
sub32_bc:
	ld a,(hl)
	sub c
	ld (hl),a
	inc hl
	ld a,(hl)
	sbc a,b
	ld (hl),a
	inc hl
	ld a,(hl)
	sbc a,#0
	ld (hl),a
	inc hl
	ld a,(hl)
	sbc a,#0
	ld (hl),a
	ret

; Z if the four bytes at HL and DE are equal.
cmp4:
	ld b,#4
c4_byte:
	ld a,(de)
	cp (hl)
	ret nz
	inc hl
	inc de
	djnz c4_byte
	ret

zero_pos:
	ld hl,#pos
zero4:
	xor a
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	inc hl
	ld (hl),a
	ret

zero_txhdr:
	ld hl,#txhdr
	jr zero4

pos_to_txhdr:
	ld hl,#pos
	ld de,#txhdr
	ld bc,#4
	ldir
	ret

rxhdr_to_pos:
	ld hl,#rxhdr
	ld de,#pos
	ld bc,#4
	ldir
	ret

; ===========================================================================
; Names
; ===========================================================================

; fcb name -> "name.ext" at DE, NUL-terminated.  C = 20h lowercases, 0 keeps.
; Out: DE at the NUL.
fcb_to_str:
	ld hl,#fcb + 1
	ld b,#8
	call fs_part
	ld a,(fcb + 9)
	and #0x7f
	cp #0x20
	jr z,fs_end
	ld a,#'.
	ld (de),a
	inc de
	ld hl,#fcb + 9
	ld b,#3
	call fs_part
fs_end:
	xor a
	ld (de),a
	ret
fs_part:
	ld a,(hl)
	and #0x7f
	cp #0x20
	jr z,fs_skip
	cp #'A
	jr c,fs_store
	cp #'Z + 1
	jr nc,fs_store
	or c
fs_store:
	ld (de),a
	inc de
fs_skip:
	inc hl
	djnz fs_part
	ret

; The sender's path at HL (NUL-terminated) -> an 8.3 name in fcb, keeping only
; the last path component.  Characters CP/M rejects become '_'.
name_to_fcb:
	ld d,h
	ld e,l
nf_scan:
	ld a,(hl)
	or a
	jr z,nf_found
	inc hl
	cp #'/
	jr z,nf_sep
	cp #0x5c			; backslash
	jr nz,nf_scan
nf_sep:
	ld d,h
	ld e,l
	jr nf_scan
nf_found:
	ld hl,#fcb + 1
	ld b,#11
nf_blank:
	ld (hl),#0x20
	inc hl
	djnz nf_blank

	ex de,hl			; HL = the last component
	ld de,#fcb + 1
	ld b,#8
nf_name:
	ld a,(hl)
	or a
	jr z,nf_done
	inc hl
	cp #'.
	jr z,nf_ext
	call cpm_char
	inc b
	dec b
	jr z,nf_name			; past eight characters: drop
	ld (de),a
	inc de
	dec b
	jr nf_name
nf_ext:
	ld de,#fcb + 9
	ld b,#3
nf_extch:
	ld a,(hl)
	or a
	jr z,nf_done
	inc hl
	cp #'.
	jr z,nf_done			; "a.tar.gz" -> A.TAR
	call cpm_char
	inc b
	dec b
	jr z,nf_extch
	ld (de),a
	inc de
	dec b
	jr nf_extch
nf_done:
	ld a,(fcb + 1)
	cp #0x20
	ret nz
	ld hl,#str_unnamed		; ".profile" and friends
	ld de,#fcb + 1
	ld bc,#8
	ldir
	ret

; A -> a character CP/M accepts in a file name.
cpm_char:
	cp #'a
	jr c,cc_upper
	cp #'z + 1
	jr nc,cc_upper
	sub #0x20
cc_upper:
	cp #0x21
	jr c,cc_bad
	cp #0x7f
	jr nc,cc_bad
	push hl
	push bc
	ld hl,#str_badchars
	ld b,#str_badchars_end - str_badchars
cc_scan:
	cp (hl)
	jr z,cc_reject
	inc hl
	djnz cc_scan
	pop bc
	pop hl
	ret
cc_reject:
	pop bc
	pop hl
cc_bad:
	ld a,#'_
	ret

; ===========================================================================
; Files
; ===========================================================================

; Clear everything after the name.  F_MAKE copies bytes 16-31 straight into the
; directory entry, and nothing else clears them (see SDGET).
fcb_clear_tail:
	ld hl,#fcb + 12
	ld b,#24
fct_byte:
	ld (hl),#0
	inc hl
	djnz fct_byte
	ret

; Create fcb's file, replacing any existing copy.  Out: C on failure.
wfile_create:
	call fcb_clear_tail
	ld de,#fcb
	ld c,#C_DELETE
	call BDOS
	call fcb_clear_tail
	ld de,#fcb
	ld c,#C_MAKE
	call BDOS
	inc a
	scf
	ret z
	ld hl,#0
	ld (fill),hl
	ld a,#1
	ld (wfile_open),a
	or a
	ret

; Write whole records from RXBUF while at least HL bytes stay buffered, then
; move the remainder to the front.  Out: C on a disk error.
wfile_flush:
	ld (keep),hl
	ld hl,#RXBUF
	ld (wptr),hl
wf_record:
	ld hl,(fill)
	ld de,(keep)
	or a
	sbc hl,de
	jr c,wf_move
	ld de,#128
	or a
	sbc hl,de
	jr c,wf_move
	ld de,(wptr)
	ld c,#C_SETDMA
	call BDOS
	ld de,#fcb
	ld c,#C_WRITE
	call BDOS
	or a
	jr nz,wf_error
	ld hl,(wptr)
	ld de,#128
	add hl,de
	ld (wptr),hl
	ld hl,(fill)
	or a
	sbc hl,de
	ld (fill),hl
	jr wf_record
wf_move:
	ld hl,(wptr)
	ld de,#RXBUF
	or a
	sbc hl,de
	ret z
	ld bc,(fill)
	ld a,b
	or c
	ret z
	ld hl,(wptr)
	ldir
	or a
	ret
wf_error:
	scf
	ret

; Flush, pad the last record with ^Z, close.  Out: C on a disk error.
wfile_close:
	ld a,(wfile_open)
	or a
	ret z
	xor a
	ld (wfile_open),a
	ld hl,#0
	call wfile_flush
	ret c
	ld hl,(fill)
	ld a,h
	or l
	jr z,wc_close
	ld de,#RXBUF
	add hl,de
	ld a,(fill)
	ld b,a
	ld a,#128
	sub b
	ld b,a
wc_pad:
	ld (hl),#CPMEOF
	inc hl
	djnz wc_pad
	ld de,#RXBUF
	ld c,#C_SETDMA
	call BDOS
	ld de,#fcb
	ld c,#C_WRITE
	call BDOS
	or a
	jr nz,wf_error
wc_close:
	ld de,#fcb
	ld c,#C_CLOSE
	call BDOS
	inc a
	jr z,wf_error
	or a
	ret

; A transfer that ends with the file still open failed: remove the fragment.
wfile_abort:
	ld a,(wfile_open)
	or a
	ret z
	xor a
	ld (wfile_open),a
	ld de,#fcb
	ld c,#C_CLOSE
	call BDOS
	ld de,#fcb
	ld c,#C_DELETE
	jp BDOS

; Without a size (XMODEM, or YMODEM with none) the last block's padding is
; indistinguishable from data.  Drop trailing ^Z: whole records of them go,
; and a partial record is padded back with ^Z on close, so nothing inside the
; last real record changes.
trim_ctrlz:
	ld hl,(fill)
tz_byte:
	ld a,h
	or l
	jr z,tz_store
	dec hl
	push hl
	ld de,#RXBUF
	add hl,de
	ld a,(hl)
	pop hl
	cp #CPMEOF
	jr z,tz_byte
	inc hl
tz_store:
	ld (fill),hl
	ret

; Open fcb for reading and size it.  Out: C if absent; fsize = records * 128.
rfile_open:
	call fcb_clear_tail
	ld de,#fcb
	ld c,#C_OPEN
	call BDOS
	inc a
	scf
	ret z
	ld de,#fcb
	ld c,#C_SIZE
	call BDOS
	ld hl,(fcb + 33)
	ld (fsize),hl
	ld a,(fcb + 35)
	ld (fsize + 2),a
	xor a
	ld (fsize + 3),a
	ld b,#7
ro_shift:
	ld hl,#fsize
	sla (hl)
	inc hl
	rl (hl)
	inc hl
	rl (hl)
	inc hl
	rl (hl)
	djnz ro_shift
	ld a,#1
	ld (size_known),a
	or a
	ret

; Fill TXBUF with up to (want) bytes from file offset (pos).
; Out: tx_len = bytes read, 0 at end of file.
;
; Random reads throughout, so a ZRPOS to anywhere costs nothing special.
rfile_read:
	ld hl,#0
	ld (tx_len),hl
	ld a,(pos)
	and #0x7f
	ld (roff),a
	; record = pos >> 7, 16 bits: CP/M 2.2 files stop at 65536 records.
	ld hl,(pos)
	ld a,(pos + 2)
	rl l
	rl h
	rla
	ld l,h
	ld h,a
	ld (rrec),hl
rr_record:
	ld hl,(rrec)
	ld (fcb + 33),hl
	xor a
	ld (fcb + 35),a
	ld de,#recbuf
	ld c,#C_SETDMA
	call BDOS
	ld de,#fcb
	ld c,#C_READR
	call BDOS
	or a
	ret nz				; past the end
	ld a,(roff)
	ld e,a
	ld d,#0
	ld hl,#recbuf
	add hl,de
	push hl
	ld a,#128
	sub e
	ld c,a
	ld b,#0				; BC = bytes left in this record
	ld hl,(want)
	ld de,(tx_len)
	or a
	sbc hl,de			; HL = bytes still wanted
	push hl
	or a
	sbc hl,bc
	pop hl
	jr nc,rr_copy
	ld b,h
	ld c,l
rr_copy:
	ld hl,(tx_len)
	ld de,#TXBUF
	add hl,de
	ex de,hl
	ld hl,(tx_len)
	add hl,bc
	ld (tx_len),hl
	pop hl
	ldir
	xor a
	ld (roff),a
	ld hl,(rrec)
	inc hl
	ld (rrec),hl
	ld hl,(want)
	ld de,(tx_len)
	or a
	sbc hl,de
	jr nz,rr_record
	ret

; Collect the names matching arg_fcb into FLIST.  Out: C if none.
; Done in full before sending: BDOS search state does not survive the opens
; and reads in between.
collect:
	ld hl,#arg_fcb
	ld de,#sfcb
	ld bc,#12
	ldir
	ld hl,#sfcb + 12
	ld b,#24
co_clear:
	ld (hl),#0
	inc hl
	djnz co_clear
	ld hl,#FLIST
	ld (fl_ptr),hl
	ld de,#dirbuf
	ld c,#C_SETDMA
	call BDOS
	ld de,#sfcb
	ld c,#C_SFIRST
co_call:
	call BDOS
	cp #0xff
	jr z,co_done
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a
	ld e,a
	ld d,#0
	ld hl,#dirbuf + 1
	add hl,de
	ld de,(fl_ptr)
	ld b,#11
co_copy:
	ld a,(hl)
	and #0x7f			; attribute bits
	ld (de),a
	inc hl
	inc de
	djnz co_copy
	ld (fl_ptr),de
	ld a,(nfiles)
	inc a
	ld (nfiles),a
	cp #MAX_FILES
	jr z,co_done
	ld de,#sfcb
	ld c,#C_SNEXT
	jr co_call
co_done:
	ld a,(nfiles)
	or a
	scf
	ret z
	or a
	ret

; Load the next FLIST entry into fcb.  Out: C when the list is done.
fl_next:
	ld a,(fl_index)
	ld hl,#nfiles
	cp (hl)
	scf
	ret z
	inc a
	ld (fl_index),a
	dec a
	ld l,a
	ld h,#0
	ld d,h
	ld e,l
	add hl,hl
	add hl,hl
	add hl,hl
	add hl,de
	add hl,de
	add hl,de			; x 11
	ld de,#FLIST
	add hl,de
	ld de,#fcb + 1
	ld bc,#11
	ldir
	ld a,(arg_fcb)
	ld (fcb),a
	or a
	ret

; ===========================================================================
; ZMODEM primitives
; ===========================================================================

; Send A ZDLE-escaped.  Escapes ZDLE, DLE, XON, XOFF and CR in either parity
; (CR because some links eat "@ CR"), or every control code if the receiver
; asked with ESCCTL.  Clobbers AF, C.
put_esc:
	ld c,a
	and #0x60
	ld a,c
	jp nz,putc			; 20h-7Fh, A0h-FFh: never escaped
	ld a,(esc_ctl)
	or a
	jr nz,pe_escape
	ld a,c
	and #0x7f
	cp #ZDLE
	jr z,pe_escape
	cp #0x10
	jr z,pe_escape
	cp #XON
	jr z,pe_escape
	cp #XOFF
	jr z,pe_escape
	cp #0x0d
	jr z,pe_escape
	ld a,c
	jp putc
pe_escape:
	ld a,#ZDLE
	call putc
	ld a,c
	xor #0x40
	jp putc

; A = byte: CRC it into DE, then send escaped.  Clobbers AF, BC.
put_esc_crc:
	push af
	call crc_upd
	pop af
	jr put_esc

; Hex header: type A, data txhdr.
zs_hexhdr:
	ld (zh_type),a
	ld a,#ZPAD
	call putc
	call putc
	ld a,#ZDLE
	call putc
	ld a,#ZHEX
	call putc
	ld de,#0
	ld a,(zh_type)
	call put_hex_crc
	ld hl,#txhdr
	ld b,#4
zsh_byte:
	ld a,(hl)
	push bc
	call put_hex_crc
	pop bc
	inc hl
	djnz zsh_byte
	ld a,d
	call put_hex
	ld a,e
	call put_hex
	ld a,#13
	call putc
	ld a,#0x8a
	call putc
	ld a,(zh_type)
	cp #ZFIN
	ret z
	cp #ZACK
	ret z
	ld a,#XON
	jp putc

put_hex_crc:
	push af
	call crc_upd
	pop af
put_hex:
	push af
	rrca
	rrca
	rrca
	rrca
	call put_nibble
	pop af
put_nibble:
	and #0x0f
	cp #10
	jr c,pn_digit
	add a,#0x27			; lowercase: lrzsz reads nothing else
pn_digit:
	add a,#'0
	jp putc

; Binary header (CRC-16): type A, data txhdr.
zs_binhdr:
	ld (zh_type),a
	ld a,#ZPAD
	call putc
	ld a,#ZDLE
	call putc
	ld a,#ZBIN
	call putc
	ld de,#0
	ld a,(zh_type)
	call put_esc_crc
	ld hl,#txhdr
	ld b,#4
zsb_byte:
	ld a,(hl)
	push bc
	call put_esc_crc
	pop bc
	inc hl
	djnz zsb_byte
	ld a,d
	push de
	call put_esc
	pop de
	ld a,e
	jp put_esc

; Data subpacket: HL = data, BC = length, A = frame end.
zs_data:
	ld (zd_end),a
	ld de,#0
zsd_byte:
	ld a,b
	or c
	jr z,zsd_end
	ld a,(hl)
	push bc
	call put_esc_crc
	pop bc
	inc hl
	dec bc
	jr zsd_byte
zsd_end:
	ld a,#ZDLE
	call putc
	ld a,(zd_end)
	call putc
	call crc_upd
	ld a,d
	push de
	call put_esc
	pop de
	ld a,e
	call put_esc
	ld a,(zd_end)
	cp #ZCRCW
	ret nz
	ld a,#XON
	jp putc

; Read one ZDLE-decoded byte.
; Out: NC, A = byte and C = 0; or NC, A = C = a frame-end character.
;      C: A = ERR_TIMEOUT, ERR_CAN or ERR_BADESC.
; Clobbers AF, B, C.
zdlread:
	call getc
	jr c,zdl_timeout
	cp #ZDLE
	jr z,zdl_escape
	ld c,a
	and #0x7f
	cp #XON
	jr z,zdlread
	cp #XOFF
	jr z,zdlread
	ld a,c
	ld c,#0
	or a
	ret
zdl_escape:
	call getc
	jr c,zdl_timeout
	cp #ZDLE
	jr z,zdl_cancel
	cp #ZCRCE
	jr c,zdl_notend
	cp #ZCRCW + 1
	jr nc,zdl_notend
	ld c,a
	or a
	ret
zdl_notend:
	cp #ZRUB0
	jr nz,zdl_rub1
	ld a,#0x7f
	jr zdl_data
zdl_rub1:
	cp #ZRUB1
	jr nz,zdl_plain
	ld a,#0xff
	jr zdl_data
zdl_plain:
	ld c,a
	and #0x7f
	cp #XON
	jr z,zdl_escape
	cp #XOFF
	jr z,zdl_escape
	ld a,c
	and #0x60
	cp #0x40
	jr nz,zdl_bad
	ld a,c
	xor #0x40
zdl_data:
	ld c,#0
	or a
	ret
zdl_cancel:
	; Two CANs so far.  Three more make the five that cancel a session.
	ld b,#3
zdl_can_more:
	call getc
	jr c,zdl_timeout
	cp #CAN
	jr nz,zdl_bad
	djnz zdl_can_more
	ld a,#ERR_CAN
	scf
	ret
zdl_bad:
	ld a,#ERR_BADESC
	scf
	ret
zdl_timeout:
	ld a,#ERR_TIMEOUT
	scf
	ret

; Receive a data subpacket at HL.  zr_limpage = the page it must not reach.
; Out: NC, A = frame end, HL = one past the data.  C: A = ERR_*.
zrdata:
	ld de,#0
zrd_byte:
	call zdlread
	ret c
	inc c
	dec c
	jr nz,zrd_end
	ld (hl),a
	inc hl
	call crc_upd
	ld a,(zr_limpage)
	cp h
	jr nz,zrd_byte
	ld a,#ERR_LONG
	scf
	ret
zrd_end:
	ld (zd_end),a
	call crc_upd
	call zdlread
	ret c
	inc c
	dec c
	jr nz,zrd_crc_bad
	call crc_upd
	call zdlread
	ret c
	inc c
	dec c
	jr nz,zrd_crc_bad
	call crc_upd
	ld a,d
	or e
	jr nz,zrd_crc_bad
	ld a,(zd_end)
	ret
zrd_crc_bad:
	ld a,#ERR_CRC
	scf
	ret

; Receive a header.  In: rx_ticks = per-character timeout.
; Out: NC, A = type, rxhdr = its four data bytes.  C: A = ERR_*.
;
; ZBIN32 headers are not accepted: ZRINIT never offers CANFC32, so a compliant
; sender does not use them.
zgethdr:
	ld hl,#4096
	ld (zg_garbage),hl
	xor a
	ld (zg_cans),a
zg_seek:
	call getc
	jp c,zg_timeout
zg_have:
	cp #ZPAD
	jr z,zg_pad
	cp #CAN
	jr nz,zg_junk
	ld a,(zg_cans)
	inc a
	ld (zg_cans),a
	cp #5
	jr c,zg_count
	ld a,#ERR_CAN
	scf
	ret
zg_junk:
	xor a
	ld (zg_cans),a
zg_count:
	ld hl,(zg_garbage)
	dec hl
	ld (zg_garbage),hl
	ld a,h
	or l
	jr nz,zg_seek
	ld a,#ERR_GARBAGE
	scf
	ret
zg_pad:
	xor a
	ld (zg_cans),a
	call getc
	jr c,zg_timeout
	cp #ZPAD
	jr z,zg_pad
	cp #ZDLE
	jr nz,zg_have
	call getc
	jr c,zg_timeout
	cp #ZBIN
	jr z,zg_bin
	cp #ZHEX
	jr z,zg_hex
	jr zg_have

zg_bin:
	ld de,#0
	ld hl,#rxtype
	ld b,#7				; type, four data bytes, CRC
zgb_byte:
	push bc
	call zdlread
	jr c,zgb_err
	inc c
	dec c
	jr nz,zgb_bad
	ld (hl),a
	inc hl
	call crc_upd
	pop bc
	djnz zgb_byte
	jr zg_check

zg_hex:
	ld de,#0
	ld hl,#rxtype
	ld b,#7
zgh_byte:
	push bc
	call get_hex
	jr c,zgb_err
	ld (hl),a
	inc hl
	call crc_upd
	pop bc
	djnz zgh_byte
zg_check:
	ld a,d
	or e
	jr nz,zg_crc
	ld a,(rxtype)
	or a
	ret
zgb_bad:
	ld a,#ERR_BADESC
	scf
zgb_err:
	pop bc
	ret
zg_crc:
	ld a,#ERR_CRC
	scf
	ret
zg_timeout:
	ld a,#ERR_TIMEOUT
	scf
	ret

; Two hex digits -> A.  C: A = ERR_*.  Clobbers C.
get_hex:
	call get_nibble
	ret c
	rlca
	rlca
	rlca
	rlca
	ld c,a
	call get_nibble
	ret c
	or c
	ret
get_nibble:
	call getc
	jr c,gn_timeout
	and #0x7f
	cp #'0
	jr c,gn_bad
	cp #'9 + 1
	jr c,gn_digit
	or #0x20
	cp #'a
	jr c,gn_bad
	cp #'f + 1
	jr nc,gn_bad
	sub #0x57
	ret
gn_digit:
	sub #'0
	ret
gn_bad:
	ld a,#ERR_GARBAGE
	scf
	ret
gn_timeout:
	ld a,#ERR_TIMEOUT
	scf
	ret

; ===========================================================================
; Common failure exits.  Jump here only from a protocol's own level, never
; from inside a CALL: they return to dispatch.
; ===========================================================================

p_cancelled:
	ld de,#msg_cancelled
	scf
	ret
p_userabort:
	call send_cancel
	ld de,#msg_aborted
	scf
	ret
p_diskerr:
	call send_cancel
	ld de,#msg_disk
	scf
	ret
p_errors:
	call send_cancel
	ld de,#msg_errors
	scf
	ret
p_noresponse:
	call send_cancel
	ld de,#msg_noresponse
	scf
	ret

; ===========================================================================
; ZMODEM receive
; ===========================================================================

zm_recv:
	ld a,#12			; a minute to start the sender
	ld (retries),a
zr_init:
	call rts_on
	ld hl,#ZRX_BUFLEN
	ld (txhdr),hl
	xor a
	ld (txhdr + 2),a
	ld a,#CANFDX
	ld (txhdr + 3),a
	ld a,#ZRINIT
	call zs_hexhdr
zr_hdr:
	ld hl,#5 * TICKS_1S
	call set_ticks
	call zgethdr
	jr nc,zr_got
	cp #ERR_CAN
	jp z,p_cancelled
	call kbcheck
	jp c,p_userabort
	ld hl,#retries
	dec (hl)
	jr nz,zr_init
	jp p_noresponse
zr_got:
	cp #ZRQINIT
	jr z,zr_init
	cp #ZFILE
	jr z,zr_file
	cp #ZSINIT
	jr z,zr_sinit
	cp #ZFIN
	jr z,zr_fin
	jr zr_init

zr_sinit:
	ld hl,#SCRATCH
	ld a,#SCRATCH_END_PAGE
	ld (zr_limpage),a
	call zrdata
	jr c,zr_init
	call zero_txhdr
	ld a,#ZACK
	call zs_hexhdr
	jr zr_hdr

zr_fin:
	call zero_txhdr
	ld a,#ZFIN
	call zs_hexhdr
	ld hl,#TICKS_1S
	call set_ticks
	call getc			; the sender's "OO", if it sends one
	call getc
	or a
	ret

zr_file:
	ld hl,#SCRATCH
	ld a,#SCRATCH_END_PAGE
	ld (zr_limpage),a
	call zrdata
	jp c,zr_init			; the sender repeats ZFILE
	ld (hl),#0
	ld a,(arg_fcb)
	ld (fcb),a
	ld hl,#SCRATCH
	call name_to_fcb
	ld hl,#SCRATCH
zf_skipname:
	ld a,(hl)
	inc hl
	or a
	jr nz,zf_skipname
	call parse_dec
	ld hl,#parsed32
	ld de,#fsize
	ld bc,#4
	ldir
	ld a,#1
	ld (size_known),a
	call rts_off
	call show_file
	call wfile_create
	push af
	call rts_on
	pop af
	jr nc,zf_made
	ld de,#msg_nocreate
	call puts
	call zero_txhdr
	ld a,#ZSKIP
	call zs_hexhdr
	jp zr_hdr
zf_made:
	call zero_pos
	xor a
	ld (errors),a
zr_rpos:
	ld hl,#errors
	inc (hl)
	ld a,(hl)
	cp #MAX_ERRORS * 2
	jp nc,p_errors
	call pos_to_txhdr
	ld a,#ZRPOS
	call zs_hexhdr
zr_dhdr:
	ld hl,#10 * TICKS_1S
	call set_ticks
	call zgethdr
	jr nc,zr_dgot
	cp #ERR_CAN
	jp z,p_cancelled
	call kbcheck
	jp c,p_userabort
	jr zr_rpos
zr_dgot:
	cp #ZDATA
	jr z,zr_zdata
	cp #ZEOF
	jr z,zr_zeof
	cp #ZFILE
	jr z,zr_dupfile
	cp #ZFIN
	jp z,p_cancelled		; sender quit mid-file
	jr zr_rpos

zr_dupfile:
	; Our ZRPOS was lost.  Swallow the repeat and say it again.
	ld hl,#SCRATCH
	ld a,#SCRATCH_END_PAGE
	ld (zr_limpage),a
	call zrdata
	jr zr_rpos

zr_zeof:
	ld hl,#rxhdr
	ld de,#pos
	call cmp4
	jr nz,zr_dhdr			; stale: data is still on its way
	call rts_off
	call wfile_close
	jp c,p_diskerr
	call progress_show
	ld a,#5
	ld (retries),a
	jp zr_init

zr_zdata:
	ld hl,#rxhdr
	ld de,#pos
	call cmp4
	jr nz,zr_rpos
zr_sub:
	ld hl,(fill)
	ld de,#RXBUF
	add hl,de
	ld (zr_start),hl
	ld a,#RXBUF_END_PAGE
	ld (zr_limpage),a
	call zrdata
	jr nc,zr_subok
	cp #ERR_CAN
	jp z,p_cancelled
	jp zr_rpos
zr_subok:
	ld (zr_fe),a
	ld de,(zr_start)
	or a
	sbc hl,de
	ld b,h
	ld c,l
	push bc
	ld hl,(fill)
	add hl,bc
	ld (fill),hl
	pop bc
	ld hl,#pos
	call add32_bc
	xor a
	ld (errors),a
	ld a,(zr_fe)
	cp #ZCRCW
	jr z,zr_crcw
	cp #ZCRCQ
	jr z,zr_crcq
	cp #ZCRCG
	jr z,zr_crcg
	call zr_maybe_flush		; ZCRCE: a header follows
	jp c,p_diskerr
	jp zr_dhdr
zr_crcg:
	call zr_maybe_flush
	jp c,p_diskerr
	jr zr_sub
zr_crcq:
	call zr_maybe_flush
	jp c,p_diskerr
	call pos_to_txhdr
	ld a,#ZACK
	call zs_hexhdr
	jr zr_sub
zr_crcw:
	; The sender is waiting for our ZACK: the one safe place to write.
	call rts_off
	ld hl,#0
	call wfile_flush
	jp c,p_diskerr
	call progress_tick
	call kbabort
	jp c,p_userabort
	call rts_on
	call pos_to_txhdr
	ld a,#ZACK
	call zs_hexhdr
	jp zr_dhdr

; A sender that ignores the advertised buffer keeps streaming.  Write anyway
; once the buffer is half full, behind RTS; ZRPOS repairs any loss.
zr_maybe_flush:
	ld hl,(fill)
	ld de,#FLUSH_AT
	or a
	sbc hl,de
	ccf
	ret nc
	call rts_off
	ld hl,#0
	call wfile_flush
	push af
	call rts_on
	pop af
	ret

; ===========================================================================
; ZMODEM send
; ===========================================================================

zm_send:
	ld hl,#str_rz
	call send_str
	ld a,#12
	ld (retries),a
zs_rq:
	call zero_txhdr
	ld a,#ZRQINIT
	call zs_hexhdr
zs_rqwait:
	call rts_on
	ld hl,#5 * TICKS_1S
	call set_ticks
	call zgethdr
	jr nc,zs_rqgot
	cp #ERR_CAN
	jp z,p_cancelled
	call kbcheck
	jp c,p_userabort
zs_rqretry:
	ld hl,#retries
	dec (hl)
	jr nz,zs_rq
	jp p_noresponse
zs_rqgot:
	cp #ZRINIT
	jr z,zs_rinit
	cp #ZCHALLENGE
	jr nz,zs_rqretry
	ld hl,#rxhdr
	ld de,#txhdr
	ld bc,#4
	ldir
	ld a,#ZACK
	call zs_hexhdr
	jr zs_rqwait
zs_rinit:
	ld a,(rxhdr + 3)
	and #ESCCTL
	ld (esc_ctl),a

zs_next:
	call rts_off
	call fl_next
	jp c,zs_fin
	call rfile_open
	jr c,zs_next			; gone since it was listed
	call show_file
	ld a,#MAX_ERRORS
	ld (retries),a
zs_zfile:
	call rts_off
	; "name.ext" NUL "size" NUL
	ld de,#TXBUF
	ld c,#0x20
	call fcb_to_str
	inc de
	ld hl,#fsize
	call fmt_dec32
	inc de
	ld hl,#-TXBUF
	add hl,de
	ld (tx_len),hl
	call zero_txhdr
	ld a,#ZCBIN
	ld (txhdr + 3),a
	ld a,#ZFILE
	call zs_binhdr
	ld hl,#TXBUF
	ld bc,(tx_len)
	ld a,#ZCRCW
	call zs_data
zs_fwait:
	call rts_on
	ld hl,#10 * TICKS_1S
	call set_ticks
	call zgethdr
	jr nc,zs_fgot
	cp #ERR_CAN
	jp z,p_cancelled
	call kbcheck
	jp c,p_userabort
zs_fretry:
	ld hl,#retries
	dec (hl)
	jr nz,zs_zfile
	jp p_noresponse
zs_fgot:
	cp #ZRPOS
	jr z,zs_rpos
	cp #ZSKIP
	jr z,zs_skipped
	cp #ZCRC
	jr nz,zs_fretry
	; The receiver wants a file CRC to decide on resuming.  We keep none;
	; zero never matches, so it takes the whole file.
	call zero_txhdr
	ld a,#ZCRC
	call zs_hexhdr
	jr zs_fwait
zs_skipped:
	ld de,#msg_skipped
	call puts
	jp zs_next

zs_rpos:
	call rxhdr_to_pos
	ld a,#MAX_ERRORS
	ld (retries),a
zs_block:
	; One ZCRCW frame per 1K: every block waits for its ZACK, the same pacing
	; the receive side asks of the PC.  RTS stays released while the frame
	; goes out, so the receiver's replies wait in the PC.
	call rts_off
	ld hl,#1024
	ld (want),hl
	call rfile_read
	ld hl,(tx_len)
	ld a,h
	or l
	jr z,zs_eof
	call pos_to_txhdr
	ld a,#ZDATA
	call zs_binhdr
	ld hl,#TXBUF
	ld bc,(tx_len)
	ld a,#ZCRCW
	call zs_data
zs_bwait:
	call rts_on
	ld hl,#10 * TICKS_1S
	call set_ticks
	call zgethdr
	jr nc,zs_bgot
	cp #ERR_CAN
	jp z,p_cancelled
	call kbcheck
	jp c,p_userabort
zs_bretry:
	ld hl,#retries
	dec (hl)
	jr nz,zs_block
	jp p_noresponse
zs_bgot:
	cp #ZACK
	jr z,zs_acked
	cp #ZSKIP
	jr z,zs_skipped
	cp #ZRPOS
	jr nz,zs_bretry
	call rxhdr_to_pos
	jr zs_bretry
zs_acked:
	ld bc,(tx_len)
	ld hl,#pos
	call add32_bc
	ld a,#MAX_ERRORS
	ld (retries),a
	call rts_off
	call progress_tick
	call kbabort
	jp c,p_userabort
	jr zs_block

zs_eof:
	call pos_to_txhdr
	ld a,#ZEOF
	call zs_binhdr
	call rts_on
	ld hl,#10 * TICKS_1S
	call set_ticks
	call zgethdr
	jr nc,zs_egot
	cp #ERR_CAN
	jp z,p_cancelled
	call kbcheck
	jp c,p_userabort
zs_eretry:
	ld hl,#retries
	dec (hl)
	jr nz,zs_eof
	jp p_noresponse
zs_egot:
	cp #ZRINIT
	jr z,zs_filedone
	cp #ZRPOS
	jp z,zs_rpos
	jr zs_eretry
zs_filedone:
	call rts_off
	call progress_show
	jp zs_next

zs_fin:
	ld a,#5
	ld (retries),a
zs_fin_send:
	call zero_txhdr
	ld a,#ZFIN
	call zs_hexhdr
	call rts_on
	ld hl,#5 * TICKS_1S
	call set_ticks
	call zgethdr
	jr c,zs_fin_retry
	cp #ZFIN
	jr nz,zs_fin_retry
	ld a,#'O
	call putc
	call putc
	or a
	ret
zs_fin_retry:
	ld hl,#retries
	dec (hl)
	jr nz,zs_fin_send
	or a				; every file was acknowledged already
	ret

; HL = NUL-terminated string to send raw.
send_str:
	ld a,(hl)
	or a
	ret z
	call putc
	inc hl
	jr send_str

; ===========================================================================
; XMODEM / YMODEM receive
; ===========================================================================

xm_recv:
	xor a
	ld (ymodem),a
	ld (size_known),a
	call rts_off
	call show_file
	call rts_on
	ld a,#1
	ld (xy_expect),a
	jr xy_recv

ym_recv:
	ld a,#1
	ld (ymodem),a
yr_next:
	xor a
	ld (xy_expect),a
	ld (size_known),a
	inc a
	ld (yr_header),a
xy_recv:
	call zero_pos
	xor a
	ld (xy_started),a
	ld (errors),a
	ld a,#1
	ld (crc_mode),a
	ld a,#20			; 'C' every 3 s: a minute to start the sender
	ld (retries),a
	call rts_on
xr_poke:
	ld a,(xy_started)
	or a
	ld a,#NAK
	jr nz,xr_poke_send
	ld a,(crc_mode)
	or a
	ld a,#'C
	jr nz,xr_poke_send
	ld a,#NAK
xr_poke_send:
	call putc
xr_wait:
	ld hl,#3 * TICKS_1S
	call set_ticks
	call getc
	jr nc,xr_char
	call kbcheck
	jp c,p_userabort
	ld hl,#retries
	dec (hl)
	jp z,xr_giveup
	; XMODEM only: ten unanswered 'C's and the sender may be checksum-only.
	ld a,(ymodem)
	or a
	jr nz,xr_poke
	ld a,(xy_started)
	or a
	jr nz,xr_poke
	ld a,(retries)
	cp #10
	jr nz,xr_poke
	xor a
	ld (crc_mode),a
	jr xr_poke

xr_char:
	cp #SOH
	jr z,xr_soh
	cp #STX
	jr z,xr_stx
	cp #EOT
	jp z,xr_eot
	cp #CAN
	jr nz,xr_wait
	ld hl,#TICKS_1S
	call set_ticks
	call getc
	jr c,xr_wait
	cp #CAN
	jr nz,xr_wait
	jp p_cancelled
xr_soh:
	ld hl,#128
	jr xr_block
xr_stx:
	ld hl,#1024
xr_block:
	ld (blk_len),hl
	ld hl,#TICKS_1S
	call set_ticks
	call getc
	jp c,xr_bad
	ld (blk_num),a
	ld c,a
	call getc
	jp c,xr_bad
	cpl
	cp c
	jp nz,xr_bad

	; A YMODEM header block goes to SCRATCH; data goes straight after what
	; is already buffered, and only counts once it checks out.
	ld hl,(fill)
	ld de,#RXBUF
	add hl,de
	ld a,(yr_header)
	or a
	jr z,xr_dest
	ld hl,#SCRATCH
xr_dest:
	ld (blk_dest),hl
	ld bc,(blk_len)
	ld a,(crc_mode)
	or a
	jr z,xr_sum
	ld de,#0
xr_crc_byte:
	call getc
	jr c,xr_bad
	ld (hl),a
	inc hl
	push bc
	call crc_upd
	pop bc
	dec bc
	ld a,b
	or c
	jr nz,xr_crc_byte
	call getc
	jr c,xr_bad
	call crc_upd
	call getc
	jr c,xr_bad
	call crc_upd
	ld a,d
	or e
	jr nz,xr_bad
	jr xr_good
xr_sum:
	ld e,#0
xr_sum_byte:
	call getc
	jr c,xr_bad
	ld (hl),a
	inc hl
	add a,e
	ld e,a
	dec bc
	ld a,b
	or c
	jr nz,xr_sum_byte
	call getc
	jr c,xr_bad
	cp e
	jr nz,xr_bad

xr_good:
	xor a
	ld (errors),a
	ld (hl),a			; terminates a block-0 name that fills it
	ld a,(blk_num)
	ld c,a
	ld a,(xy_expect)
	cp c
	jr z,xr_new
	dec a
	cp c
	jr z,xr_dup
	call send_cancel
	ld de,#msg_sequence
	scf
	ret
xr_dup:
	; Our ACK was lost and the sender repeated the block.
	ld a,#ACK
	call putc
	ld a,(ymodem)
	or a
	jp z,xr_wait
	ld a,(xy_started)
	or a
	jp nz,xr_wait
	ld a,c
	or a
	jp nz,xr_wait
	ld a,#'C			; a repeated header wants 'C' again
	call putc
	jp xr_wait

xr_bad:
	ld hl,#errors
	inc (hl)
	ld a,(hl)
	cp #MAX_ERRORS
	jp nc,p_errors
	call purge
	ld a,#NAK
	call putc
	jp xr_wait

xr_new:
	ld a,(yr_header)
	or a
	jr nz,yr_header_block
	ld a,#1
	ld (xy_started),a
	jp xr_data

	; YMODEM block 0: "name" NUL "size ..." -- or an empty name, which ends
	; the batch.  Recognised by state, never by block number: numbers wrap
	; every 256 blocks, and a 128-byte sender reaches block "0" again at
	; 32K into a file.
yr_header_block:
	ld a,(SCRATCH)
	or a
	jr z,yr_batch_end
	ld a,(arg_fcb)
	ld (fcb),a
	ld hl,#SCRATCH
	call name_to_fcb
	ld hl,#SCRATCH
yr_skipname:
	ld a,(hl)
	inc hl
	or a
	jr nz,yr_skipname
	call parse_dec
	ld hl,#parsed32
	ld de,#fsize
	ld bc,#4
	ldir
	ld hl,#parsed32
	ld de,#remain
	ld bc,#4
	ldir
	; A size of zero is as likely "not given" as an empty file; either way,
	; treat it as unknown and trim instead.
	ld hl,#parsed32
	call is_zero4
	ld a,#0
	jr z,yr_known
	inc a
yr_known:
	ld (size_known),a
	call rts_off
	call show_file
	call wfile_create
	push af
	call rts_on
	pop af
	jp c,yr_nocreate
	ld a,#1
	ld (xy_expect),a
	xor a
	ld (xy_started),a
	ld (yr_header),a
	ld a,#20
	ld (retries),a
	ld a,#ACK
	call putc
	jp xr_poke			; 'C' starts the data

yr_nocreate:
	call send_cancel
	ld de,#msg_nocreate
	scf
	ret

yr_batch_end:
	ld a,#ACK
	call putc
	or a
	ret

xr_data:
	ld bc,(blk_len)
	ld a,(size_known)
	or a
	jr z,xr_commit
	; Clip the block to what the header said is left.
	ld hl,#remain + 2
	ld a,(hl)
	inc hl
	or (hl)
	jr nz,xr_clipped
	ld hl,(remain)
	or a
	sbc hl,bc
	jr nc,xr_clipped
	ld bc,(remain)
xr_clipped:
	push bc
	ld hl,#remain
	call sub32_bc
	pop bc
xr_commit:
	ld hl,(fill)
	add hl,bc
	ld (fill),hl
	ld hl,#pos
	call add32_bc
	ld hl,#xy_expect
	inc (hl)

	; The sender waits for the ACK, so this is where the disk gets written.
	call rts_off
	ld hl,(fill)
	ld de,#FLUSH_AT
	or a
	sbc hl,de
	jr c,xr_ack
	ld hl,#0
	ld a,(size_known)
	or a
	jr nz,xr_flush
	ld hl,#1024			; keep the last block for trim_ctrlz
xr_flush:
	call wfile_flush
	jp c,p_diskerr
xr_ack:
	call progress_tick
	call kbabort
	jp c,p_userabort
	call rts_on
	ld a,#10
	ld (retries),a
	ld a,#ACK
	call putc
	jp xr_wait

xr_eot:
	ld a,(wfile_open)
	or a
	jr nz,xr_eot_file
	ld a,#ACK			; a repeated EOT after the file closed
	call putc
	jp xr_wait
xr_eot_file:
	call rts_off
	ld a,(size_known)
	or a
	call z,trim_ctrlz
	call wfile_close
	jp c,p_diskerr
	call progress_show
	call rts_on
	ld a,#ACK
	call putc
	ld a,(ymodem)
	or a
	ret z				; XMODEM: one file, done
	jp yr_next

xr_giveup:
	; Files a YMODEM batch already closed stay on disk; wfile_abort removes
	; only the one still open.
	jp p_noresponse

; Z if the four bytes at HL are zero.
is_zero4:
	ld a,(hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	inc hl
	or (hl)
	ret

; ===========================================================================
; XMODEM / YMODEM send
; ===========================================================================

xm_send:
	xor a
	ld (ymodem),a
	call show_file
	jr xs_handshake

ym_send:
	ld a,#1
	ld (ymodem),a

xs_handshake:
	call rts_on
	ld a,#60
	ld (retries),a
xs_hs_wait:
	ld hl,#TICKS_1S
	call set_ticks
	call getc
	jr c,xs_hs_timeout
	cp #'C
	jr z,xs_hs_crc
	cp #NAK
	jr z,xs_hs_sum
	cp #CAN
	jr nz,xs_hs_wait
	call getc
	jr c,xs_hs_wait
	cp #CAN
	jr nz,xs_hs_wait
	jp p_cancelled
xs_hs_timeout:
	call kbcheck
	jp c,p_userabort
	ld hl,#retries
	dec (hl)
	jr nz,xs_hs_wait
	jp p_noresponse
xs_hs_crc:
	ld a,#1
	jr xs_hs_mode
xs_hs_sum:
	xor a
xs_hs_mode:
	ld (crc_mode),a
	ld a,(ymodem)
	or a
	jr z,xs_file_data

ys_next:
	call rts_off
	call fl_next
	jp c,ys_end
	call rfile_open
	jr c,ys_next
	call show_file
	; Block 0: "name" NUL "size" NUL, zero padded.
	ld hl,#TXBUF
	ld b,#128
ys_zero:
	ld (hl),#0
	inc hl
	djnz ys_zero
	ld de,#TXBUF
	ld c,#0x20
	call fcb_to_str
	inc de
	ld hl,#fsize
	call fmt_dec32
	ld hl,#128
	ld (tx_len),hl
	xor a
	ld (blk_num),a
	call xs_sendblock
	ret c
	call xs_wait_start
	ret c
xs_file_data:
	call zero_pos
	ld a,#1
	ld (blk_num),a
xs_data:
	call rts_off
	ld hl,#1024
	ld a,(crc_mode)
	or a
	jr nz,xs_want
	ld hl,#128
xs_want:
	ld (want),hl
	call rfile_read
	ld hl,(tx_len)
	ld a,h
	or l
	jr z,xs_eot
	ld (data_len),hl
	; Pad with ^Z to a block; a short tail fits a 128-byte block.
	ld de,#129
	or a
	sbc hl,de
	ld hl,#128
	jr c,xs_pad
	ld hl,#1024
xs_pad:
	push hl
	ld de,(data_len)
	or a
	sbc hl,de
	ld b,h
	ld c,l
	ld hl,(data_len)
	ld de,#TXBUF
	add hl,de
xs_pad_byte:
	ld a,b
	or c
	jr z,xs_padded
	ld (hl),#CPMEOF
	inc hl
	dec bc
	jr xs_pad_byte
xs_padded:
	pop hl
	ld (tx_len),hl
	call xs_sendblock
	ret c
	ld bc,(data_len)
	ld hl,#pos
	call add32_bc
	ld hl,#blk_num
	inc (hl)
	call rts_off
	call progress_tick
	call kbabort
	jp c,p_userabort
	jr xs_data

xs_eot:
	ld a,#MAX_ERRORS
	ld (retries),a
xs_eot_send:
	ld a,#EOT
	call putc
	call rts_on
	ld hl,#10 * TICKS_1S
	call set_ticks
	call getc
	jr c,xs_eot_retry
	cp #ACK
	jr z,xs_eot_acked
	; NAK is the usual answer to the first EOT: send it again.
xs_eot_retry:
	ld hl,#retries
	dec (hl)
	jr nz,xs_eot_send
	jp p_noresponse
xs_eot_acked:
	call rts_off
	call progress_show
	ld a,(ymodem)
	or a
	ret z
	call xs_wait_start		; the receiver's 'C' for the next header
	ret c
	jp ys_next

ys_end:
	; An empty block 0 ends the batch.
	ld hl,#TXBUF
	ld b,#128
ys_end_zero:
	ld (hl),#0
	inc hl
	djnz ys_end_zero
	ld hl,#128
	ld (tx_len),hl
	xor a
	ld (blk_num),a
	call xs_sendblock
	ret c
	or a
	ret

; Send block blk_num: TXBUF, tx_len 128 or 1024.  Waits for the ACK.
; Out: C with DE = message on failure.
xs_sendblock:
	ld a,#MAX_ERRORS
	ld (retries),a
xsb_send:
	call rts_off
	ld a,(tx_len + 1)
	or a
	ld a,#SOH
	jr z,xsb_type
	ld a,#STX
xsb_type:
	call putc
	ld a,(blk_num)
	call putc
	cpl
	call putc
	ld hl,#TXBUF
	ld bc,(tx_len)
	ld de,#0
	ld a,(crc_mode)
	or a
	jr z,xsb_sum
xsb_crc_byte:
	ld a,(hl)
	call putc
	push bc
	call crc_upd
	pop bc
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,xsb_crc_byte
	ld a,d
	call putc
	ld a,e
	call putc
	jr xsb_wait
xsb_sum:
	ld a,(hl)
	call putc
	add a,e
	ld e,a
	inc hl
	dec bc
	ld a,b
	or c
	jr nz,xsb_sum
	ld a,e
	call putc
xsb_wait:
	call rts_on
	ld hl,#10 * TICKS_1S
	call set_ticks
	call getc
	jr c,xsb_retry
	cp #ACK
	ret z
	cp #NAK
	jr z,xsb_retry
	cp #CAN
	jr nz,xsb_wait			; stray 'C's and line noise
	ld hl,#TICKS_1S
	call set_ticks
	call getc
	jr c,xsb_wait
	cp #CAN
	jr nz,xsb_wait
	ld de,#msg_cancelled
	scf
	ret
xsb_retry:
	call kbcheck
	jr c,xsb_user
	ld hl,#retries
	dec (hl)
	jp nz,xsb_send
	call send_cancel
	ld de,#msg_noresponse
	scf
	ret
xsb_user:
	call send_cancel
	ld de,#msg_aborted
	scf
	ret

; Wait for the receiver's 'C' (or NAK).  Out: C with DE = message on failure.
xs_wait_start:
	ld a,#MAX_ERRORS
	ld (retries),a
xws_wait:
	call rts_on
	ld hl,#10 * TICKS_1S
	call set_ticks
	call getc
	jr c,xws_timeout
	cp #'C
	ret z
	cp #NAK
	ret z
	jr xws_wait
xws_timeout:
	ld hl,#retries
	dec (hl)
	jr nz,xws_wait
	call send_cancel
	ld de,#msg_noresponse
	scf
	ret

; ===========================================================================
; Strings
; ===========================================================================

msg_banner:
	.ascii "XFER 1.0 - X/Y/ZMODEM on the serial console"
	.db 13,10,0
msg_usage:
	.ascii "  XFER ZR [d:]       ZMODEM receive"
	.db 13,10
	.ascii "  XFER ZS [d:]afn    ZMODEM send"
	.db 13,10
	.ascii "  XFER YR [d:]       YMODEM batch receive"
	.db 13,10
	.ascii "  XFER YS [d:]afn    YMODEM batch send"
	.db 13,10
	.ascii "  XFER XR [d:]name   XMODEM receive"
	.db 13,10
	.ascii "  XFER XS [d:]name   XMODEM send"
	.db 13,10
	.ascii "The PC must use RTS/CTS flow control.  ESC or ^C aborts."
	.db 13,10,0
msg_anykey:
	.ascii "Press a key..."
	.db 0
msg_go:
	.ascii "Start the transfer on the PC.  ESC or ^C aborts."
	.db 13,10,0
msg_done:
	.db 13,10
	.ascii "Transfer complete."
	.db 13,10,0
msg_failed:
	.db 13,10
	.ascii "Transfer failed: "
	.db 0
msg_memory:
	.ascii "Not enough memory."
	.db 0
msg_driveonly:
	.ascii "Give a drive only: the sender names the files."
	.db 0
msg_needname:
	.ascii "Give a file name."
	.db 0
msg_nowild:
	.ascii "No wildcards here."
	.db 0
msg_nofiles:
	.ascii "No matching files."
	.db 0
msg_nofile:
	.ascii "File not found."
	.db 0
msg_nocreate:
	.ascii "cannot create the file (directory full?)"
	.db 0
msg_cancelled:
	.ascii "cancelled by the PC."
	.db 0
msg_aborted:
	.ascii "aborted from the keyboard."
	.db 0
msg_disk:
	.ascii "disk write failed (disk full?)"
	.db 0
msg_errors:
	.ascii "too many errors."
	.db 0
msg_noresponse:
	.ascii "no response from the PC."
	.db 0
msg_sequence:
	.ascii "block sequence lost."
	.db 0
msg_skipped:
	.ascii "    skipped by the PC"
	.db 0
msg_indent:
	.ascii "    "
	.db 0
msg_bytes:
	.ascii " bytes"
	.db 0
msg_open:
	.ascii "  ("
	.db 0
msg_bytes_close:
	.ascii " bytes)"
	.db 0
str_rz:
	.ascii "rz"
	.db 13,0
str_unnamed:
	.ascii "UNNAMED "
str_badchars:
	.ascii "<>.,;:=?*[]|"
str_badchars_end:

	.include "zbdos.inc"

; ===========================================================================
; Variables: past the image, cleared at start
; ===========================================================================

vars_start:
proto_vec:	.ds 2
rx_ticks:	.ds 2
tx_dead:	.ds 1
sercon_ptr:	.ds 2
sercon_saved:	.ds 1
arg_fcb:	.ds 12
fcb:		.ds 36
sfcb:		.ds 36
dirbuf:		.ds 128
recbuf:		.ds 128
namebuf:	.ds 16
numbuf:		.ds 12
fill:		.ds 2
keep:		.ds 2
wptr:		.ds 2
want:		.ds 2
tx_len:		.ds 2
data_len:	.ds 2
rrec:		.ds 2
roff:		.ds 1
wfile_open:	.ds 1
pos:		.ds 4
fsize:		.ds 4
remain:		.ds 4
parsed32:	.ds 4
num_work:	.ds 4
size_known:	.ds 1
rxtype:		.ds 1
rxhdr:		.ds 4
rxcrc:		.ds 2
txhdr:		.ds 4
zh_type:	.ds 1
zd_end:		.ds 1
zr_fe:		.ds 1
zr_limpage:	.ds 1
zr_start:	.ds 2
zg_garbage:	.ds 2
zg_cans:	.ds 1
esc_ctl:	.ds 1
retries:	.ds 1
errors:		.ds 1
nfiles:		.ds 1
fl_index:	.ds 1
fl_ptr:		.ds 2
ymodem:		.ds 1
crc_mode:	.ds 1
xy_expect:	.ds 1
xy_started:	.ds 1
yr_header:	.ds 1
blk_num:	.ds 1
blk_len:	.ds 2
blk_dest:	.ds 2
prog_cnt:	.ds 1
vars_end:
		.ds 256
stack_top:

	.ifgt (stack_top - start) - (RXBUF - 0x0100)
	.error 1			; the program has grown into its buffers
	.endif
