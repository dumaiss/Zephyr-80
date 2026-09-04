; IOC_SDREC.COM — exercise the PIC's record cache before any BIOS depends on it.
;
; The SD storage driver will ask for 128-byte CP/M records and never see a
; block.  That means the PIC is now doing read-modify-write on the host's
; behalf, and this program exists to prove it does it correctly BEFORE the
; filesystem is sitting on top.
;
;   Z80                          PIC
;    |-- CMD_SD_WRITE_REC(rec) ->|  locate/load the containing block
;    |<-- READY(id, dir, 128) ---|
;    |======= 128 bytes ========>|  merge into the cache slot, mark dirty
;    |-- CMD_XFER_STATUS ------->|  MANDATORY: only DONE reports a bulk CRC fail
;    |<-- DONE(id, status) ------|
;
; Four phases, in this order deliberately:
;
;   A  write records 0-7, flush, read all 8 back
;        the round trip works at all
;   B  read records 8, 12, 16, 20
;        four different blocks, which with three unpinned slots forces the
;        block holding records 4-7 out of the cache
;   C  re-read records 4-7
;        THE POINT: that block now exists only on the card, so matching here
;        proves the deferred write was really committed before eviction and
;        not merely forgotten with the dirty bit cleared
;   D  rewrite record 5 alone, flush, check records 4, 6 and 7
;        THE OTHER POINT: a write of 128 bytes into a 512-byte block must not
;        disturb the other three records.  Get the read-modify-write wrong and
;        every write destroys 384 bytes of somebody else's data, silently, while
;        reporting success
;
; Phases C and D are the ones worth having.  A and B can pass on a cache that is
; badly broken.
;
; Test records only: this writes records 0-7, which are LBA 0 and 1 — the head
; of the CP/M directory. Run it before the volume holds anything.

	.module ioc_sdrec
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
IOCALL		= 0xDA3F	; ZBIOS_EXT_BASE + 0Ch
IOCBULK		= 0xDA45	; ZBIOS_EXT_BASE + 12h: bulk receive
IOCBULKW	= 0xDA48	; ZBIOS_EXT_BASE + 15h: bulk transmit


CMD_PING	 = 0x01
RSP_PING	 = 0x81
	.include "ioc_levels.inc"
	.include "ioc_diag_record.inc"
CMD_SD_READ_REC	 = 0x08
RSP_SD_READ_REC	 = 0x88
CMD_SD_WRITE_REC = 0x09
RSP_SD_WRITE_REC = 0x89
CMD_SD_FLUSH	 = 0x0A
RSP_SD_FLUSH	 = 0x8A
CMD_XFER_STATUS	 = 0x06
RSP_XFER_STATUS	 = 0x86

REC_SIZE	= 128

start:
	; .ds space is not zeroed by the CP/M loader, so anything read before it
	; is written holds whatever the last program left there.
	xor a
	ld (diag_valid),a
	ld (fail_info),a
	ld (raw_off),a
	ld (loop_mode),a
	ld hl,#0
	ld (pass_count),hl
	ld (base_rec),hl

	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	; Loop mode if the command tail is non-empty: `SDREC L`.
	; The default stays a single pass, so nothing that already works changes.
	ld a,(0x0080)			; CP/M command tail length
	or a
	jr z,no_loop
	ld a,#1
	ld (loop_mode),a
no_loop:

	; ---- firmware level ----
	; Printed before anything else so every screenshot of a failure says which
	; build produced it.  Twice now a stale flash has been diagnosed by
	; inference from symptoms -- once an unknown-command reply, once a request
	; field silently ignored -- and both cost a round trip to find out.
	call check_level
	or a
	jp nz,fail

pass_loop:
	; ---- phase A: write records 0-7, flush, verify ----
	ld de,#msg_pa
	call say
	ld a,#0
pa_write:
	call set_rec
	call seed_normal
	call fill_buf
	call wr_rec
	or a
	jp nz,fail
	ld a,(cur_off)
	inc a
	cp #8
	jr c,pa_write

	call do_flush
	or a
	jp nz,fail

	ld a,#0
pa_check:
	call set_rec
	call seed_normal
	call verify_rec
	or a
	jp nz,fail
	ld a,(cur_off)
	inc a
	cp #8
	jr c,pa_check
	call ok

	; ---- phase B: touch four other blocks to force eviction ----
	ld de,#msg_pb
	call say
	call evict
	or a
	jp nz,fail
	call ok

	; ---- phase C: records 4-7 must have survived on the card ----
	ld de,#msg_pc
	call say
	ld a,#4
pc_check:
	call set_rec
	call seed_normal
	call verify_rec
	or a
	jp nz,fail
	ld a,(cur_off)
	inc a
	cp #8
	jr c,pc_check
	call ok

	; ---- phase D: rewrite record 5 alone; 4, 6, 7 must not move ----
	ld de,#msg_pd
	call say
	ld a,#5
	call set_rec
	call seed_alt
	call fill_buf
	call wr_rec
	or a
	jp nz,fail
	call do_flush
	or a
	jp nz,fail

	; Evict before checking.  Without this the verify reads back the very slot
	; the merge happened in, which proves the memcpy and nothing else.  Pushing
	; the block out first means the bytes below come off the card, so this
	; tests the whole read-modify-write-commit path.
	call evict
	or a
	jp nz,fail

	ld a,#5				; the record we changed holds the new pattern
	call set_rec
	call seed_alt
	call verify_rec
	or a
	jp nz,fail

	ld a,#4				; its neighbours hold the old one
	call set_rec
	call seed_normal
	call verify_rec
	or a
	jp nz,fail
	ld a,#6
	call set_rec
	call seed_normal
	call verify_rec
	or a
	jp nz,fail
	ld a,#7
	call set_rec
	call seed_normal
	call verify_rec
	or a
	jp nz,fail
	call ok

	ld a,(loop_mode)
	or a
	jr nz,next_pass

	ld de,#msg_pass
	ld c,#BDOS_PRINT
	call BDOS
	ret

; ---------------------------------------------------------------------------
; One pass done.  Report, advance the base, and go again unless a key is down.
; ---------------------------------------------------------------------------
next_pass:
	ld hl,(pass_count)
	inc hl
	ld (pass_count),hl
	ld a,(pass_count)
	and #0x0f
	jr nz,np_base		; one progress line per 16 passes
	ld de,#msg_passno
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(pass_count + 1)
	call print_hex_byte
	ld a,(pass_count)
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
np_base:

	; Advance the base by 32 records (8 blocks) so a long run does not
	; program the same two blocks tens of thousands of times.  Every 8th pass
	; returns to base 0: that is the only base where slot 0 is pinned and LBA
	; 0 is write-through, so rotating away from it entirely would stop testing
	; the write-through path altogether.
	ld hl,(base_rec)
	ld de,#32
	add hl,de
	ld a,h
	cp #1				; wrap past record 255 (block 63)
	jr c,np_store
	ld hl,#0
np_store:
	ld (base_rec),hl
	ld a,(pass_count)
	and #0x07
	jr nz,np_go
	ld hl,#0
	ld (base_rec),hl		; back to the pinned/write-through case
np_go:
	; Abort on any keypress, so an unattended run can still be stopped.
	ld c,#0x0b			; BDOS console status
	call BDOS
	or a
	jp z,pass_loop			; jp: the pass body outgrew jr range
	ld c,#0x01			; consume the key
	call BDOS
	ld de,#msg_stopped
	ld c,#BDOS_PRINT
	call BDOS
	ret

; ---------------------------------------------------------------------------
; PING and report the controller's firmware level.  A = 0 if it matches what
; this program expects, else a failure code.
; ---------------------------------------------------------------------------
check_level:
	; BIOS level first: it is a memory read, needs no controller, and a stale
	; ROM cannot reliably speak the packet used by the PING below.
	ld de,#msg_bios
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	call print_hex_byte
	ld a,(ZBIOS_XPORT_LEVEL_ADDR)
	cp #ZBIOS_XPORT_LEVEL
	jr z,cl_bios_ok
	ld (fail_info),a
	ld de,#msg_stale_bios
	ld c,#BDOS_PRINT
	call BDOS
	ld a,#ZBIOS_XPORT_LEVEL
	call print_hex_byte
	ld de,#msg_reflash_rom
	ld c,#BDOS_PRINT
	call BDOS
	ld a,#0x44
	ret
cl_bios_ok:
	call zero_frames
	ld a,#CMD_PING
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jr nz,cl_xport
	ld a,(rx_frame + 0)
	cp #RSP_PING
	jr nz,cl_class

	ld de,#msg_fw
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 20)		; IOC_OFF_PING_LEVEL
	call print_hex_byte

	ld a,(rx_frame + 20)
	cp #IOC_FW_LEVEL
	jr nz,cl_stale
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	xor a
	ret
cl_stale:
	ld (fail_info),a
	ld de,#msg_stale
	ld c,#BDOS_PRINT
	call BDOS
	ld a,#IOC_FW_LEVEL
	call print_hex_byte
	ld de,#msg_reflash_fw
	ld c,#BDOS_PRINT
	call BDOS
	ld a,#0x41			; controller firmware is not the expected level
	ret
cl_xport:
	ld (fail_info),a
	ld a,#0x42
	ret
cl_class:
	ld a,(rx_frame + 0)
	ld (fail_info),a
	ld a,#0x43
	ret

; ---------------------------------------------------------------------------
; Read four other blocks, which with three unpinned slots pushes everything
; else out of the cache.  Contents are irrelevant; the eviction is the point.
; A = 0 on success.
; ---------------------------------------------------------------------------
evict:
	ld a,#8
ev_loop:
	call set_rec
	call rd_rec
	or a
	ret nz
	ld a,(cur_off)
	add a,#4			; 8, 12, 16, 20 -> blocks 2, 3, 4, 5
	cp #24
	jr c,ev_loop
	xor a
	ret

; ---------------------------------------------------------------------------
; A = offset within this pass.  Records the offset for loop control and forms
; the absolute record number from the pass base.
;
; Phases address records relatively so a soak can move the whole pattern across
; the card.  Base 0 is the only base that exercises the pinned slot and the
; write-through block, so a loop must keep coming back to it rather than just
; rotating away.
; ---------------------------------------------------------------------------
set_rec:
	ld (cur_off),a
	ld l,a
	ld h,#0
	ld de,(base_rec)
	add hl,de
	ld (cur_rec),hl
	ret

; ---------------------------------------------------------------------------
; Pattern
;
; byte[i] = seed + i.  The seed is derived from the record number so a block
; read back at the wrong offset produces a mismatch at byte 0 rather than
; looking plausible — which a constant fill would not.
; ---------------------------------------------------------------------------
seed_normal:
	ld a,(cur_rec)
	ld (cur_seed),a
	ret

; Phase D needs a pattern distinguishable from the original for the SAME record.
seed_alt:
	ld a,(cur_rec)
	xor #0xff
	ld (cur_seed),a
	ret

fill_buf:
	ld hl,#wr_buf
	ld a,(cur_seed)
	ld b,#REC_SIZE
fb_loop:
	ld (hl),a
	inc hl
	inc a
	djnz fb_loop
	ret

; ---------------------------------------------------------------------------
; Read one record into rd_buf.  A = 0 on success.
; ---------------------------------------------------------------------------
rd_rec:
	call zero_frames
	ld a,#CMD_SD_READ_REC
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a		; payload length = 4 (32-bit record)
	call put_record

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,rr_xport
	ld a,(rx_frame + 0)
	cp #RSP_SD_READ_REC
	jp nz,rr_class
	ld a,(rx_frame + 2)
	or a
	jp nz,rr_sd
	call check_rec_echo
	jp nz,rr_echo

	; Length comes from READY, not assumed: a short transfer is the PIC's to
	; declare, and IOCBULK verifies the CRC trailer itself.
	ld hl,#rd_buf
	ld a,(rx_frame + 6)
	ld e,a
	ld a,(rx_frame + 7)
	ld d,a
	call IOCBULK
	or a
	jp nz,rr_bulk
	xor a
	ret

rr_xport:
	ld (fail_info),a
	ld a,#1
	ret
rr_class:
	ld a,(rx_frame + 0)
	ld (fail_info),a
	ld a,#2
	ret
rr_sd:
	ld (fail_info),a
	ld a,#3
	ret
rr_echo:
	ld a,#4
	ret
rr_bulk:
	ld (fail_info),a
	ld a,#5
	ret

; ---------------------------------------------------------------------------
; Write wr_buf to the current record.  A = 0 on success.
;
; DONE is mandatory here and there is no fast path.  For a record write it
; carries two things nothing else does: the bulk CRC result, and — when the
; record lands in the write-through block — the card's own status.
; ---------------------------------------------------------------------------
wr_rec:
	call zero_frames
	ld a,#CMD_SD_WRITE_REC
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x04
	ld (tx_frame + 3),a
	call put_record

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,wr_xport
	ld a,(rx_frame + 0)
	cp #RSP_SD_WRITE_REC
	jp nz,wr_class
	ld a,(rx_frame + 2)
	or a
	jp nz,wr_sd
	call check_rec_echo
	jp nz,wr_echo

	ld a,(rx_frame + 4)
	ld (ready_id),a

	; IOCBULKW uses reason 40h for an RR1 Tx underrun.  A zero left here means
	; its other HW_ERROR exit: /CTSA did not release after the transfer.
	xor a
	ld (IOC_DIAG_BULK_REASON),a
	ld hl,#wr_buf
	ld de,#REC_SIZE
	call IOCBULKW
	or a
	jp nz,wr_bulk

	; ---- DONE ----
	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,wr_xport
	ld a,(rx_frame + 0)
	cp #RSP_XFER_STATUS
	jp nz,wr_dclass
	ld a,(rx_frame + 4)
	ld hl,#ready_id
	cp (hl)
	jp nz,wr_id
	ld a,(rx_frame + 5)
	or a
	jp nz,wr_done
	xor a
	ret

wr_xport:
	ld (fail_info),a
	ld a,#0x11
	ret
wr_class:
	ld a,(rx_frame + 0)
	ld (fail_info),a
	ld a,#0x12			; READY reply had the wrong class
	ret
wr_dclass:
	ld a,(rx_frame + 0)
	ld (fail_info),a
	ld a,#0x18			; DONE reply had the wrong class
	ret
wr_sd:
	ld (fail_info),a
	ld a,#0x13
	ret
wr_echo:
	ld a,#0x14
	ret
wr_bulk:
	ld (fail_info),a
	ld a,#0x15
	ret
wr_id:
	ld a,#0x16
	ret
wr_done:
	ld (fail_info),a
	; Keep the MCU's own view of the transfer.  DONE carries the de-shifted
	; head of the receive buffer and the RAW capture window, and for a sync
	; failure the raw bytes are the whole story: all FF means the host never
		; put a bit on the wire, data with no A5 5A means the marker was mangled
		; or landed outside the 128-bit search, and A5 5A present means the search
	; found it late.  Without this the status byte alone cannot tell those
	; apart.
	ld hl,#(rx_frame + 6)
	ld de,#diag_peek
	ld bc,#16
	ldir
	ld a,#1
	ld (diag_valid),a
	ld a,#0x17
	ret

; ---------------------------------------------------------------------------
; Flush every dirty slot.  No bulk phase: the reply status IS the answer, which
; makes this the one storage command whose result needs no DONE query.
; ---------------------------------------------------------------------------
do_flush:
	call zero_frames
	ld a,#CMD_SD_FLUSH
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,fl_xport
	ld a,(rx_frame + 0)
	cp #RSP_SD_FLUSH
	jp nz,fl_class
	ld a,(rx_frame + 2)
	or a
	jp nz,fl_sd
	xor a
	ret
fl_xport:
	ld (fail_info),a
	ld a,#0x21
	ret
fl_class:
	ld a,(rx_frame + 0)
	ld (fail_info),a
	ld a,#0x22
	ret
fl_sd:
	ld (fail_info),a
	ld a,#0x23
	ret

; ---------------------------------------------------------------------------
; Read the current record and compare against the pattern for cur_seed.
; A = 0 on match, else the read error or 0x30 for a data mismatch.
; ---------------------------------------------------------------------------
verify_rec:
	call rd_rec
	or a
	ret nz
	ld hl,#rd_buf
	ld a,(cur_seed)
	ld c,a
	ld b,#REC_SIZE
	ld e,#0			; offset
vr_loop:
	ld a,(hl)
	cp c
	jr nz,vr_bad
	inc hl
	inc c
	inc e
	djnz vr_loop
	xor a
	ret
vr_bad:
	ld (bad_got),a
	ld a,c
	ld (bad_exp),a
	ld a,e
	ld (bad_off),a
	ld a,#0x30
	ret

; 32-bit record number into the request payload; only the low 16 bits are ever
; non-zero at 8 MiB, but the field is 32 so the protocol does not need widening.
put_record:
	ld hl,(cur_rec)
	ld a,l
	ld (tx_frame + 4),a
	ld a,h
	ld (tx_frame + 5),a
	xor a
	ld (tx_frame + 6),a
	ld (tx_frame + 7),a
	ret

; Did the PIC decode the record we asked for?  Z = yes.
check_rec_echo:
	ld a,(cur_rec)
	ld hl,#(rx_frame + 8)
	cp (hl)
	ret nz
	inc hl
	ld a,(cur_rec + 1)
	cp (hl)
	ret nz
	inc hl
	xor a
	cp (hl)
	ret nz
	inc hl
	cp (hl)
	ret

zero_frames:
	ld hl,#tx_frame
	ld b,#32
	xor a
zf_tx:
	ld (hl),a
	inc hl
	djnz zf_tx
	ld hl,#rx_frame
	ld b,#32
	xor a
zf_rx:
	ld (hl),a
	inc hl
	djnz zf_rx
	ret

ok:
	ld de,#msg_ok
	; fall through

; Print the string at DE unless we are looping.  A soak wants a progress line
; every so often, not five lines a pass.
say:
	ld a,(loop_mode)
	or a
	ret nz
	ld c,#BDOS_PRINT
	jp BDOS

; A = failure code on entry.
fail:
	ld (fail_code),a
	ld de,#msg_fail
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(fail_code)
	call print_hex_byte
	ld de,#msg_rec
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(cur_rec + 1)
	call print_hex_byte
	ld a,(cur_rec)
	call print_hex_byte
	ld de,#msg_info
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(fail_info)
	call print_hex_byte
	call report_frame
	; Each extra section is a GUARDED CALL, not a forward branch over a block.
	;
	; It was written the other way first: `cp #0x30 / jr nz,fail_end` with the
	; mismatch detail and then the MCU dump both sitting in the skipped span.
	; The dump could therefore only print when the failure WAS a data mismatch,
	; which is precisely when there is no DONE reply to dump -- so it never
	; printed at all, and the one run that needed it produced nothing.
	;
	; Same shape as the unreachable CRC trailer in IOCBULK, and the label
	; scanner cannot see this one: every label here is referenced.  A call that
	; returns cannot be jumped over, which is why the structure changed rather
	; than the branch target.
	ld a,(fail_code)
	cp #0x30
	call z,report_mismatch
	call report_rdbuf
	ld a,(fail_code)
	cp #0x05
	call z,report_bulk_transport_diag
	ld a,(fail_code)
	cp #0x15
	call z,report_bulk_transport_diag
	ld a,(diag_valid)
	or a
	call nz,report_diag
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; First eight bytes of the READ buffer, whatever the failure was.
;
; A read that fails its bulk CRC leaves the received data here and nothing else
; reports it -- diag_valid is only armed on the write DONE path.  The point is
; the SHAPE: the expected content is a ramp, so a bit-shifted stream shows up as
; a ramp with a doubled step (00 02 04 06 for a one-bit slip), and the step says
; how far the character boundary has moved.  That is how the command lane's
; two-bit-per-transaction drift was identified.
report_rdbuf:
	ld de,#msg_rdbuf
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#rd_buf
	ld b,#8
	jp dump_bytes

; BIOS-side reason for a Bulk error.  On IOCBULK receive failures, reasons 1..7
; identify the rejected packet stage.  On IOCBULKW failure 15/info 03, reason
; 40h is SIO Tx underrun; 00h means /CTSA stayed asserted after completion.
report_bulk_transport_diag:
	ld de,#msg_bulk_diag_reason
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_BULK_REASON)
	call print_hex_byte
	ld de,#msg_bulk_diag_rr
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_RR0)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_DIAG_RR1)
	call print_hex_byte
	ld de,#msg_bulk_diag_sync
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_BULK_SYNCED)
	call print_hex_byte
	ld de,#msg_bulk_diag_xfer
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(IOC_DIAG_BULK_TYPE)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_DIAG_BULK_SEQ)
	call print_hex_byte
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	ld a,(IOC_DIAG_BULK_STATUS)
	call print_hex_byte
	ret

; First eight bytes of the reply frame exactly as received.
;
; This exists for IOC_XPORT_BAD_SEQ (info 06), which is the one transport error
; that reports a frame the transport BELIEVED: its CRC passed, so the bytes are
; intact and the controller really sent them -- just for some earlier request.
; Nothing else in this report can tell "the host is one reply behind" apart from
; "noise that happened to checksum", and the two have opposite causes.
;
; Byte 0 is the class, naming which command the stale reply answered, and byte 1
; is that transaction's sequence number.  The gap between it and the sequence
; this request expected is how many exchanges the host has fallen behind, which
; is the number that says whether one extra frame appeared or one went missing.
;
; Printed unconditionally rather than under a `cp` guard: the frame is cheap and
; every failure has one, and a conditional dump is precisely how the earlier
; diagnostic here managed never to print on the run that needed it.
report_frame:
	ld de,#msg_rx
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#rx_frame
	ld b,#8
rf_loop:
	push bc
	push hl
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	inc hl
	pop bc
	djnz rf_loop
	ret

; Byte offset, expected and got, for a data mismatch.
report_mismatch:
	ld de,#msg_at
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(bad_off)
	call print_hex_byte
	ld de,#msg_exp
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(bad_exp)
	call print_hex_byte
	ld de,#msg_got
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(bad_got)
	jp print_hex_byte

; What the MCU says it received: the de-shifted buffer head, then the raw
; capture window before de-shifting.
report_diag:
	ld de,#msg_peek
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#diag_peek
	ld b,#8
	call dump_bytes
	; Walk the raw window in 8-byte slices rather than printing the one slice
	; the DONE reply happened to carry.  Eight bytes cannot distinguish "the
	; host never transmitted" from "the preamble arrived past the search" --
	; both open with idle and fill.  Six slices covers the start of the 128-bit
	; search and is followed by a separate tail range below.
	xor a
	ld (raw_off),a
rd_slice:
	ld de,#msg_raw
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(raw_off)
	call print_hex_byte
	ld e,#0x3a			; ':'
	ld c,#BDOS_CONOUT
	call BDOS
	call fetch_raw
	or a
	ret nz				; transport gave up; stop walking
	ld hl,#diag_raw
	ld b,#8
	call dump_bytes
	ld a,(raw_off)
	add a,#8
	ld (raw_off),a
	cp #0x30
	jr c,rd_slice

	; Second range: the payload TAIL and the CRC trailer.
	;
	; The first range answers "did the preamble arrive, and where"; it cannot
	; answer "is the payload intact", because a transfer whose head de-shifts
	; correctly can still fail its CRC on a byte 100 further along.  With the
	; preamble at raw byte 2 the 128-byte payload ends near 0x84 and the two
	; CRC bytes follow it, so that is where a tail fault shows.
	cp #0x78
	jr nc,rd_tail
	ld a,#0x78
	ld (raw_off),a
	jr rd_slice
rd_tail:
	cp #0xa0
	jr c,rd_slice
	ret

; Ask XFER_STATUS for the 8 raw bytes at raw_off.  A = 0 on success.
;
; Re-querying DONE is safe: it reports stored state and moves nothing on the
; bulk lane, so the window can be read as many times as we like.
fetch_raw:
	call zero_frames
	ld a,#CMD_XFER_STATUS
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a
	ld a,#0x01
	ld (tx_frame + 3),a
	ld a,(raw_off)
	ld (tx_frame + 4),a		; IOC_OFF_STATUS_RAW_OFF
	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	ret nz
	ld hl,#(rx_frame + 14)		; IOC_OFF_DONE_RAW
	ld de,#diag_raw
	ld bc,#8
	ldir
	xor a
	ret

; B bytes at HL, space separated.
dump_bytes:
	push bc
	push hl
	ld e,#0x20
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	ld a,(hl)
	push hl
	call print_hex_byte
	pop hl
	inc hl
	pop bc
	djnz dump_bytes
	ret

print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	call print_hex_nibble
	pop af
print_hex_nibble:
	and #0x0f
	add a,#0x30
	cp #0x3a
	jr c,phx_out
	add a,#0x07
phx_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

msg_banner:	.ascii "SDREC: record cache test"
		.db 13,10,'$'
msg_pa:		.ascii "A write+read 0-7 ... $"
msg_pb:		.ascii "B evict ........... $"
msg_pc:		.ascii "C survived evict .. $"
msg_pd:		.ascii "D partial write ... $"
msg_ok:		.ascii "ok"
		.db 13,10,'$'
msg_passno:	.ascii "pass $"
msg_stopped:	.ascii "stopped by key"
		.db 13,10,'$'
msg_pass:	.ascii "ALL PASS"
		.db 13,10,'$'
msg_fail:	.ascii "FAIL code $"
msg_rec:	.ascii " rec $"
msg_info:	.ascii " info $"
msg_rx:		.ascii "  rx$"
msg_at:		.ascii " at $"
msg_exp:	.ascii " exp $"
msg_got:	.ascii " got $"
msg_bios:	.ascii "bios xport level $"
msg_stale_bios:	.ascii " -- STALE ROM, expected $"
msg_reflash_rom:	.ascii ", RE-FLASH ROM"
		.db 13,10,'$'
msg_fw:		.ascii ", controller fw level $"
msg_stale:	.ascii " -- STALE FW, expected $"
msg_reflash_fw:	.ascii ", RE-FLASH CONTROLLER"
		.db 13,10,'$'
msg_peek:	.db 13,10
		.ascii "  buf:$"
msg_raw:	.db 13,10
		.ascii "  raw $"
msg_rdbuf:	.db 13,10
		.ascii "  rd_buf:$"
msg_bulk_diag_reason:	.db 13,10
		.ascii "  bulk reason=$"
msg_bulk_diag_rr:	.ascii " rr=$"
msg_bulk_diag_sync:	.ascii " bsync=$"
msg_bulk_diag_xfer:	.ascii " xfer(type/seq/status)=$"
msg_crlf:	.db 13,10,'$'

base_rec:	.ds 2
cur_rec:	.ds 2
cur_off:	.ds 1
cur_seed:	.ds 1
ready_id:	.ds 1
fail_code:	.ds 1
fail_info:	.ds 1
bad_off:	.ds 1
bad_exp:	.ds 1
bad_got:	.ds 1
diag_valid:	.ds 1
diag_peek:	.ds 8
diag_raw:	.ds 8
raw_off:	.ds 1
loop_mode:	.ds 1
pass_count:	.ds 2
tx_frame:	.ds 32
rx_frame:	.ds 32
wr_buf:		.ds 128
rd_buf:		.ds 128
