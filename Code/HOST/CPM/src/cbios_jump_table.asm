; CP/M 2.2-style CBIOS jump table.
;
; The entry order is fixed by the CP/M BIOS ABI. Each entry is a three-byte JP.

	.globl cbios_jump_table
	.globl boot,wboot,const,conin,conout
	.globl list,punch,reader,home,seldsk,settrk,setsec,setdma
	.globl read,write,listst,sectran

cbios_jump_table:
	jp boot
	jp wboot
	jp const
	jp conin
	jp conout
	jp list
	jp punch
	jp reader
	jp home
	jp seldsk
	jp settrk
	jp setsec
	jp setdma
	jp read
	jp write
	jp listst
	jp sectran

