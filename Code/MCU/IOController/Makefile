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
    $(SRC_DIR)/handlers.c   \
    $(SRC_DIR)/controller_latch.c

FIRMWARE_HEX := $(BUILD_DIR)/$(TARGET).hex

# Records the DEFS used for the last build.  The firmware depends on it, so
# changing DEFS forces a rebuild instead of silently leaving a stale hex built
# with the previous tunables.
FLAGS_STAMP := $(BUILD_DIR)/.buildflags

# -gdwarf-3 emits DWARF debug info so build/$(TARGET).elf is source-debuggable
# in VS Code (mplab-core-da / SNAP), matching the MPLAB CMake build flags.
XC8FLAGS ?= -mcpu=$(DEVICE) -mdfp=$(DFP) -I$(INC_DIR) -gdwarf-3

# Extra -D defines, for sweeping tunables without editing headers. e.g.
#   make DEFS=-DEXTSYNC_TARGET_BYTE_US=16u     # 500 kbit/s
#   make DEFS="-DEXTSYNC_SPI_RX=0 -DEXTSYNC_SPI_TX=1"
DEFS ?=

.PHONY: all clean test size force

all: $(FIRMWARE_HEX)

$(BUILD_DIR):
	mkdir -p $@

$(FLAGS_STAMP): force | $(BUILD_DIR)
	@echo '$(DEFS)' | cmp -s - $@ || echo '$(DEFS)' > $@

$(FIRMWARE_HEX): $(FIRMWARE_SRCS) $(FLAGS_STAMP) | $(BUILD_DIR)
	$(XC8) $(XC8FLAGS) $(DEFS) $(FIRMWARE_SRCS) -o $(BUILD_DIR)/$(TARGET)

test:
	@echo "No host tests yet: firmware only."

size: $(FIRMWARE_HEX)
	@ls -lh "$(BUILD_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"/*
