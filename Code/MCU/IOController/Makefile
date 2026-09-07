DEVICE ?= PIC18F57Q84
TARGET := io_controller

BUILD_DIR := build
SRC_DIR   := src
INC_DIR   := include
TINYUSB_DIR := third_party/tinyusb

XC8_DIR ?= /opt/microchip/xc8/v3.10/bin
XC8     ?= $(XC8_DIR)/xc8-cc
DFP     ?= /home/kitamura/Downloads/xc8

# An empty $(XC8) does NOT fail loudly, which is why this guard exists.
#
# The compile recipe below begins with $(XC8).  If that expands to nothing the
# line starts with `-mcpu=...`, and GNU make strips a leading `-` from a recipe
# line as its IGNORE-ERRORS modifier.  Make then runs `mcpu=...` as the command,
# the shell reports "not found", make reports "(ignored)", and the build exits 0
# having produced no hex at all -- leaving a stale build/ that looks like
# success.  These three variables were once lost to an over-broad edit and the
# breakage survived a commit for exactly that reason.
ifeq ($(strip $(XC8)),)
$(error XC8 is empty -- the compiler variable was lost.  See XC8_DIR above.)
endif

# FatFs, vendored under third_party/fatfs.  Build with IOC_FATFS=1 to link it.
#
# ON: confirmed working on hardware.  It was believed unlinkable here for
# eleven builds; that was a confound -- every FatFs build also carried the
# vol_name() pointer defect -- and the retest passed.  See the correction in
# ../../HOST/CPM2.2/docs/ioc-fat32-images-and-shared-fs.md.
#
# FatFs serves /SHARED/ ONLY.  Image resolution stays on src/fatmap.c even
# though FatFs could do it, and that split is deliberate: mounting a CP/M volume
# is boot-critical, and keeping it on 500 lines with an analysable call graph
# means a fault in the 7,000-line library costs a user-space tool rather than
# the machine's ability to boot.
FATFS_DIR := third_party/fatfs

IOC_FATFS ?= 1
ifeq ($(IOC_FATFS),1)
FATFS_SRCS := \
    $(SRC_DIR)/sdfs.c \
    $(SRC_DIR)/diskio.c \
    $(SRC_DIR)/fs_share.c \
    $(FATFS_DIR)/ff.c
FATFS_DEFS := -DIOC_FS_COMMANDS=1 -I$(FATFS_DIR)
else
FATFS_SRCS :=
FATFS_DEFS :=
endif

# Historical note, kept because it cost twelve builds to settle.
#
# FatFs was believed unlinkable here.  It is not: the bisect that produced that
# conclusion gated the volume handlers and the filesystem handlers behind ONE
# flag, so every build that linked ff.c also linked a defect in volume.c -- a
# function returning a pointer that might address either RAM or program memory,
# which reset-looped the PIC from code that never ran.  Fixing that, FatFs links
# and runs.  Across eleven builds the pointer defect predicted the outcome
# 11/11; ff.c predicted 2/11.
#
# The lesson is about the bisect, not the library: one flag must gate one
# variable.  Full table in
# ../../HOST/CPM2.2/docs/ioc-fat32-images-and-shared-fs.md.

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
    $(SRC_DIR)/boot_guard.c \
    $(SRC_DIR)/ioc_status.c \
    $(SRC_DIR)/fatmap.c \
    $(SRC_DIR)/volume.c \
    $(TINYUSB_DIR)/src/tusb.c \
    $(TINYUSB_DIR)/src/common/tusb_fifo.c \
    $(TINYUSB_DIR)/src/host/usbh.c \
    $(TINYUSB_DIR)/src/host/hub.c \
    $(TINYUSB_DIR)/src/class/hid/hid_host.c \
    $(TINYUSB_DIR)/src/portable/analog/max3421/hcd_max3421.c \
    $(FATFS_SRCS)

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

# `check-xc8-patches` is the first real target in this file, and GNU make takes
# the first real target as the default goal -- so a bare `make` ran the patch
# check, printed OK, exited 0 and built nothing.  Silently: no error, no hex,
# and a stale build/ left in place to make it look like it had worked.
.DEFAULT_GOAL := all

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
	$(XC8) $(XC8FLAGS) $(PROFILE_DEFS) $(FATFS_DEFS) $(DEFS) $(FIRMWARE_SRCS) -o $(BUILD_DIR)/$(TARGET)

test:
	@echo "No host tests yet: firmware only."

size: $(FIRMWARE_HEX)
	@ls -lh "$(BUILD_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"/*
