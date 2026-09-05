DEVICE ?= PIC18F57Q84
TARGET := io_controller

BUILD_DIR := build
SRC_DIR   := src
INC_DIR   := include
TINYUSB_DIR := third_party/tinyusb

XC8_DIR ?= /opt/microchip/xc8/v3.10/bin
XC8     ?= $(XC8_DIR)/xc8-cc
DFP     ?= /home/kitamura/Downloads/xc8

FIRMWARE_SRCS := \
    $(SRC_DIR)/main.c       \
    $(SRC_DIR)/external_sync.c \
    $(SRC_DIR)/dispatch.c   \
    $(SRC_DIR)/handlers.c   \
    $(SRC_DIR)/controller_latch.c \
    $(SRC_DIR)/spi1_bus.c \
    $(SRC_DIR)/sd_card.c \
    $(SRC_DIR)/bulk_channel.c \
    $(SRC_DIR)/timebase.c \
    $(SRC_DIR)/sd_cache.c \
    $(SRC_DIR)/power.c \
    $(SRC_DIR)/ioc_hid.c \
    $(TINYUSB_DIR)/src/tusb.c \
    $(TINYUSB_DIR)/src/common/tusb_fifo.c \
    $(TINYUSB_DIR)/src/host/usbh.c \
    $(TINYUSB_DIR)/src/host/hub.c \
    $(TINYUSB_DIR)/src/class/hid/hid_host.c \
    $(TINYUSB_DIR)/src/portable/analog/max3421/hcd_max3421.c

FIRMWARE_HEX := $(BUILD_DIR)/$(TARGET).hex

# Records the DEFS used for the last build.  The firmware depends on it, so
# changing DEFS forces a rebuild instead of silently leaving a stale hex built
# with the previous tunables.
FLAGS_STAMP := $(BUILD_DIR)/.buildflags

# -gdwarf-3 emits DWARF debug info so build/$(TARGET).elf is source-debuggable
# in VS Code (mplab-core-da / SNAP), matching the MPLAB CMake build flags.
XC8FLAGS ?= -mcpu=$(DEVICE) -mdfp=$(DFP) -I$(INC_DIR) \
    -I$(TINYUSB_DIR)/src -gdwarf-3 -mstack=hybrid:512:0:0

# Extra -D defines, for sweeping tunables without editing headers. e.g.
#   make DEFS=-DEXTSYNC_TARGET_BYTE_US=16u     # 500 kbit/s
#   make DEFS=-DEXTSYNC_SPI_BAUD=63u          # SCK 500 kHz
# Firmware build profile.
#
#   normal      what the machine runs (default)
#   diagnostic  adds the profiler, the physical edge counters, the synthetic
#               bulk ramp and the raw block commands
#
# Inclusion only: transport behaviour, timing and error handling are identical,
# so a fault seen on one profile is a fault on the other.
IOC_PROFILE ?= normal
ifeq ($(IOC_PROFILE),diagnostic)
PROFILE_DEFS := -DIOC_DIAGNOSTIC_BUILD=1
else ifeq ($(IOC_PROFILE),normal)
PROFILE_DEFS :=
else
$(error Unsupported IOC_PROFILE='$(IOC_PROFILE)'; choose normal or diagnostic)
endif

DEFS ?=

.PHONY: all clean test size force check-xc8-patches

# The TinyUSB XC8 correctness workarounds are checked before anything is built.
# Seven of them share the usbh_xc8_* prefix with 68 trace variables, so a
# cleanup or a vendor refresh can remove them without breaking the build -- it
# breaks enumeration on hardware instead.  See docs/XC8-PATCHES.md.
check-xc8-patches:
	@./tools/check_xc8_patches.sh

all: check-xc8-patches $(FIRMWARE_HEX)

$(BUILD_DIR):
	mkdir -p $@

$(FLAGS_STAMP): force | $(BUILD_DIR)
	@echo '$(PROFILE_DEFS) $(DEFS)' | cmp -s - $@ || echo '$(PROFILE_DEFS) $(DEFS)' > $@

$(FIRMWARE_HEX): $(FIRMWARE_SRCS) $(FLAGS_STAMP) | $(BUILD_DIR)
	$(XC8) $(XC8FLAGS) $(PROFILE_DEFS) $(DEFS) $(FIRMWARE_SRCS) -o $(BUILD_DIR)/$(TARGET)

test:
	@echo "No host tests yet: firmware only."

size: $(FIRMWARE_HEX)
	@ls -lh "$(BUILD_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"/*
