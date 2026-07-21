DEVICE ?= PIC18F57Q84
TARGET := io_controller

BUILD_DIR := build
SRC_DIR   := src
INC_DIR   := include

XC8_DIR ?= /opt/microchip/xc8/v3.10/bin
XC8     ?= $(XC8_DIR)/xc8-cc
DFP     ?= /home/kitamura/Downloads/xc8

FIRMWARE_SRCS := \
    $(SRC_DIR)/main.c       \
    $(SRC_DIR)/external_sync.c \
    $(SRC_DIR)/dispatch.c   \
    $(SRC_DIR)/handlers.c

FIRMWARE_HEX := $(BUILD_DIR)/$(TARGET).hex

# -gdwarf-3 emits DWARF debug info so build/$(TARGET).elf is source-debuggable
# in VS Code (mplab-core-da / SNAP), matching the MPLAB CMake build flags.
XC8FLAGS ?= -mcpu=$(DEVICE) -mdfp=$(DFP) -I$(INC_DIR) -gdwarf-3

.PHONY: all clean test size

all: $(FIRMWARE_HEX)

$(BUILD_DIR):
	mkdir -p $@

$(FIRMWARE_HEX): $(FIRMWARE_SRCS) | $(BUILD_DIR)
	$(XC8) $(XC8FLAGS) $^ -o $(BUILD_DIR)/$(TARGET)

test:
	@echo "No host tests yet: firmware only."

size: $(FIRMWARE_HEX)
	@ls -lh "$(BUILD_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"/*
