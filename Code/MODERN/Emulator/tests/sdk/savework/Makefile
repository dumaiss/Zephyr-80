# savework: the save-restore workload, built with the standalone KonaOS SDK
# (KOS_SDK_ROOT names the unpacked SDK; tests/devtools.py sets it).

KOS_SDK_ROOT ?= ../kos-sdk
include $(KOS_SDK_ROOT)/mk/kos.mk

$(eval $(call exe_program,savework,.,main.c,STACK=512))

.DEFAULT_GOAL := all
all: savework
