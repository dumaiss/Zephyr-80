; HIDSTAT.COM -- Read the IOC's dormant MAX3421E host bring-up snapshot.
;
; This is deliberately observational.  CMD_HID_STATUS does not acknowledge
; /USB_INT, call TinyUSB's task runner, or begin enumeration.
;
; IOCALL contract:
;   In:  HL = 32-byte TX mailbox, DE = 32-byte RX mailbox
;   Out: A  = 00h on success, otherwise a transport error

	.module hidstat
	.area CODE (ABS)
	.org 0x0100

BDOS		= 0x0005
BDOS_CONOUT	= 0x02
BDOS_PRINT	= 0x09
IOCALL		= 0xDA3F

CMD_HID_STATUS	= 0x0d
RSP_HID_STATUS	= 0x8d
HID_REPLY_LEN	= 26
HID_USB_LEN	= 26
HID_PAGE_USB	= 1
HID_PAGE_XFER	= 2
HID_PAGE_HUB	= 3
HID_PAGE_ENUM	= 4
HID_PAGE_HIDCFG	= 5
HID_CFG_LEN	= 26
HID_ENUM_LEN	= 26
HID_XFER_LEN	= 26
HID_HUB_LEN	= 26

start:
	; Page selection from the CP/M command tail.  The full dump outgrew one
	; screen, so the default is the bring-up snapshot alone and each detail
	; page is requested explicitly.
	;   HIDSTAT      bring-up snapshot only (default)
	;   HIDSTAT 1    USB debug
	;   HIDSTAT 2    transfer decision
	;   HIDSTAT 3    hub lifecycle
	;   HIDSTAT 4    downstream enumeration entry
	;   HIDSTAT 5    HID class driver set-config chain
	;   HIDSTAT A    everything, as before
	call parse_arg

	ld de,#msg_banner
	ld c,#BDOS_PRINT
	call BDOS

	ld a,(sel_page)
	or a
	jr z,run_page0
	cp #0xff
	jr z,run_page0
	jp page1_entry			; a detail page was named; skip page 0
run_page0:

	; Clear both compatibility mailboxes.  A5h in RX makes a reply that never
	; arrived distinguishable from a valid zero-valued field.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx:
	ld (hl),a
	inc hl
	djnz zero_tx
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx:
	ld (hl),a
	inc hl
	djnz zero_rx

	ld a,#CMD_HID_STATUS
	ld (tx_frame + 0),a
	ld a,#0x01
	ld (tx_frame + 1),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_error

	ld a,(rx_frame + 0)
	cp #RSP_HID_STATUS
	jp nz,bad_reply
	ld a,(rx_frame + 2)
	or a
	jp nz,ioc_error
	ld a,(rx_frame + 3)
	cp #HID_REPLY_LEN
	jp nz,bad_length

	ld de,#msg_status
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 4)
	push af
	call print_hex_byte
	pop af
	call print_status_name

	ld de,#msg_revision
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 5)
	call print_hex_byte

	ld de,#msg_int_level
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 6)
	and #0x01
	add a,#0x30
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS

	ld a,(rx_frame + 6)
	and #0x01
	ld de,#msg_int_asserted
	jr z,print_int_meaning
	ld de,#msg_int_inactive
print_int_meaning:
	ld c,#BDOS_PRINT
	call BDOS

	; Revision bursts.  The match count is the real signal: the revision byte
	; is a majority verdict, and only "N of 64" says whether that majority
	; was 64 clean reads or a coin toss on a marginal bus.
	ld de,#msg_rev_125k
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 7)
	call print_hex_byte
	ld a,(rx_frame + 14)
	call print_match_count
	ld de,#msg_rev_1m
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 8)
	call print_hex_byte
	ld a,(rx_frame + 15)
	call print_match_count
	ld de,#msg_rev_4m
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 9)
	call print_hex_byte
	ld a,(rx_frame + 16)
	call print_match_count

	; GPOUT write/read-back link test.  This is the liveness evidence GPX
	; would have given us if U2.17 were connected: a walking pattern through
	; GPOUT3-0 and back.  Reported per rate because the failure it is looking
	; for -- propagation delay through U3, the CD74HC4050 in front of
	; SCK/MOSI/CS -- is the kind that passes slow and fails fast.
	ld de,#msg_gpout_125k
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 10)
	call print_gpout_result
	ld de,#msg_gpout_1m
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 11)
	call print_gpout_result
	ld de,#msg_gpout_4m
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 12)
	call print_gpout_result

	; Blind command-path test.  Needs no MISO: it commands the controller and
	; then watches the controller's own INT output pin.  RA0 is pulled up 10k
	; to 3V3 and nothing else can pull it low, so a low is unforgeable proof
	; that the part is powered and executing our writes.
	; ---- live USB state -------------------------------------------------
	ld de,#msg_usb_devs
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 17)
	call print_dec_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS

	ld de,#msg_kbd_addr
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 18)
	push af
	call print_hex_byte
	pop af
	or a
	ld de,#msg_kbd_none
	jr z,print_kbd_state
	ld de,#msg_kbd_mounted
print_kbd_state:
	ld c,#BDOS_PRINT
	call BDOS

	; Speed decides whether this device can work at all: there is an FE1.1S
	; hub in front of every port, and the MAX3421E driver has no PRE-packet
	; support, so a low-speed device behind it is unreachable.
	ld de,#msg_kbd_speed
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 29)
	push af
	call print_hex_byte
	pop af
	or a
	ld de,#msg_speed_full
	jr z,print_speed
	cp #1
	ld de,#msg_speed_low
	jr z,print_speed
	ld de,#msg_speed_unknown
print_speed:
	ld c,#BDOS_PRINT
	call BDOS

	; Reports only advance while the keyboard's interrupt endpoint is being
	; polled, so a rising count is proof the whole pipeline is live -- not
	; just that enumeration finished.
	ld de,#msg_kbd_reports
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 20)
	call print_hex_byte
	ld a,(rx_frame + 19)
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS

	; Boot protocol layout: modifier, reserved, then six keycodes.
	ld de,#msg_kbd_report
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#rx_frame + 21
	ld b,#8
print_report_byte:
	push bc
	push hl
	ld a,(hl)
	call print_hex_byte
	ld e,#' '
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop bc
	inc hl
	djnz print_report_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS

	ld de,#msg_int_drive
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 13)
	push af
	call print_hex_byte
	pop af
	cp #0x01
	ld de,#msg_int_pass
	jr z,print_int_drive
	cp #0x03
	ld de,#msg_int_stuck_hi
	jr z,print_int_drive
	cp #0xff
	ld de,#msg_int_xfer
	jr z,print_int_drive
	cp #0xfe
	ld de,#msg_int_na
	jr z,print_int_drive
	ld de,#msg_int_odd
print_int_drive:
	ld c,#BDOS_PRINT
	call BDOS

	ld a,(sel_page)
	cp #0xff
	jp nz,exit_ok			; default stops after the snapshot
page1_entry:
	ld a,(sel_page)
	cp #1
	jr z,run_page1
	cp #0xff
	jr z,run_page1
	jp page2_entry
run_page1:
	; ---- page 1: raw controller and stack state ------------------------
	; Separates "nothing ever connected" from "connected but enumeration
	; never finished" -- device count alone cannot, since it only advances
	; once enumeration completes.
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx2:
	ld (hl),a
	inc hl
	djnz zero_tx2
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx2:
	ld (hl),a
	inc hl
	djnz zero_rx2

	ld a,#CMD_HID_STATUS
	ld (tx_frame + 0),a
	ld a,#0x02
	ld (tx_frame + 1),a
	; LEN must be set: the transport carries exactly this many payload bytes,
	; so leaving it zero silently drops the page selector and the controller
	; answers with page 0.
	ld a,#1
	ld (tx_frame + 3),a		; payload length = 1 (page selector)
	ld a,#HID_PAGE_USB
	ld (tx_frame + 4),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_error
	ld a,(rx_frame + 3)
	cp #HID_USB_LEN
	jp nz,bad_length

	ld de,#msg_usb_hdr
	ld c,#BDOS_PRINT
	call BDOS

	ld de,#msg_task_calls
	call print_label_word
	ld de,#msg_int_disp
	ld hl,#rx_frame + 7
	call print_word_at
	ld de,#msg_connected
	ld hl,#rx_frame + 11
	call print_byte_at
	ld de,#msg_root_speed
	ld hl,#rx_frame + 12
	call print_byte_at
	ld de,#msg_reg_mode
	ld hl,#rx_frame + 14
	call print_byte_at
	ld de,#msg_reg_hirq
	ld hl,#rx_frame + 13
	call print_byte_at
	ld de,#msg_reg_hrsl
	ld hl,#rx_frame + 15
	call print_byte_at
	ld de,#msg_reg_usbirq
	ld hl,#rx_frame + 16
	call print_byte_at
	; Bit n set = device address n+1 enumerated.  Bit 2 is the hub, which the
	; device count can never show: usbh.c skips tuh_mount_cb() for hubs.
	ld de,#msg_mounted
	ld hl,#rx_frame + 17
	call print_byte_at
	ld a,(rx_frame + 17)
	and #0x04
	ld de,#msg_hub_no
	jr z,print_hub_state
	ld de,#msg_hub_yes
print_hub_state:
	ld c,#BDOS_PRINT
	call BDOS

	; Enumeration milestones.  The first of these reading 00 is where the
	; sequence stopped: attach -> device descriptor -> config descriptor.
	ld de,#msg_ev_attach
	ld hl,#rx_frame + 18
	call print_byte_at
	ld de,#msg_ev_remove
	ld hl,#rx_frame + 19
	call print_byte_at
	ld de,#msg_dev_desc
	ld hl,#rx_frame + 20
	call print_byte_at
	ld de,#msg_cfg_desc
	ld hl,#rx_frame + 21
	call print_byte_at
	; Last enumeration state entered.  05 = ADDR0_DEVICE_DESC, 06 = SET_ADDR,
	; 07 = GET_DEVICE_DESC, 10 = GET_9BYTE_CONFIG, 12 = SET_CONFIG,
	; 13 = CONFIG_DRIVER (hex).  FF = never entered.
	ld de,#msg_enum_state
	ld hl,#rx_frame + 22
	call print_byte_at
	ld de,#msg_enum_fails
	ld hl,#rx_frame + 23
	call print_byte_at
	ld de,#msg_ctrl_rej
	ld hl,#rx_frame + 24
	call print_byte_at
	ld a,(rx_frame + 24)
	or a
	jr z,print_hcd_taps
	ld de,#msg_ctrl_rej_warn
	ld c,#BDOS_PRINT
	call BDOS
print_hcd_taps:
	; Host controller layer: did the transfer ever complete in hardware?
	ld de,#msg_hxfrdn
	ld hl,#rx_frame + 25
	call print_byte_at
	ld de,#msg_xferdone
	ld hl,#rx_frame + 26
	call print_byte_at
	ld de,#msg_epnull
	ld hl,#rx_frame + 27
	call print_byte_at
	ld de,#msg_lasthrsl
	ld hl,#rx_frame + 28
	call print_byte_at
	; Packed: high nibble = control transfers started, low = completions
	; reported up to the host stack.  Unequal means the completion was lost
	; between the controller driver and usbh.
	ld de,#msg_startdone
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 29)
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call print_hex_nibble
	ld de,#msg_started_sep
	ld c,#BDOS_PRINT
	call BDOS
	ld a,(rx_frame + 29)
	and #0x0f
	call print_hex_nibble
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS

	ld a,(sel_page)
	cp #0xff
	jp nz,exit_ok
page2_entry:
	ld a,(sel_page)
	cp #2
	jr z,run_page2
	cp #0xff
	jr z,run_page2
	jp page3_entry
run_page2:
	; ---- page 2: what handle_xfer_done() branched on -------------------
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx3:
	ld (hl),a
	inc hl
	djnz zero_tx3
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx3:
	ld (hl),a
	inc hl
	djnz zero_rx3

	ld a,#CMD_HID_STATUS
	ld (tx_frame + 0),a
	ld a,#0x03
	ld (tx_frame + 1),a
	ld a,#1
	ld (tx_frame + 3),a		; LEN: the page selector is a payload byte
	ld a,#HID_PAGE_XFER
	ld (tx_frame + 4),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_error
	ld a,(rx_frame + 3)
	cp #HID_XFER_LEN
	jp nz,bad_length

	ld de,#msg_xfer_hdr
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_x_hxfr
	ld hl,#rx_frame + 5
	call print_byte_at
	ld de,#msg_x_epdir
	ld hl,#rx_frame + 6
	call print_byte_at
	ld de,#msg_x_peraddr
	ld hl,#rx_frame + 7
	call print_byte_at
	ld de,#msg_x_epnum
	ld hl,#rx_frame + 8
	call print_byte_at
	ld de,#msg_x_pktsize
	ld hl,#rx_frame + 9
	call print_byte_at
	ld de,#msg_x_total
	ld hl,#rx_frame + 10
	call print_word_at
	ld de,#msg_x_xferred
	ld hl,#rx_frame + 12
	call print_word_at
	ld de,#msg_x_epstate
	ld hl,#rx_frame + 14
	call print_byte_at
	ld de,#msg_x_xactlen
	ld hl,#rx_frame + 15
	call print_byte_at
	ld de,#msg_x_branch
	ld hl,#rx_frame + 16
	call print_byte_at
	ld a,(rx_frame + 16)
	cp #2
	ld de,#msg_x_br2
	jr z,print_branch_name
	cp #3
	ld de,#msg_x_br3
	jr z,print_branch_name
	or a
	ld de,#msg_x_br0
	jr z,print_branch_name
	ld de,#msg_x_br_ok
print_branch_name:
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_x_hub_open
	ld hl,#rx_frame + 17
	call print_byte_at
	ld de,#msg_x_hub_pre
	ld hl,#rx_frame + 18
	call print_byte_at
	ld de,#msg_x_hub_after_open
	ld hl,#rx_frame + 19
	call print_byte_at
	ld de,#msg_x_submit_addr
	ld hl,#rx_frame + 20
	call print_byte_at
	ld de,#msg_x_submit_ep
	ld hl,#rx_frame + 21
	call print_byte_at
	ld de,#msg_x_setup
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#rx_frame + 22
	ld b,#8
print_setup_byte:
	push bc
	push hl
	ld a,(hl)
	call print_hex_byte
	ld e,#' '
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop bc
	inc hl
	djnz print_setup_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS

	ld a,(sel_page)
	cp #0xff
	jp nz,exit_ok
page3_entry:
	ld a,(sel_page)
	cp #3
	jr z,run_page3
	cp #0xff
	jr z,run_page3
	jp page4_entry
run_page3:
	; ---- page 3: hub object lifecycle -----------------------------------
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx4:
	ld (hl),a
	inc hl
	djnz zero_tx4
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx4:
	ld (hl),a
	inc hl
	djnz zero_rx4

	ld a,#CMD_HID_STATUS
	ld (tx_frame + 0),a
	ld a,#0x04
	ld (tx_frame + 1),a
	ld a,#1
	ld (tx_frame + 3),a
	ld a,#HID_PAGE_HUB
	ld (tx_frame + 4),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_error
	ld a,(rx_frame + 3)
	cp #HID_HUB_LEN
	jp nz,bad_length

	ld de,#msg_hub_hdr
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_h_init
	ld hl,#rx_frame + 5
	call print_byte_at
	ld de,#msg_h_close
	ld hl,#rx_frame + 6
	call print_byte_at
	ld de,#msg_h_addr_entry
	ld hl,#rx_frame + 7
	call print_byte_at
	ld de,#msg_h_addr_post
	ld hl,#rx_frame + 8
	call print_byte_at
	ld de,#msg_h_object
	ld hl,#rx_frame + 9
	call print_word_at
	ld de,#msg_h_parsed
	ld hl,#rx_frame + 11
	call print_byte_at
	ld de,#msg_h_after_open
	ld hl,#rx_frame + 12
	call print_byte_at
	ld de,#msg_h_set_config
	ld hl,#rx_frame + 13
	call print_byte_at
	ld de,#msg_h_desc_pre
	ld hl,#rx_frame + 14
	call print_byte_at
	ld de,#msg_h_desc_post
	ld hl,#rx_frame + 15
	call print_byte_at
	ld de,#msg_h_port1
	ld hl,#rx_frame + 16
	call print_byte_at
	ld de,#msg_h_port2
	ld hl,#rx_frame + 17
	call print_byte_at
	ld de,#msg_h_port3
	ld hl,#rx_frame + 18
	call print_byte_at
	ld de,#msg_h_port4
	ld hl,#rx_frame + 19
	call print_byte_at
	ld de,#msg_h_preclaim
	ld hl,#rx_frame + 20
	call print_byte_at
	ld de,#msg_h_raw
	ld c,#BDOS_PRINT
	call BDOS
	ld hl,#rx_frame + 21
	ld b,#8
print_hub_raw_byte:
	push bc
	push hl
	ld a,(hl)
	call print_hex_byte
	ld e,#' '
	ld c,#BDOS_CONOUT
	call BDOS
	pop hl
	pop bc
	inc hl
	djnz print_hub_raw_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_h_close_addr
	ld hl,#rx_frame + 29
	call print_byte_at
	ret

; DE = label, prints label then the 16-bit LE word at rx_frame+5
print_label_word:
	ld hl,#rx_frame + 5
	; fall through
; DE = label, HL -> 16-bit little-endian word.  Print "label: HHLL" + CRLF.
print_word_at:
	push hl
	ld c,#BDOS_PRINT
	call BDOS
	pop hl
	; BDOS preserves nothing, and print_hex_byte calls it -- so the low byte
	; has to be carried in a register that survives, not re-read from (HL).
	ld a,(hl)
	ld b,a			; B = low byte
	inc hl
	ld a,(hl)		; A = high byte
	push bc
	call print_hex_byte
	pop bc
	ld a,b
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; DE = label, HL -> byte.  Print "label: HH" + CRLF.
print_byte_at:
	push hl
	ld c,#BDOS_PRINT
	call BDOS
	pop hl
	ld a,(hl)
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; A = match count 0..64.  Print "  (n of 64)" plus a verdict.
print_match_count:
	push af
	ld de,#msg_match_open
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	push af
	call print_dec_byte
	ld de,#msg_match_close
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	cp #64
	ld de,#msg_match_clean
	jr z,print_match_out
	or a
	ld de,#msg_match_none
	jr z,print_match_out
	ld de,#msg_match_marginal
print_match_out:
	ld c,#BDOS_PRINT
	call BDOS
	ret

; A = 0..99.  Print as decimal with no leading zero.
print_dec_byte:
	ld b,#0
pdb_tens:
	cp #10
	jr c,pdb_ones
	sub #10
	inc b
	jr pdb_tens
pdb_ones:
	ld c,a			; units in C, tens in B
	ld a,b
	or a
	jr z,pdb_units
	add a,#0x30
	push bc
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	pop bc
pdb_units:
	ld a,c
	add a,#0x30
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

; A = one GPOUT loopback result.  Print it as hex followed by its meaning.
;   00h  every pattern read back correctly
;   FFh  the controller's own SPI module never completed a byte
;   else a mask of the GPOUT bits that came back wrong
print_gpout_result:
	push af
	call print_hex_byte
	pop af
	or a
	ld de,#msg_gpout_pass
	jr z,print_gpout_out
	cp #0xff
	ld de,#msg_gpout_xfer
	jr z,print_gpout_out
	ld de,#msg_gpout_fail
print_gpout_out:
	ld c,#BDOS_PRINT
	call BDOS
	ret

; A = HidHostStatus.  Print its symbolic meaning.
print_status_name:
	cp #0
	ld de,#msg_not_started
	jr z,print_status
	cp #1
	ld de,#msg_ready
	jr z,print_status
	cp #2
	ld de,#msg_spi_error
	jr z,print_status
	cp #3
	ld de,#msg_bad_revision
	jr z,print_status
	cp #4
	ld de,#msg_init_failed
	jr z,print_status
	ld de,#msg_unknown_status
print_status:
	ld c,#BDOS_PRINT
	call BDOS
	ret

xport_error:
	push af
	ld de,#msg_xport_error
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

bad_reply:
	push af
	ld de,#msg_bad_reply
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_old_fw
	ld c,#BDOS_PRINT
	call BDOS
	ret

ioc_error:
	push af
	ld de,#msg_ioc_error
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

bad_length:
	push af
	ld de,#msg_bad_length
	ld c,#BDOS_PRINT
	call BDOS
	pop af
	call print_hex_byte
	ld de,#msg_crlf
	ld c,#BDOS_PRINT
	call BDOS
	ret

; Print A as two uppercase hexadecimal digits.
print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call print_hex_nibble
	pop af
	and #0x0f
print_hex_nibble:
	add a,#0x30
	cp #0x3a
	jr c,print_hex_out
	add a,#0x07
print_hex_out:
	ld e,a
	ld c,#BDOS_CONOUT
	call BDOS
	ret

	ld a,(sel_page)
	cp #0xff
	jp nz,exit_ok
page4_entry:
	ld a,(sel_page)
	cp #4
	jr z,run_page4
	cp #0xff
	jr z,run_page4
	jp page5_entry
run_page4:
	; ---- page 4: behind-hub enumeration entry ---------------------------
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx5:
	ld (hl),a
	inc hl
	djnz zero_tx5
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx5:
	ld (hl),a
	inc hl
	djnz zero_rx5

	ld a,#CMD_HID_STATUS
	ld (tx_frame + 0),a
	ld a,#0x05
	ld (tx_frame + 1),a
	ld a,#1
	ld (tx_frame + 3),a
	ld a,#HID_PAGE_ENUM
	ld (tx_frame + 4),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_error
	ld a,(rx_frame + 3)
	cp #HID_ENUM_LEN
	jp nz,bad_length

	ld de,#msg_enum_hdr
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_e_calls
	ld hl,#rx_frame + 5
	call print_byte_at
	ld de,#msg_e_addr
	ld hl,#rx_frame + 6
	call print_byte_at
	ld de,#msg_e_port
	ld hl,#rx_frame + 7
	call print_byte_at
	ld de,#msg_e_ret
	ld hl,#rx_frame + 8
	call print_byte_at
	ld a,(rx_frame + 8)
	cp #0xff
	ld de,#msg_e_never
	jr z,print_e_ret
	cp #0xfe
	ld de,#msg_e_port0
	jr z,print_e_ret
	or a
	ld de,#msg_e_refused
	jr z,print_e_ret
	ld de,#msg_e_ok
print_e_ret:
	ld c,#BDOS_PRINT
	call BDOS

	; The gate that gates every new attach.  FFh = idle and ready; anything
	; else means the attach path defers and re-queues the SAME event, which
	; presents as an unbounded attach count.
	ld de,#msg_e_gate
	ld hl,#rx_frame + 9
	call print_byte_at
	ld a,(rx_frame + 9)
	cp #0xff
	ld de,#msg_e_gate_idle
	jr z,print_e_gate
	ld de,#msg_e_gate_stuck
print_e_gate:
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_e_defers
	ld hl,#rx_frame + 10
	call print_byte_at
	ld de,#msg_e_completes
	ld hl,#rx_frame + 11
	call print_byte_at
	ld de,#msg_e_att_addr
	ld hl,#rx_frame + 12
	call print_byte_at
	ld de,#msg_e_att_port
	ld hl,#rx_frame + 13
	call print_byte_at

	; Host controller stall state.  An endpoint left at 03h (ATTEMPT_1) was
	; armed but never started, and the FRAME retry ignores it because that
	; test is strictly greater than ATTEMPT_1 -- stranded with no owner.
	ld de,#msg_e_busy
	ld hl,#rx_frame + 14
	call print_byte_at
	ld de,#msg_e_epstate
	ld hl,#rx_frame + 15
	call print_byte_at
	ld de,#msg_e_eppkt
	ld hl,#rx_frame + 16
	call print_byte_at
	ld a,(rx_frame + 15)
	cp #0xff
	ld de,#msg_e_ep_none
	jr z,print_e_ep
	cp #3
	ld de,#msg_e_ep_stranded
	jr z,print_e_ep
	ld de,#msg_e_ep_other
print_e_ep:
	ld c,#BDOS_PRINT
	call BDOS

	; Was the completed status transfer ever handed to the hub class driver?
	; hub_xfer_cb() re-arms on every path it takes, so a zero here means the
	; completion never got there -- a dispatch fault, not a hub fault.
	ld de,#msg_e_hubcb
	ld hl,#rx_frame + 17
	call print_byte_at
	ld de,#msg_e_hubarm
	ld hl,#rx_frame + 18
	call print_byte_at
	ld de,#msg_e_hubchange
	ld hl,#rx_frame + 19
	call print_byte_at
	ld a,(rx_frame + 17)
	or a
	ld de,#msg_e_cb_never
	jr z,print_e_cb
	ld de,#msg_e_cb_ran
print_e_cb:
	ld c,#BDOS_PRINT
	call BDOS

	; Endpoint table.  hcd_edpt_open() fails silently when full, which shows
	; up much later as an endpoint that simply is not there.
	ld de,#msg_e_epfail
	ld hl,#rx_frame + 20
	call print_byte_at
	ld de,#msg_e_epused
	ld hl,#rx_frame + 21
	call print_byte_at
	ld de,#msg_e_eptotal
	ld hl,#rx_frame + 22
	call print_byte_at
	ld a,(rx_frame + 20)
	or a
	ld de,#msg_e_ep_ok
	jr z,print_e_epf
	ld de,#msg_e_ep_full
print_e_epf:
	ld c,#BDOS_PRINT
	call BDOS

	; Endpoint-to-driver binding.  FFh means the hub's interrupt endpoint was
	; never bound to a class driver, so get_driver(0xFF) returns NULL and
	; every completion for it is discarded with no error.
	ld de,#msg_e_ep2drv
	ld hl,#rx_frame + 23
	call print_byte_at
	ld de,#msg_e_bindcalls
	ld hl,#rx_frame + 24
	call print_byte_at
	ld de,#msg_e_binddrvid
	ld hl,#rx_frame + 25
	call print_byte_at
	ld de,#msg_e_bindlen
	ld hl,#rx_frame + 26
	call print_word_at
	ld a,(rx_frame + 23)
	cp #0xff
	ld de,#msg_e_unbound
	jr z,print_e_bind
	cp #0xfe
	ld de,#msg_e_nodev
	jr z,print_e_bind
	ld de,#msg_e_bound
print_e_bind:
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_e_itfclob
	ld hl,#rx_frame + 28
	call print_byte_at
	ld a,(rx_frame + 28)
	or a
	ld de,#msg_e_itf_ok
	jr z,print_e_itf
	ld de,#msg_e_itf_bad
print_e_itf:
	ld c,#BDOS_PRINT
	call BDOS
	; If the bind landed here instead of [IN], tu_edpt_dir() gave the wrong
	; direction and the map is written to the wrong slot.
	ld de,#msg_e_ep2drvout
	ld hl,#rx_frame + 29
	call print_byte_at
	ld a,(rx_frame + 29)
	cp #0xff
	ld de,#msg_e_out_empty
	jr z,print_e_out
	ld de,#msg_e_out_wrong
print_e_out:
	ld c,#BDOS_PRINT
	call BDOS
	ret

	ld a,(sel_page)
	cp #0xff
	jp nz,exit_ok
page5_entry:
	ld a,(sel_page)
	cp #5
	jr z,run_page5
	cp #0xff
	jr z,run_page5
	jp exit_ok
run_page5:
	; ---- page 5: HID class driver set-config chain ----------------------
	xor a
	ld hl,#tx_frame
	ld b,#32
zero_tx6:
	ld (hl),a
	inc hl
	djnz zero_tx6
	ld a,#0xa5
	ld hl,#rx_frame
	ld b,#32
zero_rx6:
	ld (hl),a
	inc hl
	djnz zero_rx6

	ld a,#CMD_HID_STATUS
	ld (tx_frame + 0),a
	ld a,#0x06
	ld (tx_frame + 1),a
	ld a,#1
	ld (tx_frame + 3),a
	ld a,#HID_PAGE_HIDCFG
	ld (tx_frame + 4),a

	ld hl,#tx_frame
	ld de,#rx_frame
	call IOCALL
	or a
	jp nz,xport_error
	ld a,(rx_frame + 3)
	cp #HID_CFG_LEN
	jp nz,bad_length

	ld de,#msg_c_hdr
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_c_open
	ld hl,#rx_frame + 5
	call print_byte_at
	ld de,#msg_c_setcfg
	ld hl,#rx_frame + 6
	call print_byte_at
	ld de,#msg_c_proc
	ld hl,#rx_frame + 7
	call print_byte_at
	ld de,#msg_c_state
	ld hl,#rx_frame + 8
	call print_byte_at
	ld de,#msg_c_itfnum
	ld hl,#rx_frame + 9
	call print_byte_at
	ld de,#msg_c_breq
	ld hl,#rx_frame + 10
	call print_byte_at
	ld de,#msg_c_result
	ld hl,#rx_frame + 11
	call print_byte_at
	ld de,#msg_c_mount
	ld hl,#rx_frame + 12
	call print_byte_at
	ld de,#msg_c_mountcb
	ld hl,#rx_frame + 13
	call print_byte_at
	ld a,(rx_frame + 12)
	or a
	ld de,#msg_c_nomount
	jr z,print_c_v
	ld de,#msg_c_mounted
print_c_v:
	ld c,#BDOS_PRINT
	call BDOS
	; What tuh_hid_mount_cb() was actually handed, before any filtering.
	ld de,#msg_c_hidmounts
	ld hl,#rx_frame + 14
	call print_byte_at
	ld de,#msg_c_daddr
	ld hl,#rx_frame + 15
	call print_byte_at
	ld de,#msg_c_inst
	ld hl,#rx_frame + 16
	call print_byte_at
	ld de,#msg_c_proto
	ld hl,#rx_frame + 17
	call print_byte_at
	ld a,(rx_frame + 17)
	cp #1
	ld de,#msg_c_p_kbd
	jr z,print_c_p
	or a
	ld de,#msg_c_p_none
	jr z,print_c_p
	cp #2
	ld de,#msg_c_p_mouse
	jr z,print_c_p
	ld de,#msg_c_p_other
print_c_p:
	ld c,#BDOS_PRINT
	call BDOS
	ld de,#msg_c_arm
	ld hl,#rx_frame + 18
	call print_byte_at
	ld a,(rx_frame + 18)
	cp #1
	ld de,#msg_c_arm_ok
	jr z,print_c_a
	ld de,#msg_c_arm_bad
print_c_a:
	ld c,#BDOS_PRINT
	call BDOS
	; The keyboard's OWN endpoint at address 1.  Only the hub's had ever been
	; checked; an unbound ep here discards every report silently.
	ld de,#msg_c_kstate
	ld hl,#rx_frame + 19
	call print_byte_at
	ld de,#msg_c_kpkt
	ld hl,#rx_frame + 20
	call print_byte_at
	ld de,#msg_c_kep2drv
	ld hl,#rx_frame + 21
	call print_byte_at
	ld de,#msg_c_kbusy
	ld hl,#rx_frame + 22
	call print_byte_at
	ld a,(rx_frame + 21)
	cp #0xff
	ld de,#msg_c_k_unbound
	jr z,print_c_k
	cp #0xfe
	ld de,#msg_c_k_nodev
	jr z,print_c_k
	ld de,#msg_c_k_bound
print_c_k:
	ld c,#BDOS_PRINT
	call BDOS
	; The endpoint address hidh_open() captured.  81h is the interrupt IN
	; endpoint; 00h means report arming targets the control endpoint instead.
	ld de,#msg_c_epin
	ld hl,#rx_frame + 23
	call print_byte_at
	ld a,(rx_frame + 23)
	or a
	ld de,#msg_c_epin_bad
	jr z,print_c_e
	ld de,#msg_c_epin_ok
print_c_e:
	ld c,#BDOS_PRINT
	call BDOS
	; Does the keyboard's transfer reach the controller, and its completion
	; come back up through the HID driver into this port?
	ld de,#msg_c_ksub
	ld hl,#rx_frame + 24
	call print_byte_at
	ld de,#msg_c_xfercb
	ld hl,#rx_frame + 25
	call print_byte_at
	ld de,#msg_c_xfercbep
	ld hl,#rx_frame + 26
	call print_byte_at
	ld de,#msg_c_rptcb
	ld hl,#rx_frame + 27
	call print_byte_at
	ld de,#msg_c_rptdaddr
	ld hl,#rx_frame + 28
	call print_byte_at
	ld de,#msg_c_rptinst
	ld hl,#rx_frame + 29
	call print_byte_at
	ld a,(rx_frame + 24)
	or a
	ld de,#msg_c_nosub
	jr z,print_c_r
	ld a,(rx_frame + 25)
	or a
	ld de,#msg_c_nocb
	jr z,print_c_r
	ld a,(rx_frame + 27)
	or a
	ld de,#msg_c_norpt
	jr z,print_c_r
	ld de,#msg_c_pathok
print_c_r:
	ld c,#BDOS_PRINT
	call BDOS
	ret

exit_ok:
	ret

; Read the CP/M command tail (length at 0080h, text from 0081h) and store the
; selected page in sel_page: 0 = snapshot only, 1..3 = that detail page,
; FFh = all pages.
parse_arg:
	xor a
	ld (sel_page),a
	ld a,(0x0080)
	or a
	ret z				; no tail at all
	ld b,a
	ld hl,#0x0081
parse_skip:
	ld a,(hl)
	cp #' '
	jr nz,parse_got
	inc hl
	djnz parse_skip
	ret				; tail was all blanks
parse_got:
	cp #'1'
	jr c,parse_alpha
	cp #'6'
	jr nc,parse_alpha
	sub #'0'
	ld (sel_page),a
	ret
parse_alpha:
	; anything else means "all"; 'a' and 'A' are the documented spelling
	ld a,#0xff
	ld (sel_page),a
	ret

sel_page:
	.db 0

msg_e_ep2drvout:
	.ascii "  ep2drv[1][OUT] : "
	.db '$'
msg_e_out_empty:
	.ascii "  empty too - the bind wrote nowhere"
	.db 0x0d,0x0a,'$'
msg_e_out_wrong:
	.ascii "  BOUND HERE - tu_edpt_dir() returned the wrong direction"
	.db 0x0d,0x0a,'$'
msg_e_itfclob:
	.ascii "  desc_itf clobb : "
	.db '$'
msg_e_itf_ok:
	.ascii "  survived driver->open()"
	.db 0x0d,0x0a,'$'
msg_e_itf_bad:
	.ascii "  CLOBBERED across driver->open() - repaired by the port"
	.db 0x0d,0x0a,'$'
msg_e_ep2drv:
	.ascii "  ep2drv[1][IN]  : "
	.db '$'
msg_e_bindcalls:
	.ascii "  bind calls     : "
	.db '$'
msg_e_binddrvid:
	.ascii "  bind drv_id    : "
	.db '$'
msg_e_bindlen:
	.ascii "  bind drv_len   : "
	.db '$'
msg_e_unbound:
	.ascii "  NEVER BOUND - completions for this ep are discarded"
	.db 0x0d,0x0a,'$'
msg_e_nodev:
	.ascii "  NO SUCH DEVICE at address 3"
	.db 0x0d,0x0a,'$'
msg_e_bound:
	.ascii "  bound to a driver"
	.db 0x0d,0x0a,'$'
msg_e_epfail:
	.ascii "  ep alloc fails : "
	.db '$'
msg_e_epused:
	.ascii "  ep slots used  : "
	.db '$'
msg_e_eptotal:
	.ascii "  ep slots total : "
	.db '$'
msg_e_ep_full:
	.ascii "  TABLE FULL - hcd_edpt_open failed silently"
	.db 0x0d,0x0a,'$'
msg_e_ep_ok:
	.ascii "  no allocation failures"
	.db 0x0d,0x0a,'$'
msg_e_hubcb:
	.ascii "  hub_xfer_cb    : "
	.db '$'
msg_e_hubarm:
	.ascii "  status arms    : "
	.db '$'
msg_e_hubchange:
	.ascii "  status change  : "
	.db '$'
msg_e_cb_never:
	.ascii "  NEVER DISPATCHED - completion never reached the hub driver"
	.db 0x0d,0x0a,'$'
msg_e_cb_ran:
	.ascii "  dispatched - hub driver did run"
	.db 0x0d,0x0a,'$'
msg_e_busy:
	.ascii "  busy_lock      : "
	.db '$'
msg_e_epstate:
	.ascii "  hub ep state   : "
	.db '$'
msg_e_eppkt:
	.ascii "  hub ep pktsize : "
	.db '$'
msg_e_ep_none:
	.ascii "  NO SUCH EP - hub int-IN was never opened"
	.db 0x0d,0x0a,'$'
msg_e_ep_stranded:
	.ascii "  ATTEMPT_1 - armed but never started (STRANDED)"
	.db 0x0d,0x0a,'$'
msg_e_ep_other:
	.ascii "  running or idle"
	.db 0x0d,0x0a,'$'
msg_e_gate:
	.ascii "  enumerating    : "
	.db '$'
msg_e_gate_idle:
	.ascii "  idle - ready for a new attach"
	.db 0x0d,0x0a,'$'
msg_e_gate_stuck:
	.ascii "  STUCK - every attach defers and re-queues"
	.db 0x0d,0x0a,'$'
msg_e_defers:
	.ascii "  defer count    : "
	.db '$'
msg_e_completes:
	.ascii "  enum completes : "
	.db '$'
msg_e_att_addr:
	.ascii "  attach hub addr: "
	.db '$'
msg_e_att_port:
	.ascii "  attach hub port: "
	.db '$'
msg_enum_hdr:
	.db 0x0d,0x0a
	.ascii "DOWNSTREAM ENUM"
	.db 0x0d,0x0a,'$'
msg_e_calls:
	.ascii "  branch entries : "
	.db '$'
msg_e_addr:
	.ascii "  hub address    : "
	.db '$'
msg_e_port:
	.ascii "  hub port       : "
	.db '$'
msg_e_ret:
	.ascii "  get_status ret : "
	.db '$'
msg_e_never:
	.ascii "  BRANCH NEVER REACHED - attach never got this far"
	.db 0x0d,0x0a,'$'
msg_e_port0:
	.ascii "  hub_port was 0 - aborted before the call"
	.db 0x0d,0x0a,'$'
msg_e_refused:
	.ascii "  REFUSED - aborts before the state machine"
	.db 0x0d,0x0a,'$'
msg_e_ok:
	.ascii "  accepted - enumeration should have started"
	.db 0x0d,0x0a,'$'
msg_c_ksub:
	.ascii "  ep81 submits   : "
	.db '$'
msg_c_xfercb:
	.ascii "  hidh_xfer_cb   : "
	.db '$'
msg_c_xfercbep:
	.ascii "  epin after wr  : "
	.db '$'
msg_c_rptcb:
	.ascii "  report_cb      : "
	.db '$'
msg_c_rptdaddr:
	.ascii "  itf clears     : "
	.db '$'
msg_c_rptinst:
	.ascii "  epin_size      : "
	.db '$'
msg_c_nosub:
	.ascii "  NEVER SUBMITTED - the arm does not reach the controller"
	.db 0x0d,0x0a,'$'
msg_c_nocb:
	.ascii "  SUBMITTED but never completed into the HID driver"
	.db 0x0d,0x0a,'$'
msg_c_norpt:
	.ascii "  HID driver ran but the report never reached this port"
	.db 0x0d,0x0a,'$'
msg_c_pathok:
	.ascii "  full path exercised - check the guard"
	.db 0x0d,0x0a,'$'
msg_c_epin:
	.ascii "  hid ep_in      : "
	.db '$'
msg_c_epin_bad:
	.ascii "  ZERO - arming would target the control endpoint"
	.db 0x0d,0x0a,'$'
msg_c_epin_ok:
	.ascii "  interrupt endpoint captured"
	.db 0x0d,0x0a,'$'
msg_c_kstate:
	.ascii "  kbd ep state   : "
	.db '$'
msg_c_kpkt:
	.ascii "  kbd ep pktsize : "
	.db '$'
msg_c_kep2drv:
	.ascii "  kbd ep2drv     : "
	.db '$'
msg_c_kbusy:
	.ascii "  busy_lock      : "
	.db '$'
msg_c_k_unbound:
	.ascii "  UNBOUND - reports discarded before the HID driver"
	.db 0x0d,0x0a,'$'
msg_c_k_nodev:
	.ascii "  NO DEVICE at address 1"
	.db 0x0d,0x0a,'$'
msg_c_k_bound:
	.ascii "  bound - reports should reach the HID driver"
	.db 0x0d,0x0a,'$'
msg_c_hidmounts:
	.ascii "  hid_mount_cb   : "
	.db '$'
msg_c_daddr:
	.ascii "  mount daddr    : "
	.db '$'
msg_c_inst:
	.ascii "  mount instance : "
	.db '$'
msg_c_proto:
	.ascii "  itf protocol   : "
	.db '$'
msg_c_p_kbd:
	.ascii "  KEYBOARD"
	.db 0x0d,0x0a,'$'
msg_c_p_none:
	.ascii "  none declared (still usable in boot protocol)"
	.db 0x0d,0x0a,'$'
msg_c_p_mouse:
	.ascii "  mouse - ignored"
	.db 0x0d,0x0a,'$'
msg_c_p_other:
	.ascii "  never called"
	.db 0x0d,0x0a,'$'
msg_c_arm:
	.ascii "  first arm       : "
	.db '$'
msg_c_arm_ok:
	.ascii "  accepted - reports should flow"
	.db 0x0d,0x0a,'$'
msg_c_arm_bad:
	.ascii "  REFUSED - no reports will arrive"
	.db 0x0d,0x0a,'$'
msg_c_hdr:
	.db 0x0d,0x0a
	.ascii "HID SET-CONFIG"
	.db 0x0d,0x0a,'$'
msg_c_open:
	.ascii "  hidh_open      : "
	.db '$'
msg_c_setcfg:
	.ascii "  hidh_set_config: "
	.db '$'
msg_c_proc:
	.ascii "  process_setcfg : "
	.db '$'
msg_c_state:
	.ascii "  last state     : "
	.db '$'
msg_c_itfnum:
	.ascii "  itf_num        : "
	.db '$'
msg_c_breq:
	.ascii "  bRequest       : "
	.db '$'
msg_c_result:
	.ascii "  xfer result    : "
	.db '$'
msg_c_mount:
	.ascii "  mount complete : "
	.db '$'
msg_c_mountcb:
	.ascii "  tuh_mount_cb   : "
	.db '$'
msg_c_nomount:
	.ascii "                     HID mount never completed"
	.db 0x0d,0x0a,'$'
msg_c_mounted:
	.ascii "                     HID mount completed"
	.db 0x0d,0x0a,'$'
msg_banner:
	.ascii "IOC HID STATUS"
	.db 0x0d,0x0a,'$'
msg_status:
	.ascii "  bring-up status : "
	.db '$'
msg_revision:
	.ascii "  MAX3421E REVISION: "
	.db '$'
msg_int_level:
	.db 0x0d,0x0a
	.ascii "  /USB_INT level  : "
	.db '$'
msg_not_started:
	.ascii "  NOT STARTED"
	.db 0x0d,0x0a,'$'
msg_ready:
	.ascii "  CONTROLLER READY"
	.db 0x0d,0x0a,'$'
msg_spi_error:
	.ascii "  SPI ERROR"
	.db 0x0d,0x0a,'$'
msg_bad_revision:
	.ascii "  BAD REVISION"
	.db 0x0d,0x0a,'$'
msg_init_failed:
	.ascii "  TINYUSB INIT FAILED"
	.db 0x0d,0x0a,'$'
msg_unknown_status:
	.ascii "  UNKNOWN"
	.db 0x0d,0x0a,'$'
msg_int_asserted:
	.ascii "  ASSERTED (pending; not serviced in this phase)"
	.db 0x0d,0x0a,'$'
msg_int_inactive:
	.ascii "  inactive"
	.db 0x0d,0x0a,'$'
msg_rev_125k:
	.ascii "  live REV @125k : "
	.db '$'
msg_rev_1m:
	.db 0x0d,0x0a
	.ascii "  live REV @1MHz : "
	.db '$'
msg_rev_4m:
	.db 0x0d,0x0a
	.ascii "  live REV @4MHz : "
	.db '$'
msg_gpout_125k:
	.db 0x0d,0x0a
	.ascii "  GPOUT link@125k: "
	.db '$'
msg_gpout_1m:
	.ascii "  GPOUT link@1MHz: "
	.db '$'
msg_gpout_4m:
	.ascii "  GPOUT link@4MHz: "
	.db '$'
msg_gpout_pass:
	.ascii "  ok"
	.db 0x0d,0x0a,'$'
msg_gpout_xfer:
	.ascii "  SPI MODULE TIMEOUT (nothing learned about the far end)"
	.db 0x0d,0x0a,'$'
msg_gpout_fail:
	.ascii "  FAIL (hi nibble = patterns failed of 8, lo = bit mask)"
	.db 0x0d,0x0a,'$'
msg_usb_hdr:
	.db 0x0d,0x0a
	.ascii "USB DEBUG"
	.db 0x0d,0x0a,'$'
msg_task_calls:
	.ascii "  task calls     : "
	.db '$'
msg_int_disp:
	.ascii "  int dispatches : "
	.db '$'
msg_connected:
	.ascii "  port connected : "
	.db '$'
msg_root_speed:
	.ascii "  root speed     : "
	.db '$'
msg_reg_mode:
	.ascii "  MODE   (R27)   : "
	.db '$'
msg_reg_hirq:
	.ascii "  HIRQ   (R25)   : "
	.db '$'
msg_reg_hrsl:
	.ascii "  HRSL   (R31)   : "
	.db '$'
msg_reg_usbirq:
	.ascii "  USBIRQ (R13)   : "
	.db '$'
msg_ev_attach:
	.ascii "  attach events  : "
	.db '$'
msg_ev_remove:
	.ascii "  remove events  : "
	.db '$'
msg_dev_desc:
	.ascii "  device descr   : "
	.db '$'
msg_cfg_desc:
	.ascii "  config descr   : "
	.db '$'
msg_xfer_hdr:
	.db 0x0d,0x0a
	.ascii "XFER DECISION"
	.db 0x0d,0x0a,'$'
msg_x_hxfr:
	.ascii "  HXFR reg       : "
	.db '$'
msg_x_epdir:
	.ascii "  ep_dir         : "
	.db '$'
msg_x_peraddr:
	.ascii "  PERADDR        : "
	.db '$'
msg_x_epnum:
	.ascii "  ep_num         : "
	.db '$'
msg_x_pktsize:
	.ascii "  packet_size    : "
	.db '$'
msg_x_total:
	.ascii "  total_len      : "
	.db '$'
msg_x_xferred:
	.ascii "  xferred_len    : "
	.db '$'
msg_x_epstate:
	.ascii "  ep state       : "
	.db '$'
msg_x_xactlen:
	.ascii "  xact_len       : "
	.db '$'
msg_x_branch:
	.ascii "  branch taken   : "
	.db '$'
msg_x_hub_open:
	.ascii "  hub open ep    : "
	.db '$'
msg_x_hub_pre:
	.ascii "  hub ep preclaim: "
	.db '$'
msg_x_hub_after_open:
	.ascii "  hub after open : "
	.db '$'
msg_x_submit_addr:
	.ascii "  submit address : "
	.db '$'
msg_x_submit_ep:
	.ascii "  submit endpoint: "
	.db '$'
msg_x_setup:
	.ascii "  last SETUP     : "
	.db '$'
msg_hub_hdr:
	.db 0x0d,0x0a
	.ascii "HUB LIFECYCLE"
	.db 0x0d,0x0a,'$'
msg_h_init:
	.ascii "  init calls     : "
	.db '$'
msg_h_close:
	.ascii "  close calls    : "
	.db '$'
msg_h_addr_entry:
	.ascii "  open addr entry: "
	.db '$'
msg_h_addr_post:
	.ascii "  open addr post : "
	.db '$'
msg_h_object:
	.ascii "  open object ptr: "
	.db '$'
msg_h_parsed:
	.ascii "  parsed ep      : "
	.db '$'
msg_h_after_open:
	.ascii "  after open     : "
	.db '$'
msg_h_set_config:
	.ascii "  at set_config  : "
	.db '$'
msg_h_desc_pre:
	.ascii "  descriptor pre : "
	.db '$'
msg_h_desc_post:
	.ascii "  descriptor post: "
	.db '$'
msg_h_port1:
	.ascii "  port 1 complete: "
	.db '$'
msg_h_port2:
	.ascii "  port 2 complete: "
	.db '$'
msg_h_port3:
	.ascii "  port 3 complete: "
	.db '$'
msg_h_port4:
	.ascii "  port 4 complete: "
	.db '$'
msg_h_preclaim:
	.ascii "  before claim   : "
	.db '$'
msg_h_raw:
	.ascii "  raw hub object : "
	.db '$'
msg_h_close_addr:
	.ascii "  last close addr: "
	.db '$'
msg_x_br0:
	.ascii "                     never reached the branch"
	.db 0x0d,0x0a,'$'
msg_x_br2:
	.ascii "                     took xact_out - thinks more to send"
	.db 0x0d,0x0a,'$'
msg_x_br3:
	.ascii "                     re-issued HXFR on the IN path - wrong direction"
	.db 0x0d,0x0a,'$'
msg_x_br_ok:
	.ascii "                     completed"
	.db 0x0d,0x0a,'$'
msg_startdone:
	.ascii "  setups started : "
	.db '$'
msg_started_sep:
	.ascii "   xfer events up: "
	.db '$'
msg_hxfrdn:
	.ascii "  HXFRDN seen    : "
	.db '$'
msg_xferdone:
	.ascii "  xfer_done runs : "
	.db '$'
msg_epnull:
	.ascii "  ep lookup fail : "
	.db '$'
msg_lasthrsl:
	.ascii "  HRSL at done   : "
	.db '$'
msg_enum_state:
	.ascii "  last enum state: "
	.db '$'
msg_enum_fails:
	.ascii "  enum failures  : "
	.db '$'
msg_ctrl_rej:
	.ascii "  ctrl rejected  : "
	.db '$'
msg_ctrl_rej_warn:
	.ascii "                     NONZERO - a step used the blocking control API"
	.db 0x0d,0x0a,'$'
msg_mounted:
	.ascii "  mounted addrs  : "
	.db '$'
msg_hub_yes:
	.ascii "                     bit2 set - HUB IS ENUMERATED"
	.db 0x0d,0x0a,'$'
msg_hub_no:
	.ascii "                     bit2 clear - hub NOT enumerated"
	.db 0x0d,0x0a,'$'
msg_usb_devs:
	.ascii "  USB devices    : "
	.db '$'
msg_kbd_addr:
	.ascii "  keyboard addr  : "
	.db '$'
msg_kbd_none:
	.ascii "  none mounted"
	.db 0x0d,0x0a,'$'
msg_kbd_mounted:
	.ascii "  MOUNTED"
	.db 0x0d,0x0a,'$'
msg_kbd_speed:
	.ascii "  keyboard speed : "
	.db '$'
msg_speed_full:
	.ascii "  full speed - supported"
	.db 0x0d,0x0a,'$'
msg_speed_low:
	.ascii "  LOW SPEED - unreachable behind the hub"
	.db 0x0d,0x0a
	.ascii "                     driver has no PRE-packet support; try a FS keyboard"
	.db 0x0d,0x0a,'$'
msg_speed_unknown:
	.ascii "  none"
	.db 0x0d,0x0a,'$'
msg_kbd_reports:
	.ascii "  boot reports   : "
	.db '$'
msg_kbd_report:
	.ascii "  last report    : "
	.db '$'
msg_match_open:
	.ascii "  ("
	.db '$'
msg_match_close:
	.ascii " of 64)"
	.db '$'
msg_match_clean:
	.ascii "  clean"
	.db '$'
msg_match_marginal:
	.ascii "  MARGINAL"
	.db '$'
msg_match_none:
	.ascii "  no valid read"
	.db '$'
msg_int_drive:
	.ascii "  INT drive test : "
	.db '$'
msg_int_pass:
	.ascii "  PASS - controller is powered and hearing us"
	.db 0x0d,0x0a
	.ascii "                     a silent MISO is now U2.15 or its stub alone"
	.db 0x0d,0x0a,'$'
msg_int_stuck_hi:
	.ascii "  STUCK HIGH - nothing is reaching the part"
	.db 0x0d,0x0a
	.ascii "                     check VCC (U2.23) and VL (U2.2) AT THE PINS"
	.db 0x0d,0x0a,'$'
msg_int_xfer:
	.ascii "  SPI MODULE TIMEOUT"
	.db 0x0d,0x0a,'$'
msg_int_na:
	.ascii "  n/a - USB is live, INT belongs to the stack"
	.db 0x0d,0x0a,'$'
msg_int_odd:
	.ascii "  UNEXPECTED (00 = stuck low, 02 = inverted)"
	.db 0x0d,0x0a,'$'
msg_xport_error:
	.ascii "transport error 0x"
	.db '$'
msg_bad_reply:
	.ascii "unexpected reply 0x"
	.db '$'
msg_old_fw:
	.ascii " (flash controller firmware level 61)"
	.db 0x0d,0x0a,'$'
msg_ioc_error:
	.ascii "controller status error 0x"
	.db '$'
msg_bad_length:
	.ascii "unexpected payload length 0x"
	.db '$'
msg_crlf:
	.db 0x0d,0x0a,'$'

tx_frame:
	.ds 32
rx_frame:
	.ds 32
