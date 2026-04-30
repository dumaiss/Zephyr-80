TARGET := hello

BUILD_DIR := build
SRC_DIR := src

Z80ASM ?= z80asm
Z80ASMFLAGS ?=

SRC := $(SRC_DIR)/main.asm
BIN := $(BUILD_DIR)/$(TARGET).bin

.PHONY: all clean

all: $(BIN)

$(BUILD_DIR):
	mkdir -p $@

$(BIN): $(SRC) | $(BUILD_DIR)
	$(Z80ASM) $(Z80ASMFLAGS) -o $@ $<

clean:
	rm -rf "$(BUILD_DIR)"/*
