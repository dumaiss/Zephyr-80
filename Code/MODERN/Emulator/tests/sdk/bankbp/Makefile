# bankbp: the debug-symbols fixture, built with the standalone KonaOS SDK
# (KOS_SDK_ROOT names the unpacked SDK; tests/debug_symbols.py sets it).
#
# A placed program whose home zone (home.c) and far segment 1 (far.c) both
# start at 8000h: two physical banks behind one logical address.

KOS_SDK_ROOT ?= ../kos-sdk
include $(KOS_SDK_ROOT)/mk/kos.mk

$(eval $(call exe_program,bankbp,.,main.c home.c far.c,STACK=256,PLACE=home.c=home:far.c=far1))

.DEFAULT_GOAL := all
all: bankbp
