PYTHON ?= python3
SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
MAKEBIN ?= makebin

BUILD_DIR ?= build
TOOLS_DIR ?= tools
SRC_DIR ?= src
DOCS_DIR ?= docs

CPM22_SRC ?= cpm-2.2/src/cpm22.asm
CPMTOOLS_DISKDEF ?= images/diskdef

# Which backend is linked as drive A:.  Exactly one can be, because the BIOS
# common window has no room for two; they all .org at CBIOS_STORAGE_A_CODE_BASE
# and export the neutral stg_a_* entry points the dispatcher calls.
#
#   rom      read-only CP/M volume in flash pages 1-3 (default)
#   vdrip    proxy storage over the host serial link (the previous default)
#   ramdisk  banked RAM disk, retained but not maintained
STORAGE_A ?= rom
STORAGE_A_SRC ?= $(SRC_DIR)/cbios_storage_$(STORAGE_A).asm

ASFLAGS ?= -o -l -s
LDFLAGS ?= -i
ROM_SIZE ?= 65536
MAKEBIN_FLAGS ?= -s $(ROM_SIZE)

RUNTIME_SRCS ?= \
	$(SRC_DIR)/zephyr.asm \
	$(SRC_DIR)/platform_zephyr80.inc \
	$(SRC_DIR)/cbios_defs.inc \
	$(SRC_DIR)/boot_shadow_copy.asm \
	$(SRC_DIR)/cbios_boot.asm \
	$(SRC_DIR)/cbios_console.asm \
	$(SRC_DIR)/sio_core.asm \
	$(SRC_DIR)/vdrip_transport.asm \
	$(SRC_DIR)/cbios_bios_ext.asm \
	$(SRC_DIR)/cbios_iocall.asm \
	$(SRC_DIR)/cbios_ioc_command.asm \
	$(SRC_DIR)/cbios_hid_input.asm \
	$(SRC_DIR)/cbios_console_vdrip.asm \
	$(SRC_DIR)/cbios_storage.asm \
	$(STORAGE_A_SRC) \
	$(SRC_DIR)/cbios_storage_sd.asm \
	$(SRC_DIR)/cbios_bank_select.asm \
	$(SRC_DIR)/cbios_bank.asm

FIRMWARE_BIN ?= $(BUILD_DIR)/firmware.bin
SYMBOLS_FILE ?= $(BUILD_DIR)/firmware.map
CPM22_ASXXXX_SRC ?= $(BUILD_DIR)/cpm22_asxxxx.asm
FIRMWARE_SRC ?= $(BUILD_DIR)/zephyr_build.asm
FIRMWARE_REL ?= $(BUILD_DIR)/firmware.rel
FIRMWARE_IHX ?= $(BUILD_DIR)/firmware.ihx
FIRMWARE_LST ?= $(BUILD_DIR)/firmware.lst
FIRMWARE_SYM ?= $(BUILD_DIR)/firmware.sym

FINAL_IMAGE ?= $(BUILD_DIR)/zephyr80.bin
LAYOUT_MANIFEST ?= $(BUILD_DIR)/layout.manifest
LAYOUT_REPORT ?= $(BUILD_DIR)/layout-report.md
SYMBOL_MAP_DOC ?= $(DOCS_DIR)/symbol-map.md
MEMORY_MAP_DOC ?= $(DOCS_DIR)/memory-map.md

IMAGE_TOOL := $(TOOLS_DIR)/build_zephyr_image.py
ROM_DISK_TOOL := $(TOOLS_DIR)/build_rom_disk.py

# ROM disk inputs and outputs.  Only used when STORAGE_A=rom; a vdrip or ramdisk
# build embeds no payloads and produces the same 128 KiB image it always did.
PAYLOAD_CONFIG ?= images/banks.ini
ROM_DISK_PAGES ?= 3
ROM_DISK_IMAGE ?= $(BUILD_DIR)/romdisk.img
ROM_DISK_STAGE ?= images/ROM/0
ROM_DISK_CHUNKS := $(foreach n,$(shell seq 1 $(ROM_DISK_PAGES)),$(BUILD_DIR)/romdisk.p$(n).bin)

# The volume is assembled from binaries built by sibling projects.  Listing them
# here is only for change detection: build_rom_disk.py owns the real manifest and
# reports precisely which file is missing if one has not been built yet.
HELLOWORLD_BUILD ?= ../HelloWorld/build
MONITOR_BUILD ?= ../Monitor/build
ROM_DISK_INPUTS := $(wildcard $(HELLOWORLD_BUILD)/*.com) \
	$(wildcard $(MONITOR_BUILD)/zephyr80_monitor.bin) \
	$(wildcard images/A/0/*) $(wildcard images/A/1/*)

ifeq ($(STORAGE_A),rom)
PAYLOAD_ARGS := --payload-config "$(PAYLOAD_CONFIG)"
IMAGE_PREREQS := $(ROM_DISK_CHUNKS)
else
PAYLOAD_ARGS :=
IMAGE_PREREQS :=
endif
CPM22_CONVERT_TOOL := $(TOOLS_DIR)/convert_cpm22_asxxxx.py
MEMORY_DOC_TOOL := $(TOOLS_DIR)/generate_memory_docs.py

.PHONY: all image docs clean check-inputs runtime-sources-check rom-disk

all: image

image: $(FINAL_IMAGE) docs

docs: $(FINAL_IMAGE) $(FIRMWARE_LST) $(SYMBOLS_FILE) $(LAYOUT_MANIFEST) $(MEMORY_DOC_TOOL)
	$(PYTHON) $(MEMORY_DOC_TOOL) \
		--listing "$(FIRMWARE_LST)" \
		--map "$(SYMBOLS_FILE)" \
		--manifest "$(LAYOUT_MANIFEST)" \
		--firmware-bin "$(FIRMWARE_BIN)" \
		--final-image "$(FINAL_IMAGE)" \
		--symbol-map "$(SYMBOL_MAP_DOC)" \
		--memory-map "$(MEMORY_MAP_DOC)"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

check-inputs: $(BUILD_DIR) $(FIRMWARE_BIN) $(SYMBOLS_FILE)
	@test -f "$(CPM22_SRC)" || { echo "Missing CP/M source input: $(CPM22_SRC)"; exit 1; }
	@test -f "$(FIRMWARE_BIN)" || { echo "Missing firmware image: $(FIRMWARE_BIN)"; exit 1; }
	@test -f "$(SYMBOLS_FILE)" || { echo "Missing firmware symbol map: $(SYMBOLS_FILE)"; exit 1; }
	@test -f "$(CPMTOOLS_DISKDEF)" || { echo "Missing cpmtools disk definition: $(CPMTOOLS_DISKDEF)"; exit 1; }
	@test -f "$(SRC_DIR)/cbios_defs.inc" || { echo "Missing CBIOS definitions: $(SRC_DIR)/cbios_defs.inc"; exit 1; }
	@test -f "$(IMAGE_TOOL)" || { echo "Missing image tool: $(IMAGE_TOOL)"; exit 1; }
	@test -f "$(CPM22_CONVERT_TOOL)" || { echo "Missing CP/M conversion tool: $(CPM22_CONVERT_TOOL)"; exit 1; }
	@test -f "$(MEMORY_DOC_TOOL)" || { echo "Missing memory documentation tool: $(MEMORY_DOC_TOOL)"; exit 1; }

runtime-sources-check:
	@for src in $(RUNTIME_SRCS); do \
		test -f "$$src" || { echo "Missing runtime source: $$src"; exit 1; }; \
	done

$(CPM22_ASXXXX_SRC): $(CPM22_SRC) $(CPM22_CONVERT_TOOL) | $(BUILD_DIR)
	$(PYTHON) $(CPM22_CONVERT_TOOL) "$<" "$@"

$(FIRMWARE_SRC): $(SRC_DIR)/zephyr.asm $(CPM22_ASXXXX_SRC) Makefile | $(BUILD_DIR)
	sed \
		-e 's|\.include "../cpm-2.2/src/cpm22.asm"|.include "cpm22_asxxxx.asm"|' \
		-e 's|\.include "cbios_storage_vdrip.asm"|.include "cbios_storage_$(STORAGE_A).asm"|' \
		"$<" > "$@"

$(FIRMWARE_REL): $(FIRMWARE_SRC) $(RUNTIME_SRCS) $(CPM22_ASXXXX_SRC) $(CPM22_SRC) | $(BUILD_DIR)
	$(SDASZ80) -I$(SRC_DIR) -I$(BUILD_DIR) $(ASFLAGS) $@ $(FIRMWARE_SRC)

$(FIRMWARE_IHX): $(FIRMWARE_REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<
	$(PYTHON) $(TOOLS_DIR)/check_overlap.py "$@" --symbols "$(FIRMWARE_SYM)"

$(FIRMWARE_BIN): $(FIRMWARE_IHX)
	$(MAKEBIN) $(MAKEBIN_FLAGS) $< $@

$(SYMBOLS_FILE): $(FIRMWARE_REL)
	cp "$(FIRMWARE_SYM)" "$@"

# Build the drive A: volume and split it into one 48 KiB chunk per ROM page.
# Writes only inside $(BUILD_DIR) and the staging tree; it never touches
# images/zephyr80-vdrip2.cpm, which is a separate user-owned volume.
rom-disk: $(ROM_DISK_IMAGE)

$(ROM_DISK_IMAGE): $(ROM_DISK_TOOL) $(CPMTOOLS_DISKDEF) $(ROM_DISK_INPUTS) | $(BUILD_DIR)
	$(PYTHON) $(ROM_DISK_TOOL) \
		--diskdef "$(CPMTOOLS_DISKDEF)" \
		--staging-dir "$(ROM_DISK_STAGE)" \
		--hello-dir "$(HELLOWORLD_BUILD)" \
		--monitor-dir "$(MONITOR_BUILD)" \
		--build-dir "$(BUILD_DIR)" \
		--image "$(ROM_DISK_IMAGE)" \
		--page-count $(ROM_DISK_PAGES)

# Produced by the same run as the image above; no recipe of their own.
$(ROM_DISK_CHUNKS): $(ROM_DISK_IMAGE) ;

$(FINAL_IMAGE): check-inputs $(IMAGE_PREREQS) $(IMAGE_TOOL) $(SRC_DIR)/cbios_defs.inc
	$(PYTHON) $(IMAGE_TOOL) \
		--firmware "$(FIRMWARE_BIN)" \
		--defs "$(SRC_DIR)/cbios_defs.inc" \
		--output "$(FINAL_IMAGE)" \
		--manifest "$(LAYOUT_MANIFEST)" \
		--report "$(LAYOUT_REPORT)" \
		--symbols "$(SYMBOLS_FILE)" \
		$(PAYLOAD_ARGS)

clean:
	rm -rf "$(BUILD_DIR)"
