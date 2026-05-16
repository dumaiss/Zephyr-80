TARGET := monitor

BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
MAKEBIN ?= makebin
PYTHON ?= python3

# Leave ROM_SIZE empty for a packed binary. Example: make ROM_SIZE=32768
ROM_SIZE ?=
ASFLAGS ?= -o -l -s
LDFLAGS ?= -i

SRC := $(SRC_DIR)/monitor/zephyr80_monitor.asm
INC := $(wildcard $(SRC_DIR)/monitor/*.inc)
REL := $(BUILD_DIR)/$(TARGET).rel
IHX := $(BUILD_DIR)/$(TARGET).ihx
RAW_BIN := $(BUILD_DIR)/$(TARGET).raw.bin
BIN := $(BUILD_DIR)/$(TARGET).bin
SWAPBITS := $(TOOLS_DIR)/swapbits.py

ifeq ($(strip $(ROM_SIZE)),)
MAKEBIN_FLAGS := -p
else
MAKEBIN_FLAGS := -s $(ROM_SIZE)
endif

.PHONY: all clean

all: $(BIN)

$(BUILD_DIR):
	mkdir -p $@

$(REL): $(SRC) $(INC) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $@ $<

$(IHX): $(REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(RAW_BIN): $(IHX)
	$(MAKEBIN) $(MAKEBIN_FLAGS) $< $@

$(BIN): $(RAW_BIN) $(SWAPBITS)
	$(PYTHON) $(SWAPBITS) $< $@

clean:
	rm -rf "$(BUILD_DIR)"/*
