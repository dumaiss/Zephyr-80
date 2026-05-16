BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools

Z80ASM ?= z80asm
OBJCOPY ?= objcopy
PYTHON ?= python3
Z80ASMFLAGS ?=
HEX_ORIGIN ?= 8000h
HEX_OFFSET ?= 0x8000

SWAPBITS := $(TOOLS_DIR)/swapbits.py

ASM_SRCS := $(wildcard $(SRC_DIR)/*.asm)
TARGETS := $(basename $(notdir $(ASM_SRCS)))

RAW_BIN_DIR := $(BUILD_DIR)/raw
HEX_SRC_DIR := $(BUILD_DIR)/hex-src
HEX_RAW_DIR := $(BUILD_DIR)/hex-raw

BINS := $(addprefix $(BUILD_DIR)/,$(addsuffix .bin,$(TARGETS)))
HEXS := $(addprefix $(BUILD_DIR)/,$(addsuffix .hex,$(TARGETS)))

.PHONY: all clean bins hex

all: bins hex

bins: $(BINS)

hex: $(HEXS)

$(BUILD_DIR) $(RAW_BIN_DIR) $(HEX_SRC_DIR) $(HEX_RAW_DIR):
	mkdir -p $@

$(RAW_BIN_DIR)/%.bin: $(SRC_DIR)/%.asm | $(RAW_BIN_DIR)
	$(Z80ASM) $(Z80ASMFLAGS) -o $@ $<

$(BUILD_DIR)/%.bin: $(RAW_BIN_DIR)/%.bin $(SWAPBITS) | $(BUILD_DIR)
	$(PYTHON) $(SWAPBITS) $< $@

$(HEX_SRC_DIR)/%.asm: $(SRC_DIR)/%.asm | $(HEX_SRC_DIR)
	awk 'BEGIN { fixed = 0 } /^[[:space:]]*[Oo][Rr][Gg][[:space:]]/ && !fixed { print "                org $(HEX_ORIGIN)"; fixed = 1; next } { print }' $< > $@

$(HEX_RAW_DIR)/%.bin: $(HEX_SRC_DIR)/%.asm | $(HEX_RAW_DIR)
	$(Z80ASM) $(Z80ASMFLAGS) -o $@ $<

$(BUILD_DIR)/%.hex: $(HEX_RAW_DIR)/%.bin | $(BUILD_DIR)
	$(OBJCOPY) -I binary -O ihex --change-addresses $(HEX_OFFSET) $< $@
	sed -i '/^:04000003/d;/^:04000005/d' $@

clean:
	rm -rf "$(BUILD_DIR)"/*
