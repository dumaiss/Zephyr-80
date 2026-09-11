; Zephyr-80 SD storage transaction layer, on ROM page 4.
;
; Phase 3 extension.  The record arithmetic, the request builder, the command
; exchange, the read, write and flush transactions, and the three card probes.
;
; A ROM SERVICE MUST NOT TOUCH THE BANK LATCH.  Writing it drops the machine out
; of shadow mode and unmaps the ROM the service is executing from, mid
; instruction stream.  That is why sd_copy_to_dma, sd_copy_from_dma and
; sd_select_bank are not here: they switch to the caller's DMA bank to stage a
; record, which is exactly the forbidden operation.  They also read and write
; the caller's memory, which shadow mode would replace with ROM on the read
; side, so they would have had to stay resident for two independent reasons.
;
; Staging therefore happens OUTSIDE the gate, in the thunks that replaced these
; routines in the dispatcher:
;
;   read   gate -> this fills RES_MOVE_BUFFER -> resident sd_copy_to_dma
;   write  resident sd_copy_from_dma -> gate -> this sends from RES_MOVE_BUFFER
;
; RES_IOCALL, RES_IOCBULK and RES_IOCBULKW are called from here at their resident
; addresses.  That is safe: in this path they touch only RES_MOVE_BUFFER and the SIO
; ports, both of which are reachable with ROM mapped low.

sd_compute_record:
	ld hl,(RES_sd_storage_track)
	ld a,h
	cp #0x40			; 16384 tracks
	jr nc,sd_record_bad
	ld de,(RES_sd_storage_sector)
	ld a,d
	or a
	jr nz,sd_record_bad
	ld a,e
	cp #4				; 4 records per track
	jr nc,sd_record_bad
	add hl,hl
	add hl,hl
	ld d,#0
	add hl,de
	ld (RES_sd_storage_record),hl
	xor a
	ret
sd_record_bad:
	ld a,#RES_BIOS_ERR
	ret

; ---------------------------------------------------------------------------
; Frame helpers
; ---------------------------------------------------------------------------

; Zero both frames.
sd_zero_frames:
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld b,#64			; tx and rx are adjacent
	xor a
sd_zf_loop:
	ld (hl),a
	inc hl
	djnz sd_zf_loop
	ret

; Build a record-addressed request.  In: A = command class.
sd_build_request:
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld (hl),a			; class
	inc hl
	ld (hl),#0x01			; seq placeholder; RES_IOCALL stamps the real one
	inc hl
	ld (hl),#0x00			; status
	inc hl
	ld (hl),#0x05			; payload: 32-bit record, then the unit
	inc hl
	ld de,(RES_sd_storage_record)
	ld (hl),e
	inc hl
	ld (hl),d
	inc hl
	ld (hl),#0x00
	inc hl
	ld (hl),#0x00
	inc hl
	; The unit is sent EXPLICITLY, including B:'s zero.
	;
	; The controller reads this byte only when LEN is 5 or more and defaults
	; to unit 0 otherwise, so a length of 4 would still work -- but it would
	; mean B: relied on a compatibility fallback to address the right volume,
	; and a request whose meaning depends on what it omits is one edit away
	; from addressing the wrong disk.
	ld a,(RES_sd_storage_unit)
	ld (hl),a
	ret

; Send the staged request and check the reply.
; In:  A = expected response class.
; Out: A = BIOS_OK, or RES_BIOS_ERR / RES_BIOS_ERR_BAD_REPLY.
sd_exchange:
	ld (RES_sd_storage_expect),a
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld de,#(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	call RES_IOCALL
	or a
	jr nz,sd_exchange_xport
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	ld hl,#RES_sd_storage_expect
	cp (hl)
	jr nz,sd_exchange_reply
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + 2)
	or a
	jr nz,sd_exchange_status
	; The MCU echoes the record it decoded.  The frame CRC proves the frame
	; arrived intact; this proves both ends agree on what it MEANT, which a
	; decode bug on either side would survive.
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + 8)
	ld a,(RES_sd_storage_record)
	cp (hl)
	jr nz,sd_exchange_echo
	inc hl
	ld a,(RES_sd_storage_record + 1)
	cp (hl)
	jr nz,sd_exchange_echo
	xor a
	ret
sd_exchange_xport:
	ld a,#RES_BIOS_ERR_TIMEOUT
	ret
sd_exchange_reply:
	ld a,#RES_BIOS_ERR_BAD_REPLY
	ret
sd_exchange_status:
	ld a,#RES_BIOS_ERR_IO
	ret
sd_exchange_echo:
	ld a,#RES_BIOS_ERR_BAD_REPLY
	ret

sd_storage_read:
	call sd_compute_record
	or a
	ret nz

	call sd_zero_frames
	ld a,#RES_SD_CMD_READ_REC
	call sd_build_request
	ld a,#RES_SD_RSP_READ_REC
	call sd_exchange
	or a
	ret nz

	; Length comes from READY rather than being assumed: a short transfer is
	; the MCU's to declare, and RES_IOCBULK verifies the CRC trailer itself.
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_DATA_OFF)
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + 6)
	ld e,a
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + 7)
	ld d,a
	call RES_IOCBULK
	or a
	jr nz,sd_read_bulk_failed

	; sd_copy_to_dma is NOT called here: it selects the caller's DMA bank,
	; which would unmap this page.  sd_read_thunk does it after the gate
	; returns, with the record already staged in RES_MOVE_BUFFER.
	xor a
	ret
sd_read_bulk_failed:
	ld a,#RES_BIOS_ERR_IO
	ret

; ---------------------------------------------------------------------------
; WRITE one record
;
; C holds CP/M's write type on entry and is deliberately ignored.  The deferral
; policy lives on the MCU and is an address rule there -- the block holding the
; directory head is write-through, everything else rides the flush timer -- so
; the controller never has to know what a directory is.
; ---------------------------------------------------------------------------
sd_storage_write:
	call sd_compute_record
	or a
	ret nz

	; sd_copy_from_dma already ran, in sd_write_thunk, before the gate: this
	; service cannot read the caller's buffer and cannot switch banks.  The
	; record is waiting in RES_MOVE_BUFFER.
	call sd_zero_frames
	ld a,#RES_SD_CMD_WRITE_REC
	call sd_build_request
	ld a,#RES_SD_RSP_WRITE_REC
	call sd_exchange
	or a
	ret nz

	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_DATA_OFF)
	ld de,#RES_SD_STORAGE_RECORD_BYTES
	call RES_IOCBULKW
	or a
	jr nz,sd_write_bulk_failed

	; DONE is mandatory and has no fast path.
	call sd_zero_frames
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld (hl),#RES_SD_CMD_XFER_STATUS
	inc hl
	ld (hl),#0x01
	ld a,#RES_SD_RSP_XFER_STATUS
	ld (RES_sd_storage_expect),a
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld de,#(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	call RES_IOCALL
	or a
	jr nz,sd_write_xport_failed
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	cp #RES_SD_RSP_XFER_STATUS
	jr nz,sd_write_reply_failed
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + 5)
	or a
	jr nz,sd_write_done_failed
	xor a
	ret
sd_write_bulk_failed:
	ld a,#RES_BIOS_ERR_IO
	ret
sd_write_xport_failed:
	ld a,#RES_BIOS_ERR_TIMEOUT
	ret
sd_write_reply_failed:
	ld a,#RES_BIOS_ERR_BAD_REPLY
	ret
sd_write_done_failed:
	ld a,#RES_BIOS_ERR_IO
	ret

; ---------------------------------------------------------------------------
; Commit every dirty cache slot.  No bulk phase: the reply status IS the answer,
; which makes this the one storage command whose result needs no DONE query.
; ---------------------------------------------------------------------------
sd_storage_flush:
	call sd_zero_frames
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld (hl),#RES_SD_CMD_FLUSH
	inc hl
	ld (hl),#0x01
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld de,#(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	call RES_IOCALL
	or a
	jr nz,sd_flush_failed
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	cp #RES_SD_RSP_FLUSH
	jr nz,sd_flush_failed
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + 2)
	or a
	jr nz,sd_flush_failed
	xor a
	ret
sd_flush_failed:
	ld a,#RES_BIOS_ERR_IO
	ret

sd_storage_probe:
	call sd_storage_probe_card
	jr nz,sd_probe_failed
	ld de,#RES_SD_STORAGE_DPH
	jr sd_probe_store_result

sd_probe_failed:
	ld de,#0x0000			; no DPH: drive unavailable
; In: DE = DPH to return, or zero for an unavailable drive.
; Out: saved SELDSK HL replaced with DE.  Clobbers HL; foreground only.
sd_probe_store_result:
	ld hl,(RES_storage_caller_sp)
	ld (hl),e
	inc hl
	ld (hl),d
	ret

; ---------------------------------------------------------------------------
; C: selection probe, in its own region.
; ---------------------------------------------------------------------------

sd_storage_probe_card:
	call sd_zero_frames
	ld a,#RES_SD_CMD_PROBE
	ld (RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF),a
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld de,#(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	call RES_IOCALL
	or a				; transport status
	ret nz
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + RES_IOC_OFF_STATUS)
	or a
	ret

; ---------------------------------------------------------------------------
; C: selection probe.
;
; Two transactions, and the order matters.
;
; The card probe runs first because it is what INITIALISES the card.  Only once
; the card is up does the controller's idle loop resolve /CPM/CPM_1.DRV and
; CPM_2.DRV into volume units -- so asking about unit 1 before that would
; truthfully answer "nothing mounted" on a perfectly good card.  The two IOCALLs
; are separate transactions, so the controller's main loop runs between them and
; the mount has happened by the time the second one is answered.
;
; CMD_VOL_INFO is then a pure query: no card I/O, no state change.  A mode of
; zero means unit 1 has no volume -- an unformatted card, or one with no
; CPM_2.DRV on it -- and C: reports itself unavailable, which is a clean select
; error rather than reads that fail one at a time later.
; ---------------------------------------------------------------------------
sd_storage_probe2:
	call sd_storage_probe_card
	jp nz,sd_probe_failed
	call sd_zero_frames
	ld a,#RES_SD_CMD_VOL_INFO
	ld (RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF),a
	ld a,#0x01
	ld (RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF + RES_IOC_OFF_LEN),a
	ld a,(RES_sd_storage_unit)
	ld (RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF + RES_IOC_OFF_PAYLOAD),a
	ld hl,#(RES_MOVE_BUFFER + RES_SD_STORAGE_TX_OFF)
	ld de,#(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF)
	call RES_IOCALL
	or a
	jp nz,sd_probe_failed
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + RES_IOC_OFF_STATUS)
	or a
	jp nz,sd_probe_failed
	ld a,(RES_MOVE_BUFFER + RES_SD_STORAGE_RX_OFF + RES_SD_VOL_INFO_MODE_OFF)
	cp #RES_SD_VOL_MODE_NONE
	jp z,sd_probe_failed		; unit exists, but nothing is mounted on it
	ld de,#RES_SD_STORAGE_DPH2
	jp sd_probe_store_result

; The region ends at CBIOS_SD_PROBE2_CODE_END (F96Fh); RES_SD_STORAGE_DPH2 is
; org'd immediately after it, so overrunning this block collides with C:'s own
; DPH and tools/check_overlap.py reports it by name.
