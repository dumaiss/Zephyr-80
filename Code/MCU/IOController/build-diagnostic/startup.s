
	; Microchip MPLAB XC8 C Compiler V3.10
	; Copyright (C) 2025 Microchip Technology Inc.

	; Auto-generated runtime startup code for final link stage.

	;
	; Compiler options:
	;
	; -q --opt=none --chip=18f57q84 --dfp=/home/kitamura/Downloads/xc8 \
	; -Iinclude -Ithird_party/tinyusb/src --output=+elf:multilocs \
	; --stack=hybrid:512:0:0 -DIOC_DIAGNOSTIC_BUILD=1 src/main.c \
	; src/external_sync.c src/dispatch.c src/handlers.c \
	; src/controller_latch.c src/spi1_bus.c src/sd_card.c \
	; src/bulk_channel.c src/timebase.c src/sd_cache.c src/power.c \
	; src/ioc_hid.c third_party/tinyusb/src/tusb.c \
	; third_party/tinyusb/src/common/tusb_fifo.c \
	; third_party/tinyusb/src/host/usbh.c \
	; third_party/tinyusb/src/host/hub.c \
	; third_party/tinyusb/src/class/hid/hid_host.c \
	; third_party/tinyusb/src/portable/analog/max3421/hcd_max3421.c \
	; -oio_controller --objdir=build-diagnostic --outdir=build-diagnostic \
	; -L--fixupoverflow=error --std=c99 --rors --icl=auto --callgraph=none \
	; --warn=-3 --errformat=%f:%l:%c: error: (%n) %s \
	; --warnformat=%f:%l:%c: warning: (%n) %s \
	; --msgformat=%f:%l:%c: advisory: (%n) %s
	;


	processor	18F57Q84
	include "/home/kitamura/Downloads/xc8/pic/include/proc/18f57q84.cgen.inc"

	GLOBAL	_main,start
	FNROOT	_main

	pic18cxx	equ	1

	psect	const,class=CONST,delta=1,reloc=2,noexec
	psect	smallconst,class=SMALLCONST,delta=1,reloc=2,noexec
	psect	mediumconst,class=MEDIUMCONST,delta=1,reloc=2,noexec
	psect	rbss,class=COMRAM,space=1,noexec
	psect	bss,class=RAM,space=1,noexec
	psect	rdata,class=COMRAM,space=1,noexec
	psect	irdata,class=CODE,space=0,reloc=2,noexec
	psect	bss,class=RAM,space=1,noexec
	psect	data,class=RAM,space=1,noexec
	psect	idata,class=CODE,space=0,reloc=2,noexec
	psect	nvrram,class=COMRAM,space=1,noexec
	psect	nvbit,class=COMRAM,bit,space=1,noexec
	psect	temp,ovrld,class=COMRAM,space=1,noexec
	psect	struct,ovrld,class=COMRAM,space=1,noexec
	psect	rbit,class=COMRAM,bit,space=1,noexec
	psect	bigbss,class=BIGRAM,space=1,noexec
	psect	bigdata,class=BIGRAM,space=1,noexec
	psect	ibigdata,class=CODE,space=0,reloc=2,noexec
	psect	farbss,class=FARRAM,space=0,reloc=2,delta=1,noexec
	psect	nvFARRAM,class=FARRAM,space=0,reloc=2,delta=1,noexec
	psect	fardata,class=FARRAM,space=0,reloc=2,delta=1,noexec
	psect	ifardata,class=CODE,space=0,reloc=2,delta=1,noexec

	psect	reset_vec,class=CODE,delta=1,reloc=2
	psect	powerup,class=CODE,delta=1,reloc=2
	psect	init,class=CODE,delta=1,reloc=2
	psect	text,class=CODE,delta=1,reloc=2
GLOBAL	intlevel0,intlevel1,intlevel2
intlevel0:
intlevel1:
intlevel2:
GLOBAL	intlevel3
intlevel3:
	psect	clrtext,class=CODE,delta=1,reloc=2

	psect	config,class=CONFIG,delta=1,space=4,noexec
	psect	idloc,class=IDLOC,delta=1,space=5,noexec
	psect	eeprom_data,class=EEDATA,delta=1,noexec
	PSECT	ramtop,class=RAM,noexec
	GLOBAL	__S1			; top of RAM usage
	GLOBAL	__ramtop
	GLOBAL	__LRAM,__HRAM
__ramtop:

	psect	reset_vec
reset_vec:
	; No powerup routine
	global start

; jump to start
	goto start
	GLOBAL __accesstop
__accesstop EQU 1376

; No heap to be allocated
	psect	heap,class=HEAP,space=7,noexec
	global ___heap_lo
	___heap_lo	equ	0
	global ___heap_hi
	___heap_hi	equ	0


;Initialize the stack pointer (FSR1)
	global stacklo, stackhi
	stacklo	equ	02302h
	stackhi	equ	02501h


	psect	stack,class=STACK,space=2,noexec
	global ___sp,___inthi_sp,___intlo_sp
___sp:
	global ___stack_lo
	___stack_lo:
	ds 512

	global ___stack_hi
	___stack_hi:
___inthi_sp:
; No data stack was needed for the high interrupt function

___intlo_sp:
; No data stack was needed for the low interrupt function



	psect	init
start:
	lfsr	1,___sp
	global start_initialization
	goto start_initialization	;jump to C runtime clear & initialization

psect comram,class=COMRAM,space=1
psect abs1,class=ABS1,space=1
psect bigram,class=BIGRAM,space=1
psect ram,class=RAM,space=1
psect bank5,class=BANK5,space=1
psect bank6,class=BANK6,space=1
psect bank7,class=BANK7,space=1
psect bank8,class=BANK8,space=1
psect bank9,class=BANK9,space=1
psect bank10,class=BANK10,space=1
psect bank11,class=BANK11,space=1
psect bank12,class=BANK12,space=1
psect bank13,class=BANK13,space=1
psect bank14,class=BANK14,space=1
psect bank15,class=BANK15,space=1
psect bank16,class=BANK16,space=1
psect bank17,class=BANK17,space=1
psect bank18,class=BANK18,space=1
psect bank19,class=BANK19,space=1
psect bank20,class=BANK20,space=1
psect bank21,class=BANK21,space=1
psect bank22,class=BANK22,space=1
psect bank23,class=BANK23,space=1
psect bank24,class=BANK24,space=1
psect bank25,class=BANK25,space=1
psect bank26,class=BANK26,space=1
psect bank27,class=BANK27,space=1
psect bank28,class=BANK28,space=1
psect bank29,class=BANK29,space=1
psect bank30,class=BANK30,space=1
psect bank31,class=BANK31,space=1
psect bank32,class=BANK32,space=1
psect bank33,class=BANK33,space=1
psect bank34,class=BANK34,space=1
psect bank35,class=BANK35,space=1
psect bank36,class=BANK36,space=1
psect bank37,class=BANK37,space=1
psect bank38,class=BANK38,space=1
psect bank39,class=BANK39,space=1
psect bank40,class=BANK40,space=1
psect bank41,class=BANK41,space=1
psect bank42,class=BANK42,space=1
psect bank43,class=BANK43,space=1
psect bank44,class=BANK44,space=1
psect bank45,class=BANK45,space=1
psect bank46,class=BANK46,space=1
psect bank47,class=BANK47,space=1
psect bank48,class=BANK48,space=1
psect bank49,class=BANK49,space=1
psect bank50,class=BANK50,space=1
psect bank51,class=BANK51,space=1
psect bank52,class=BANK52,space=1
psect bank53,class=BANK53,space=1
psect bank54,class=BANK54,space=1
psect sfr,class=SFR,space=1
psect bigsfr,class=BIGSFR,space=1


	end	start
