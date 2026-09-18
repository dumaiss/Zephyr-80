; sdwild.inc -- ambiguous-name support for SDGET and SDPUT.
;
; SEPARATE FROM sdfs.inc, AND INCLUDED LAST, FOR ONE REASON: the match table is
; 1.4K of .ds, and .ds only costs nothing when nothing emitted follows it.
; sdfs.inc is followed by zbdos.inc, which emits IOCALL and friends, so a table
; declared there would be zero-filled into the middle of the .COM -- it took
; SDDIR from 1145 bytes to 2784.  Here it is the last thing assembled.
;
; Only SDGET and SDPUT include this.  SDDIR lists everything already and SDDEL
; is destructive, so neither wants a pattern.

; How many matching names one wildcard run carries.
MAX_MATCH	= 128

; ---------------------------------------------------------------------------
; Ambiguous names
;
; The CCP expands * into ? while it packs FCB1, so by the time a transient runs
; there is no * left: an ambiguous name is simply one with a 3Fh in it.  That is
; also the form the BDOS search calls match against and the form READDIR sends
; back -- pack_name() on the controller emits the same eleven space-padded bytes
; an FCB holds -- so matching is an eleven-byte compare and nothing here parses
; a filename.
;
; Names arrive from the controller upper case: FF_USE_LFN is 0, so f_readdir
; reports the raw 8.3 short name, and the CCP has already folded the pattern.
; No case handling is needed on either side.
; ---------------------------------------------------------------------------

; Carry set if the name in FCB1 is ambiguous.
name_is_ambiguous:
	ld hl,#FCB1 + 1
	ld b,#11
nia_loop:
	ld a,(hl)
	cp #'?'
	scf
	ret z
	inc hl
	djnz nia_loop
	or a				; clear carry
	ret

; Keep FCB1's name as the pattern.  Must run before the name field is replaced
; with a concrete match.
save_pattern:
	ld hl,#FCB1 + 1
	ld de,#pattern
	ld bc,#11
	ldir
	ret

; Z if the eleven packed bytes at HL match (pattern).  HL is preserved.
name_match:
	push hl
	ld de,#pattern
	ld b,#11
nm_loop:
	ld a,(de)
	cp #'?'
	jr z,nm_next
	ld c,a
	ld a,(hl)
	cp c
	jr nz,nm_no
nm_next:
	inc hl
	inc de
	djnz nm_loop
	pop hl
	xor a
	ret
nm_no:
	pop hl
	or #0xff
	ret

; Append the eleven bytes at HL to the match table.  A table full is not an
; error: it is recorded so the caller can say the listing was cut short, which
; is more useful than refusing to copy anything.
match_add:
	ld a,(match_count)
	cp #MAX_MATCH
	jr nc,ma_full
	ld de,#match_table
	or a
	jr z,ma_store
	ld b,a
ma_adv:
	ld a,#11
	add a,e
	ld e,a
	jr nc,ma_noc
	inc d
ma_noc:
	djnz ma_adv
ma_store:
	ld bc,#11
	ldir
	ld hl,#match_count
	inc (hl)
	ret
ma_full:
	ld a,#1
	ld (match_over),a
	ret

; HL = match table entry A.
match_entry:
	ld hl,#match_table
	or a
	ret z
	ld b,a
me_adv:
	ld a,#11
	add a,l
	ld l,a
	jr nc,me_noc
	inc h
me_noc:
	djnz me_adv
	ret

; Put the eleven bytes at HL into FCB1's name field.
set_fcb_name:
	ld de,#FCB1 + 1
	ld bc,#11
	ldir
	ret

; Walk the CP/M directory for entries matching FCB1 and collect them.
;
; FCB1 is the search FCB, so nothing may touch it or the default DMA buffer
; between the first call and the last -- which is why this fills a table
; instead of copying as it goes.  EX is zero, so a file that spans extents is
; reported once rather than once per extent.
collect_cpm:
	xor a
	ld (match_count),a
	ld (match_over),a
	ld de,#FCB1
	ld c,#BDOS_SFIRST
	call BDOS
cc_check:
	inc a
	ret z				; FFh: no more entries
	dec a
	add a,a
	add a,a
	add a,a
	add a,a
	add a,a				; the entry is at DMA + index * 32
	ld hl,#DEFAULT_DMA
	add a,l
	ld l,a
	jr nc,cc_noc
	inc h
cc_noc:
	inc hl				; past the user-number byte, onto the name
	call match_add
	ld de,#FCB1
	ld c,#BDOS_SNEXT
	call BDOS
	jr cc_check

; Characters print_name would emit for the packed name at HL, returned in B.
; Counting them is cheaper than a cursor query and does not depend on the
; console driver.
name_width:
	push hl
	ld b,#0
	ld c,#8
nw_base:
	ld a,(hl)
	cp #' '
	jr z,nw_ext
	inc b
	inc hl
	dec c
	jr nz,nw_base
nw_ext:
	pop hl
	push hl
	ld de,#8
	add hl,de
	ld a,(hl)
	cp #' '
	jr z,nw_done
	inc b				; the dot
	ld c,#3
nw_ext_loop:
	ld a,(hl)
	cp #' '
	jr z,nw_done
	inc b
	inc hl
	dec c
	jr nz,nw_ext_loop
nw_done:
	pop hl
	ret

; The packed name at HL, padded out to a fixed column so sizes line up without
; a format routine.
print_name_col:
	call print_name
	call name_width
	ld a,#14
	sub b
	ret c
	ret z
	ld b,a
pnc_pad:
	ld a,#' '
	call conout
	djnz pnc_pad
	ret

msg_files:	.ascii " file(s)"
		.db 13,10,'$'
msg_nomatch:	.ascii "no match"
		.db 13,10,'$'
msg_cut:	.ascii "more matched than fit; copied the first "
		.db '$'

; Last in the image, so these reserve TPA and emit nothing.
pattern:	.ds 11
match_count:	.ds 1
match_over:	.ds 1
match_table:	.ds 11 * MAX_MATCH
