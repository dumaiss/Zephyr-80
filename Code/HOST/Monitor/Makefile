TARGET := zephyr80_monitor

BUILD_DIR := build
SRC_DIR := src

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
MAKEBIN ?= makebin
DD ?= dd

ASFLAGS ?= -o -l -s
LDFLAGS ?= -i
LOAD_OFFSET ?= 256

SRC := $(SRC_DIR)/monitor/zephyr80_monitor.asm
INC := $(wildcard $(SRC_DIR)/monitor/*.inc)
REL := $(BUILD_DIR)/$(TARGET).rel
IHX := $(BUILD_DIR)/$(TARGET).ihx
PADDED_BIN := $(BUILD_DIR)/$(TARGET).padded.bin
BIN := $(BUILD_DIR)/$(TARGET).bin

.PHONY: all clean

all: $(BIN)

$(BUILD_DIR):
	mkdir -p $@

$(REL): $(SRC) $(INC) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $@ $<

$(IHX): $(REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(PADDED_BIN): $(IHX)
	$(MAKEBIN) $< $@

$(BIN): $(PADDED_BIN)
	$(DD) if=$< of=$@ bs=$(LOAD_OFFSET) skip=1 status=none

clean:
	rm -rf "$(BUILD_DIR)"/*
