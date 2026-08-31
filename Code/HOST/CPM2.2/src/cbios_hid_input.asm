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
; POLLING, AND WHY THERE IS NO TIMER
;
; CONST is the poll point, and CP/M calls it hard: BDOS OUTCHAR calls CONST once
; per character printed, before every CONOUT.  A full IOCALL is roughly 0.6 ms,
; so polling the controller on every CONST would add that to every character of
; console output -- about 48 ms per 80-column line.  That is the whole reason
; this is rate limited.
;
; The limiter counts CONST calls rather than time, and needs no timer, because
; the controller already has both the clock and the buffer.  Keystrokes are
; never lost by asking late: they accumulate in the IOC's queue and arrive
; whenever the host next asks.  That makes wall-clock latency irrelevant in the
; only case a timer would help -- a program computing without calling CONST --
; because there is nowhere better to put the bytes than the queue they are
; already in.
;
; The interval is adaptive rather than fixed, which matches the two regimes CP/M
; actually produces:
;
;   - typing arrives in bursts, so a poll that returns data drops the interval
;     to 1 and the rest of the burst is fetched at full rate;
;   - an idle CONST spin backs off to HID_BACKOFF_MAX, and since that spin runs
;     thousands of times a second the first keystroke still lands in well under
;     a millisecond;
;   - console output calls CONST once per character, so the same backoff costs
;     roughly 10 us per character amortised instead of 600.

	.globl hid_input_init,hid_input_status,hid_input_get

	.area CODE (ABS)
	.org CBIOS_HID_INPUT_CODE_BASE

HID_INPUT_CODE_START:

HID_Q_SIZE		= 16
HID_Q_MASK		= (HID_Q_SIZE - 1)
HID_BACKOFF_MIN		= 1
HID_BACKOFF_MAX		= 64

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
	ld a,#HID_BACKOFF_MIN
	ld (hid_backoff),a
	ld (hid_countdown),a

	ld a,#CMD_HID_INPUT
	ld (hid_tx_frame + 0),a
	ld a,#1
	ld (hid_tx_frame + 3),a		; one payload byte: the maximum wanted
	ret

; ---------------------------------------------------------------------------
; hid_input_status — A = FFh if a USB byte is available, 00h otherwise
; ---------------------------------------------------------------------------
; Polls the controller at most once every hid_backoff calls.  Safe to call from
; a hot CONST loop; that is the design point.
; Clobbers: AF, BC, DE, HL.
hid_input_status:
	ld a,(hid_q_count)
	or a
	jr nz,hid_status_yes

	ld a,(hid_countdown)
	dec a
	ld (hid_countdown),a
	or a
	jr z,hid_status_poll
	xor a
	ret

hid_status_poll:
	call hid_input_poll
	ld a,(hid_q_count)
	or a
	jr nz,hid_status_got

	; Nothing waiting — double the interval, capped.
	ld a,(hid_backoff)
	add a,a
	jr c,hid_status_cap
	cp #(HID_BACKOFF_MAX + 1)
	jr c,hid_status_set
hid_status_cap:
	ld a,#HID_BACKOFF_MAX
hid_status_set:
	ld (hid_backoff),a
	ld (hid_countdown),a
	xor a
	ret

hid_status_got:
	; Data arrived — typing comes in bursts, so fetch again next call.
	ld a,#HID_BACKOFF_MIN
	ld (hid_backoff),a
	ld (hid_countdown),a
hid_status_yes:
	ld a,#0xff
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
hid_backoff:
	.db 0
hid_countdown:
	.db 0

HID_INPUT_STATE_END:
