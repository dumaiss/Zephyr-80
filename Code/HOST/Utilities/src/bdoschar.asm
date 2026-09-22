; BDOSCHAR.COM -- capture the observable ZSDOS SEARCH FIRST/NEXT contract.
;
; Usage: BDOSCHAR [d:]pattern [d:]output.txt
;        BDOSCHAR [d:]SETUP
;
; The CCP supplies the argument as FCB 1 at 005Ch.  This utility copies only
; its drive and packed 8.3 pattern into a clean private FCB, installs a private
; DMA buffer, and writes machine-readable hexadecimal snapshots to the exact
; output FCB supplied as the second argument.  Every search call records:
;
;   return A, all 36 caller-FCB bytes, all 128 DMA bytes, and (on success) the
;   selected 32-byte directory slot.
;
; DMA is filled with A5h before each call so untouched/stale bytes are visible.
; A second pass changes every byte of the original search FCB to CCh between
; SEARCH FIRST and SEARCH NEXT.  This establishes whether continuation depends
; on the caller retaining that FCB.  File output is buffered into CP/M
; 128-byte records and padded with 1Ah.  The default DMA at 0080h is restored
; on every exit.  An existing output file is replaced; no searched file is
; changed unless the caller deliberately names it as the output file.
;
; Put the output on a drive outside the search, for example:
;
;   BDOSCHAR B:*.* C:BCHAR00.TXT
;
; That prevents the growing report file from becoming a wildcard result.
; SETUP creates the generated fixtures through BDOS and replaces only their
; reserved names; see bdoschar_fixtures.inc.

	.module bdoschar
	.area CODE (ABS)
	.org 0x0100

BDOS            = 0x0005
FCB1            = 0x005c
FCB2            = 0x006c
DEFAULT_DMA     = 0x0080

BDOS_CONOUT     = 2
BDOS_PRINT      = 9
BDOS_CLOSE      = 16
BDOS_GETDRV     = 25
BDOS_SETDMA     = 26
BDOS_USER       = 32
BDOS_SFIRST     = 17
BDOS_SNEXT      = 18
BDOS_DELETE     = 19
BDOS_WRITESEQ   = 21
BDOS_MAKE       = 22
BDOS_SETATTR    = 30

FCB_BYTES       = 36
DMA_BYTES       = 128
DIR_ENTRY_BYTES = 32
SEARCH_CAP      = 64

start:
	ld (entry_sp),sp
	ld sp,#stack_top
	call main
	; CP/M's conventional default DMA must survive this diagnostic.
	ld de,#DEFAULT_DMA
	ld c,#BDOS_SETDMA
	call BDOS
	ld sp,(entry_sp)
	ret

main:
	xor a
	ld (output_open),a
	ld (output_error),a
	ld (output_count),a
	call make_clean_fcb
	ld c,#BDOS_GETDRV
	call BDOS
	ld (current_drive),a
	ld e,#0xff
	ld c,#BDOS_USER
	call BDOS
	ld (current_user),a
	call is_setup_request
	jp z,run_setup
	call fcb_has_name
	jp z,show_usage
	call make_output_fcb
	call output_fcb_valid
	jp z,show_usage

	ld hl,#search_fcb
	ld de,#initial_fcb
	ld bc,#FCB_BYTES
	ldir

	call open_output
	jr nz,show_open_error

	ld de,#msg_banner
	call puts

	ld de,#msg_context
	call puts
	ld a,(current_drive)
	call print_hex_byte
	ld de,#msg_user
	call puts
	ld a,(current_user)
	call print_hex_byte
	call crlf

	ld de,#msg_input_fcb
	call puts
	ld hl,#initial_fcb
	ld b,#FCB_BYTES
	call print_block
	call crlf
	ld de,#msg_output_fcb
	call puts
	ld hl,#initial_output_fcb
	ld b,#12
	call print_block
	call crlf

	ld de,#msg_normal
	call puts
	call run_normal_search

	ld de,#msg_mutation
	call puts
	call run_mutation_search

	call finish_output
	ld a,(output_error)
	or a
	ld de,#msg_written
	jr z,show_final
	ld de,#msg_write_error
show_final:
	jp console_puts

show_open_error:
	ld de,#msg_open_error
	jp console_puts

show_usage:
	ld de,#msg_usage
	jp console_puts

run_setup:
	ld de,#msg_setup_start
	call console_puts
	call setup_fixtures
	ld a,(setup_error)
	or a
	ld de,#msg_setup_ok
	jr z,show_setup_result
	ld de,#msg_setup_error
show_setup_result:
	call console_puts
	ld a,(setup_error)
	or a
	ret z
	ld de,#msg_setup_user
	call console_puts
	ld a,(setup_fail_user)
	call console_print_hex_byte
	ld de,#msg_setup_rc
	call console_puts
	ld a,(setup_fail_code)
	call console_print_hex_byte
	ld de,#msg_crlf
	jp console_puts

; Z only when the first FCB is exactly [d:]SETUP with a blank extension.
is_setup_request:
	ld hl,#search_fcb + 1
	ld de,#setup_name
	ld b,#11
isr_loop:
	ld a,(de)
	cp (hl)
	ret nz
	inc de
	inc hl
	djnz isr_loop
	xor a
	ret

; Copy the exact output name from CCP FCB 2 and clear its state fields.
make_output_fcb:
	ld hl,#FCB2
	ld de,#output_fcb
	ld bc,#12
	ldir
	xor a
	ld b,#24
mof_zero:
	ld (de),a
	inc de
	djnz mof_zero
	ld hl,#output_fcb
	ld de,#initial_output_fcb
	ld bc,#FCB_BYTES
	ldir
	ret

; NZ for a nonblank exact output name; Z rejects blanks and wildcards.
output_fcb_valid:
	ld hl,#output_fcb + 1
	ld b,#11
	ld c,#0
ofv_loop:
	ld a,(hl)
	cp #0x3f			; '?' would make DELETE destructive
	jr z,ofv_bad
	cp #0x20
	jr z,ofv_next
	ld c,#1
ofv_next:
	inc hl
	djnz ofv_loop
	ld a,c
	or a
	ret
ofv_bad:
	xor a
	ret

restore_output_fcb:
	ld hl,#initial_output_fcb
	ld de,#output_fcb
	ld bc,#FCB_BYTES
	ldir
	ret

; Replace the named report file, then initialize the record buffer.
; Out: Z on success, NZ on failure. Clobbers AF/BC/DE/HL.
open_output:
	ld de,#output_fcb
	ld c,#BDOS_DELETE
	call BDOS			; absent is normal
	call restore_output_fcb
	ld de,#output_fcb
	ld c,#BDOS_MAKE
	call BDOS
	cp #0xff
	jr z,oo_fail
	ld a,#1
	ld (output_open),a
	ld hl,#output_buffer
	ld (output_ptr),hl
	xor a
	ld (output_count),a
	ld (output_error),a
	ret
oo_fail:
	ld a,#0xff
	or a
	ret

; Copy drive + packed 8.3 pattern from CCP FCB 1 and clear all state fields.
make_clean_fcb:
	ld hl,#FCB1
	ld de,#search_fcb
	ld bc,#12
	ldir
	xor a
	ld b,#24
mcf_zero:
	ld (de),a
	inc de
	djnz mcf_zero
	ret

; Z when all eleven packed name bytes are spaces.
fcb_has_name:
	ld hl,#search_fcb + 1
	ld b,#11
fhn_loop:
	ld a,(hl)
	cp #0x20
	jr nz,fhn_yes
	inc hl
	djnz fhn_loop
	xor a
	ret
fhn_yes:
	ld a,#0xff
	or a
	ret

restore_fcb:
	ld hl,#initial_fcb
	ld de,#search_fcb
	ld bc,#FCB_BYTES
	ldir
	ret

; Create every generated fixture through the running BDOS.  This is a setup
; operation on the drive encoded in the SETUP FCB (zero means current drive).
; Existing files with these reserved names are replaced in their listed USER.
setup_fixtures:
	xor a
	ld (setup_error),a
	ld (fixture_count),a
	ld a,(search_fcb)
	ld (fixture_drive),a

	; Deterministic record payload.  The first two bytes are replaced with the
	; remaining-record count before each sequential write.
	ld hl,#fixture_record
	ld b,#DMA_BYTES
	ld a,#0xe5
sf_fill_record:
	ld (hl),a
	inc hl
	djnz sf_fill_record

	ld hl,#bdoschar_fixture_table
sf_next:
	ld a,(hl)
	cp #0xff
	jp z,sf_done
	ld (fixture_user),a
	xor a
	ld (fixture_open),a
	inc hl
	ld a,(hl)
	ld (fixture_attrs),a
	inc hl
	ld e,(hl)
	inc hl
	ld d,(hl)
	inc hl
	ld (fixture_records),de
	ld de,#fixture_fcb + 1
	ld bc,#11
	ldir
	ld (fixture_next),hl

	ld a,(fixture_drive)
	ld (fixture_fcb),a
	xor a
	ld de,#fixture_fcb + 12
	ld b,#24
sf_zero_fcb:
	ld (de),a
	inc de
	djnz sf_zero_fcb
	call save_fixture_fcb

	ld a,(fixture_user)
	ld e,a
	ld c,#BDOS_USER
	call BDOS

	; Clear old attributes first so a previous read-only fixture can be deleted.
	call restore_fixture_fcb
	ld de,#fixture_fcb
	ld c,#BDOS_SETATTR
	call BDOS
	call restore_fixture_fcb
	ld de,#fixture_fcb
	ld c,#BDOS_DELETE
	call BDOS			; absent is normal

	call restore_fixture_fcb
	ld de,#fixture_fcb
	ld c,#BDOS_MAKE
	call BDOS
	cp #0xff
	jp z,sf_fail
	ld a,#1
	ld (fixture_open),a

	ld de,#fixture_record
	ld c,#BDOS_SETDMA
	call BDOS
	ld hl,(fixture_records)
	ld (fixture_remaining),hl
sf_write_loop:
	ld hl,(fixture_remaining)
	ld a,h
	or l
	jr z,sf_close
	ld (fixture_record),hl
	ld de,#fixture_fcb
	ld c,#BDOS_WRITESEQ
	call BDOS
	or a
	jp nz,sf_fail
	ld hl,(fixture_remaining)
	dec hl
	ld (fixture_remaining),hl
	jr sf_write_loop

sf_close:
	ld de,#fixture_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	cp #0xff
	jp z,sf_fail
	xor a
	ld (fixture_open),a

	ld a,(fixture_attrs)
	or a
	jr z,sf_created
	call restore_fixture_fcb
	ld a,(fixture_attrs)
	and #BDOSCHAR_ATTR_RO
	jr z,sf_no_ro
	ld a,(fixture_fcb + 9)
	or #0x80
	ld (fixture_fcb + 9),a
sf_no_ro:
	ld a,(fixture_attrs)
	and #BDOSCHAR_ATTR_SYS
	jr z,sf_no_sys
	ld a,(fixture_fcb + 10)
	or #0x80
	ld (fixture_fcb + 10),a
sf_no_sys:
	ld a,(fixture_attrs)
	and #BDOSCHAR_ATTR_ARC
	jr z,sf_set_attrs
	ld a,(fixture_fcb + 11)
	or #0x80
	ld (fixture_fcb + 11),a
sf_set_attrs:
	ld de,#fixture_fcb
	ld c,#BDOS_SETATTR
	call BDOS
	cp #0xff
	jp z,sf_fail

sf_created:
	ld a,(fixture_count)
	inc a
	ld (fixture_count),a
	ld hl,(fixture_next)
	jp sf_next

sf_fail:
	ld (setup_fail_code),a
	ld a,(fixture_user)
	ld (setup_fail_user),a
	ld a,(fixture_open)
	or a
	jr z,sf_fail_mark
	ld de,#fixture_fcb
	ld c,#BDOS_CLOSE
	call BDOS
sf_fail_mark:
	ld a,#0xff
	ld (setup_error),a
sf_done:
	; USER is global ZSDOS state: restore exactly what the utility found.
	ld a,(current_user)
	ld e,a
	ld c,#BDOS_USER
	call BDOS
	ret

save_fixture_fcb:
	ld hl,#fixture_fcb
	ld de,#fixture_fcb_template
	ld bc,#FCB_BYTES
	ldir
	ret

restore_fixture_fcb:
	ld hl,#fixture_fcb_template
	ld de,#fixture_fcb
	ld bc,#FCB_BYTES
	ldir
	ret

prefill_dma:
	ld hl,#dma_buffer
	ld b,#DMA_BYTES
	ld a,#0xa5
pfd_loop:
	ld (hl),a
	inc hl
	djnz pfd_loop
	ld de,#dma_buffer
	ld c,#BDOS_SETDMA
	jp BDOS

run_normal_search:
	call restore_fcb
	xor a
	ld (call_index),a
	ld (operation),a		; 0 = SEARCH FIRST
rns_call:
	call prefill_dma
	ld de,#search_fcb
	ld a,(operation)
	or a
	ld c,#BDOS_SFIRST
	jr z,rns_bdos
	ld c,#BDOS_SNEXT
rns_bdos:
	call BDOS
	ld (search_result),a
	call dump_call
	ld a,(search_result)
	cp #0xff
	ret z
	ld a,(call_index)
	inc a
	ld (call_index),a
	cp #SEARCH_CAP
	jr nc,rns_capped
	ld a,#1
	ld (operation),a
	jr rns_call
rns_capped:
	ld de,#msg_capped
	jp puts

run_mutation_search:
	call restore_fcb
	xor a
	ld (call_index),a
	ld (operation),a
	call prefill_dma
	ld de,#search_fcb
	ld c,#BDOS_SFIRST
	call BDOS
	ld (search_result),a
	call dump_call
	ld a,(search_result)
	cp #0xff
	ret z

	ld hl,#search_fcb
	ld b,#FCB_BYTES
	ld a,#0xcc
rms_poison:
	ld (hl),a
	inc hl
	djnz rms_poison
	ld de,#msg_changed_fcb
	call puts
	ld hl,#search_fcb
	ld b,#FCB_BYTES
	call print_block
	call crlf

	ld a,#1
	ld (call_index),a
	ld (operation),a
	call prefill_dma
	ld de,#search_fcb
	ld c,#BDOS_SNEXT
	call BDOS
	ld (search_result),a
	jp dump_call

; One complete, self-delimiting observation.
dump_call:
	ld de,#msg_call
	call puts
	ld a,(operation)
	or a
	ld a,#0x46			; 'F'
	jr z,dc_op
	ld a,#0x4e			; 'N'
dc_op:
	call putc
	ld de,#msg_index
	call puts
	ld a,(call_index)
	call print_hex_byte
	ld de,#msg_result
	call puts
	ld a,(search_result)
	call print_hex_byte
	call crlf

	ld de,#msg_fcb
	call puts
	ld hl,#search_fcb
	ld b,#FCB_BYTES
	call print_block
	call crlf

	ld de,#msg_dma
	call puts
	ld hl,#dma_buffer
	ld b,#DMA_BYTES
	call print_block
	call crlf

	ld a,(search_result)
	cp #4
	ret nc
	ld de,#msg_slot
	call puts
	ld a,(search_result)
	call print_hex_byte
	ld de,#msg_data
	call puts
	ld a,(search_result)
	; slot offset = return value * 32
	rlca
	rlca
	rlca
	rlca
	rlca
	ld e,a
	ld d,#0
	ld hl,#dma_buffer
	add hl,de
	ld b,#DIR_ENTRY_BYTES
	call print_block
	call crlf
	ret

print_block:
pb_loop:
	ld a,(hl)
	call print_hex_byte
	inc hl
	djnz pb_loop
	ret

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
	jr c,phn_out
	add a,#0x07
phn_out:
	jp putc

putc:
	ld (output_char),a
	push bc
	push de
	push hl
	ld a,(output_error)
	or a
	jr nz,putc_done
	ld hl,(output_ptr)
	ld a,(output_char)
	ld (hl),a
	inc hl
	ld (output_ptr),hl
	ld a,(output_count)
	inc a
	ld (output_count),a
	cp #DMA_BYTES
	call z,write_output_record
putc_done:
	pop hl
	pop de
	pop bc
	ld a,(output_char)
	ret

puts:
puts_loop:
	ld a,(de)
	cp #'$'
	ret z
	inc de
	call putc
	jr puts_loop

crlf:
	ld de,#msg_crlf
	jp puts

; Write the full 128-byte output buffer as one sequential CP/M record.
; Resets the buffer even on failure; output_error suppresses later bytes.
write_output_record:
	ld de,#output_buffer
	ld c,#BDOS_SETDMA
	call BDOS
	ld de,#output_fcb
	ld c,#BDOS_WRITESEQ
	call BDOS
	or a
	jr z,wor_reset
	ld (output_error),a
wor_reset:
	ld hl,#output_buffer
	ld (output_ptr),hl
	xor a
	ld (output_count),a
	ret

; Pad the final text record with CP/M EOF bytes, write it and close the file.
finish_output:
	ld a,(output_open)
	or a
	ret z
	ld a,(output_error)
	or a
	jr nz,fo_close
	ld a,(output_count)
	or a
	jr z,fo_close
fo_pad:
	ld hl,(output_ptr)
	ld (hl),#0x1a
	inc hl
	ld (output_ptr),hl
	ld a,(output_count)
	inc a
	ld (output_count),a
	cp #DMA_BYTES
	jr c,fo_pad
	call write_output_record
fo_close:
	ld de,#output_fcb
	ld c,#BDOS_CLOSE
	call BDOS
	cp #0xff
	jr nz,fo_closed
	ld a,(output_error)
	or a
	jr nz,fo_closed
	ld a,#0xff
	ld (output_error),a
fo_closed:
	xor a
	ld (output_open),a
	ret

console_puts:
	ld c,#BDOS_PRINT
	jp BDOS

console_print_hex_byte:
	push af
	rrca
	rrca
	rrca
	rrca
	and #0x0f
	call console_print_hex_nibble
	pop af
	and #0x0f
console_print_hex_nibble:
	add a,#0x30
	cp #0x3a
	jr c,cph_out
	add a,#0x07
cph_out:
	ld e,a
	ld c,#BDOS_CONOUT
	jp BDOS

	.include "bdoschar_fixtures.inc"

msg_banner:
	.ascii "BDOSCHAR V2"
	.db 13,10,'$'
msg_context:
	.ascii "CONTEXT DRIVE="
	.db '$'
msg_user:
	.ascii " USER="
	.db '$'
msg_input_fcb:
	.ascii "INPUT_FCB="
	.db '$'
msg_output_fcb:
	.ascii "OUTPUT_FCB="
	.db '$'
msg_normal:
	.ascii "PHASE=NORMAL"
	.db 13,10,'$'
msg_mutation:
	.ascii "PHASE=MUTATE_ORIGINAL"
	.db 13,10,'$'
msg_call:
	.ascii "CALL=S"
	.db '$'
msg_index:
	.ascii " INDEX="
	.db '$'
msg_result:
	.ascii " A="
	.db '$'
msg_fcb:
	.ascii "FCB="
	.db '$'
msg_dma:
	.ascii "DMA="
	.db '$'
msg_slot:
	.ascii "SLOT="
	.db '$'
msg_data:
	.ascii " DATA="
	.db '$'
msg_changed_fcb:
	.ascii "CHANGED_FCB="
	.db '$'
msg_capped:
	.ascii "STOP=CAP_40"
	.db 13,10,'$'
msg_usage:
	.ascii "Usage: BDOSCHAR [d:]pattern [d:]output.txt"
	.db 13,10
	.ascii "       BDOSCHAR [d:]SETUP"
	.db 13,10
	.ascii "Use another drive for wildcard captures."
	.db 13,10,'$'
msg_setup_start:
	.ascii "BDOSCHAR: creating generated fixtures..."
	.db 13,10,'$'
msg_setup_ok:
	.ascii "BDOSCHAR: generated fixtures created"
	.db 13,10,'$'
msg_setup_error:
	.ascii "BDOSCHAR: fixture setup failed"
	.db 13,10,'$'
msg_setup_user:
	.ascii "  USER="
	.db '$'
msg_setup_rc:
	.ascii " RC="
	.db '$'
msg_open_error:
	.ascii "BDOSCHAR: cannot replace output file"
	.db 13,10,'$'
msg_write_error:
	.ascii "BDOSCHAR: output write/close failed"
	.db 13,10,'$'
msg_written:
	.ascii "BDOSCHAR: report written"
	.db 13,10,'$'
msg_crlf:
	.db 13,10,'$'

setup_name:
	.ascii "SETUP      "

current_drive:	.ds 1
current_user:	.ds 1
call_index:	.ds 1
operation:	.ds 1
search_result:	.ds 1
initial_fcb:	.ds FCB_BYTES
search_fcb:	.ds FCB_BYTES
dma_buffer:	.ds DMA_BYTES
initial_output_fcb:	.ds FCB_BYTES
output_fcb:	.ds FCB_BYTES
output_buffer:	.ds DMA_BYTES
output_ptr:	.ds 2
output_count:	.ds 1
output_char:	.ds 1
output_open:	.ds 1
output_error:	.ds 1
setup_error:	.ds 1
setup_fail_user:	.ds 1
setup_fail_code:	.ds 1
fixture_drive:	.ds 1
fixture_user:	.ds 1
fixture_attrs:	.ds 1
fixture_open:	.ds 1
fixture_count:	.ds 1
fixture_records:	.ds 2
fixture_remaining:	.ds 2
fixture_next:	.ds 2
fixture_fcb:	.ds FCB_BYTES
fixture_fcb_template:	.ds FCB_BYTES
fixture_record:	.ds DMA_BYTES

entry_sp:	.ds 2
	.ds 256
stack_top:
