; Zephyr-80 BIOS USB keyboard console input.
;
; The IO Controller enumerates a USB keyboard, translates boot reports into
; terminal bytes, and holds them in a 128-byte queue.  This module fetches those
; bytes with CMD_HID_INPUT and presents them to the CP/M console as a second
; input source alongside the proxy keyboard's textq.
;
; It is deliberately additive.  textq is filled from the SIO0/B receive
; interrupt; this queue is touched only at task level, so the two never race.
; Dropping proxy keyboard support later is then a matter of the proxy simply not
; sending -- textq stays empty and nothing here changes.
;
; THE DOORBELL, AND WHY THERE IS NO TIMER
;
; CONST is the poll point, and CP/M calls it hard: BDOS OUTCHAR calls CONST once
; per character printed, before every CONOUT.  A full IOCALL is roughly 0.6 ms,
; so asking the controller on every CONST would add that to every character of
; console output -- about 48 ms per 80-column line.
;
; So CONST does not ask the controller; it looks at a wire.  The IOC asserts
; /CTSB on SIO1/B while its keyboard queue holds anything and releases it when
; the queue empties, and that level appears as RR0 bit 5 on the command lane's
; control port.  Reading it is one OUT and one IN -- call it 15 us -- and the
; IOCALL happens only when there is something to fetch.  An idle machine pays
; nothing, and a keystroke is picked up on the very next CONST.
;
; No timer is needed because the controller already has both the clock and the
; buffer: keystrokes are never lost by asking late, they accumulate in the IOC's
; queue.  That is also why the doorbell is a LEVEL and not an edge -- this code
; samples the current state and never counts transitions, so nothing is lost if
; the SIO's status latch swallows a change.
;
; WHY /CTSB CANNOT DISTURB EXTERNAL SYNC
;
; The character boundary on SIO1/B is established by the MCU's falling /SYNCB
; edge alone.  Only three things end character assembly -- chip reset, receiver
; disabled, and Enter Hunt Phase -- and a CTS transition is none of them.  The
; single path by which CTS could gate anything is Auto Enables, WR3 bit 5, which
; is clear on this channel and must stay clear.  SIO1/A is deliberately the
; opposite, where /DCDA does gate the receiver.  So the doorbell needs no
; LINK_SYNC and leaves ioc_rx_synced alone.
;
; THE RESET EXTERNAL/STATUS BEFORE THE READ IS NOT OPTIONAL
;
; The SIO latches ALL of RR0's status bits together on any status change, so a
; stale latch could report a level the pin no longer carries.  Every reader of
; RR0 on this port unlatches first; sio_command_wait_ready does exactly the same
; before sampling /DCDB.
;
; FOREGROUND ONLY
;
; This must never be called from interrupt context.  ioc_command_recv_frame
; scans for the reply marker with interrupts ENABLED, polling RR0 on this same
; port as a WR0 pointer write followed by an IN; an ISR landing between those two
; instructions would corrupt the read.  CONST is task level, so this is safe, and
; it is the reason the doorbell is not wired to the SIO's External/Status
; interrupt.
;
; THE STUCK-DOORBELL GUARD
;
; A controller that died with the line asserted would otherwise put a full IOCALL
; timeout on every CONST, which reads as a hung machine.  So a fetch that returns
; nothing despite the doorbell makes the next HID_STUCK_PENALTY calls ignore it,
; and any fetch that produces data -- or a released doorbell, the normal idle
; case -- clears the penalty immediately.  In healthy operation the penalty is
; always zero and costs one compare.

	.globl hid_input_init,hid_input_status,hid_input_get

	.area CODE (ABS)
	.org CBIOS_HID_INPUT_CODE_BASE

HID_INPUT_CODE_START:

HID_Q_SIZE		= 16
HID_Q_MASK		= (HID_Q_SIZE - 1)
; CONST calls to ignore the doorbell after a fetch that returned nothing.
HID_STUCK_PENALTY	= 64

; RR0 bit 5 is CTS: SET means the pin is asserted (low), i.e. the controller
; has queued input.  Same convention as the /CTSA waits in cbios_ioc_command.
HID_DOORBELL_MASK	= 0x20

CMD_HID_INPUT		= 0x0e
RSP_HID_INPUT		= 0x8e

; ---------------------------------------------------------------------------
; hid_input_init — clear queue state and stage the constant request frame
; ---------------------------------------------------------------------------
; Cold boot leaves this RAM undefined, so this must run before the first CONST.
; Called from vdrip_console_init.
; Clobbers: AF, B, HL.
hid_input_init:
	; Only bytes 0..4 of the request are ever transmitted: the wire packet
	; carries TYPE, SEQ and STATUS plus LEN payload bytes, and LEN is 1.  The
	; rest of the mailbox is never read, so it is not worth clearing.  IOCALL
	; stamps the sequence at +1 itself.
	xor a
	ld (hid_q_head),a
	ld (hid_q_tail),a
	ld (hid_q_count),a
	ld (hid_tx_frame + 2),a		; status
	ld (hid_penalty),a

	ld a,#CMD_HID_INPUT
	ld (hid_tx_frame + 0),a
	ld a,#1
	ld (hid_tx_frame + 3),a		; one payload byte: the maximum wanted
	ret

; ---------------------------------------------------------------------------
; hid_input_status — A = FFh if a USB byte is available, 00h otherwise
; ---------------------------------------------------------------------------
; Reads the /CTSB doorbell and fetches only when the controller says it has
; something.  Safe to call from a hot CONST loop; that is the design point.
; Clobbers: AF, BC, DE, HL.
hid_input_status:
	ld a,(hid_q_count)
	or a
	jr nz,hid_status_yes

	; Unlatch RR0's status bits, then sample the doorbell.
	ld a,#SIO_WR0_RESET_EXT_STATUS
	out (SIO_COMMAND_CTRL_PORT),a
	in a,(SIO_COMMAND_CTRL_PORT)
	and #HID_DOORBELL_MASK
	jr nz,hid_status_ring

	; Doorbell released: the controller has nothing.  This is the hot path --
	; every CONST during console output lands here -- and it also clears the
	; stuck-doorbell penalty, since a line that can still fall is not stuck.
	xor a
	ld (hid_penalty),a
	ret

hid_status_ring:
	ld a,(hid_penalty)
	or a
	jr z,hid_status_fetch
	dec a
	ld (hid_penalty),a
	xor a
	ret

hid_status_fetch:
	call hid_input_poll
	ld a,(hid_q_count)
	or a
	jr z,hid_status_stuck
	; Data arrived.  Typing comes in bursts and the doorbell stays asserted
	; until the controller's queue drains, so the rest is fetched at full rate.
	xor a
	ld (hid_penalty),a
hid_status_yes:
	ld a,#0xff
	ret

hid_status_stuck:
	; The doorbell said yes and the fetch produced nothing: a transport failure,
	; or a controller that died with the line asserted.  Ignore it for a while
	; so a dead IOC cannot put an IOCALL timeout on every CONST.
	ld a,#HID_STUCK_PENALTY
	ld (hid_penalty),a
	xor a
	ret

; ---------------------------------------------------------------------------
; hid_input_get — A = oldest queued USB byte
; ---------------------------------------------------------------------------
; Caller must have seen hid_input_status return FFh.  Returns 00h if empty.
; Clobbers: AF, DE, HL.
hid_input_get:
	ld a,(hid_q_count)
	or a
	ret z				; empty: A is already 00h
	dec a
	ld (hid_q_count),a

	ld hl,#hid_queue
	ld a,(hid_q_tail)
	ld e,a
	ld d,#0x00
	add hl,de

	inc a
	and #HID_Q_MASK
	ld (hid_q_tail),a

	ld a,(hl)
	ret

; ---------------------------------------------------------------------------
; hid_input_poll — one CMD_HID_INPUT transaction
; ---------------------------------------------------------------------------
; Requests only as many bytes as this queue can hold.  That matters: the
; controller DEQUEUES what it sends, so anything returned that will not fit here
; would be lost rather than left behind.  Asking for the free space exactly is
; what makes the local queue's smaller size harmless.
;
; Any transport or protocol failure leaves the queue untouched and is reported
; as "no input" -- a broken IOC link must not wedge the console, which still has
; the proxy keyboard.
; Clobbers: AF, BC, DE, HL.
hid_input_poll:
	ld a,(hid_q_count)
	ld b,a
	ld a,#HID_Q_SIZE
	sub b
	ret z				; queue full: ask for nothing
	ld (hid_tx_frame + 4),a

	ld hl,#hid_tx_frame
	ld de,#hid_rx_frame
	call IOCALL
	or a
	ret nz				; transport error

	ld a,(hid_rx_frame + 0)
	cp #RSP_HID_INPUT
	ret nz
	ld a,(hid_rx_frame + 2)
	or a
	ret nz				; controller reported failure

	; LEN counts the two metadata bytes (queued, dropped) plus the data.
	ld a,(hid_rx_frame + 3)
	sub #2
	ret c				; malformed: shorter than the metadata
	ret z				; nothing waiting
	ld b,a
	ld hl,#(hid_rx_frame + 6)

; Append inline rather than through a helper: this is the only producer, and
; the call plus the register save/restore around it cost more than the body.
; Space was reserved by sizing the request to the free slots, so no bound check
; is needed here -- see the note above about the controller dequeuing what it
; sends.
hid_poll_store:
	ld c,(hl)
	push hl
	ld hl,#hid_queue
	ld a,(hid_q_head)
	ld e,a
	ld d,#0x00
	add hl,de
	ld (hl),c

	ld a,e
	inc a
	and #HID_Q_MASK
	ld (hid_q_head),a

	ld a,(hid_q_count)
	inc a
	ld (hid_q_count),a

	pop hl
	inc hl
	djnz hid_poll_store
	ret

HID_INPUT_CODE_END:

; ---------------------------------------------------------------------------
; State
; ---------------------------------------------------------------------------
; In the fixed gap after the SD backend rather than MOVE_BUFFER, which the
; storage driver stages its own IOCALL mailboxes in.  CONST can fire from BDOS
; OUTCHAR at any moment, including with a storage request staged, so the two
; must not share.  This also keeps the state out of SD_STORAGE_ALV_BUFFER at
; FD00h-FDFFh; that entire page belongs to CP/M's SD allocation vector.
	.area CODE (ABS)
	.org CBIOS_HID_INPUT_STATE_BASE

HID_INPUT_STATE_START:

hid_tx_frame:
	; IOCALL transmits exactly bytes 0..4 for this one-byte request.
	.ds 5
hid_rx_frame:
	.ds 32
hid_queue:
	.ds HID_Q_SIZE
hid_q_head:
	.db 0
hid_q_tail:
	.db 0
hid_q_count:
	.db 0
hid_penalty:
	.db 0

HID_INPUT_STATE_END:
