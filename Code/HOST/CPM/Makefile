TARGET := cbios

BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
MAKEBIN ?= makebin
PYTHON ?= python3

ASFLAGS ?= -o -l -s
LDFLAGS ?= -i

# The reset vector lives at 0000h and the CBIOS/high boot path lives in the
# E000h-FFFFh common area, so make a full-size ROM image and apply the
# CPU-board data-bit fix.
ROM_SIZE ?= 65536
MAKEBIN_FLAGS ?= -s $(ROM_SIZE)
SWAPBITS ?= tools/swapbits.py

SRC := $(SRC_DIR)/cbios.asm
ASM_PARTS := $(wildcard $(SRC_DIR)/*.asm)
INC_PARTS := $(wildcard $(SRC_DIR)/*.inc)

REL := $(BUILD_DIR)/$(TARGET).rel
IHX := $(BUILD_DIR)/$(TARGET).ihx
RAW_BIN := $(BUILD_DIR)/$(TARGET).raw.bin
BIN := $(BUILD_DIR)/$(TARGET).bin

.PHONY: all clean dirs cbios

all: cbios

cbios: $(IHX) $(RAW_BIN) $(BIN)

dirs: $(BUILD_DIR)

$(BUILD_DIR):
	mkdir -p $@

$(REL): $(SRC) $(ASM_PARTS) $(INC_PARTS) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $@ $<

$(IHX): $(REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(RAW_BIN): $(IHX)
	$(MAKEBIN) $(MAKEBIN_FLAGS) $< $@

$(BIN): $(RAW_BIN) $(SWAPBITS)
	$(PYTHON) $(SWAPBITS) $< $@

clean:
	rm -rf "$(BUILD_DIR)"/*
