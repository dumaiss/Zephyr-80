PYTHON ?= python3
SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
MAKEBIN ?= makebin
.DEFAULT_GOAL := all

BUILD_DIR ?= build
TOOLS_DIR ?= tools
SRC_DIR ?= src
DOCS_DIR ?= docs

CPM22_SRC ?= cpm22/cpm22.asm
CPMTOOLS_DISKDEF ?= config/diskdef

# Which backend is linked as drive A:.  Exactly one can be, because the BIOS
# common window has no room for two; they all .org at CBIOS_STORAGE_A_CODE_BASE
# and export the neutral stg_a_* entry points the dispatcher calls.
#
#   rom      read-only CP/M volume in flash pages 1-3 (default)
#   vdrip    proxy storage over the host serial link (the previous default)
#            *** CURRENTLY DOES NOT BUILD -- see below ***
#   ramdisk  banked RAM disk, retained but not maintained
#
# STORAGE_A=vdrip overflows driver slot 5 by 29 bytes and fails layout
# validation with a precise message naming STORAGE_A_CODE_END.  This is
# arithmetic, not a regression to hunt: that configuration needs the VDrip
# transport (649 bytes) plus the consolidated SD probe (41) plus the VDrip
# storage backend (356) = 1046 bytes in a 1024-byte slot.
#
# It only ever fit because 36 of the probe's 49 bytes lived OUTSIDE slot 5 --
# 16 in the core BIOS tail at DFEDh and 20 in the packed extension at F41Bh --
# wedged into whatever holes existed when each piece was written.  Pulling them
# into one block is the point of the slot 5 realignment, and no 41-byte
# contiguous hole exists anywhere else in that build (the packed extension has
# 31 bytes across two pieces; the core BIOS has at most 19).
#
# Left failing deliberately, pending a decision on whether to retire this
# backend or give it a two-way split probe.  CONSOLE=vdrip STORAGE_A=rom and
# the default CONSOLE=v9958 STORAGE_A=rom both build normally.
STORAGE_A ?= rom
STORAGE_A_SRC ?= $(SRC_DIR)/cbios_storage_$(STORAGE_A).asm

# Console backend linked into the fixed BIOS console slots:
#   v9958    physical LunchCrema V9958 plus IOC HID input (default)
#   vdrip    retained Virtual Drip compatibility console
CONSOLE ?= v9958
VALID_CONSOLES := v9958 vdrip
ifeq ($(filter $(CONSOLE),$(VALID_CONSOLES)),)
$(error Unsupported CONSOLE='$(CONSOLE)'; choose one of: $(VALID_CONSOLES))
endif
ifeq ($(STORAGE_A),vdrip)
ifneq ($(CONSOLE),vdrip)
$(error STORAGE_A=vdrip requires CONSOLE=vdrip because both use the shared VDrip transport)
endif
endif

CONSOLE_SRC := $(SRC_DIR)/cbios_console_$(CONSOLE).asm
ifeq ($(CONSOLE),vdrip)
VDRIP_TRANSPORT_SRC := $(SRC_DIR)/vdrip_transport.asm
VDRIP_TRANSPORT_INCLUDE := .include "vdrip_transport.asm"
VDRIP_TRANSPORT_LINKED := 1
else
VDRIP_TRANSPORT_SRC :=
VDRIP_TRANSPORT_INCLUDE :=
VDRIP_TRANSPORT_LINKED := 0
endif

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
	$(VDRIP_TRANSPORT_SRC) \
	$(SRC_DIR)/cbios_bios_ext.asm \
	$(SRC_DIR)/cbios_iocall.asm \
	$(SRC_DIR)/cbios_ioc_command.asm \
	$(SRC_DIR)/cbios_hid_input.asm \
	$(SRC_DIR)/cbios_sercon.asm \
	$(CONSOLE_SRC) \
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

# The CP/M tools read the IOC failure record at fixed addresses through this
# mirror of the layout in cbios_defs.inc.  Two hand-maintained copies have
# already drifted once; check_diag_record.py is what notices.
DIAG_RECORD_MIRROR ?= ../Utilities/src/ioc_diag_record.inc

IMAGE_TOOL := $(TOOLS_DIR)/build_zephyr_image.py
ROM_DISK_TOOL := $(TOOLS_DIR)/build_rom_disk.py

# ROM disk inputs and outputs.  Only used when STORAGE_A=rom; a vdrip or ramdisk
# build embeds no payloads and produces the same 128 KiB image it always did.
# Which utility set lands on the ROM rescue disk.
#
#   normal      rescue and provisioning tools only (default)
#   diagnostic  normal plus bring-up, benchmark and DESTRUCTIVE tools
#
# The destructive ones -- SDWRITE, SDREC, SDSOAK, SDBENCH -- act on whatever
# card is inserted, with no drive letter to get wrong.  They have no business on
# a disk you reach for when the machine is already in trouble.  Nothing is
# deleted by this: every tool still builds, and the diagnostic profile carries
# them all.
ROM_DISK_PROFILE ?= normal

PAYLOAD_CONFIG ?= config/banks.ini
ROM_DISK_PAGES ?= 3
ROM_DISK_IMAGE ?= $(BUILD_DIR)/romdisk.img
# Staging for the ROM A: volume.  A BUILD OUTPUT, not a source: build_rom_disk.py
# copies the resolved manifest here and then builds the image from it.
#
# It used to live at images/ROM/0 and 24 of its files were tracked in git, so
# every build rewrote checked-in content and dirtied the tree -- and the tracked
# copies drifted from the projects that actually produce them, which is the same
# trap NOWRAP.com and WRAPON.COM fell into on the ROM itself.
ROM_DISK_STAGE ?= $(BUILD_DIR)/romdisk-stage
ROM_DISK_CHUNKS := $(foreach n,$(shell seq 1 $(ROM_DISK_PAGES)),$(BUILD_DIR)/romdisk.p$(n).bin)

# The volume is assembled from binaries built by sibling projects.  Listing them
# here is only for change detection: build_rom_disk.py owns the real manifest and
# reports precisely which file is missing if one has not been built yet.
UTILITIES_BUILD ?= ../Utilities/build
# Prebuilt third-party ZCPR2 / Z-System binaries.  Checked in, not built: there
# is no source for them in this tree.
UTILITIES_ZSYS ?= ../Utilities/zsys
MONITOR_BUILD ?= ../Monitor/build
# Stock DRI tools (PIP, STAT, ZSID, DUMP) come from the software volumes, which
# is where the machine's third-party CP/M software now lives.
SOFTWARE_DIR ?= ../Software
ROM_DISK_INPUTS := $(wildcard $(UTILITIES_BUILD)/*.com) \
	$(wildcard $(UTILITIES_ZSYS)/*.COM) \
	$(wildcard $(MONITOR_BUILD)/zephyr80_monitor.bin) \
	$(wildcard $(SOFTWARE_DIR)/disk1/0/*) $(wildcard $(SOFTWARE_DIR)/disk1/1/*)

ifeq ($(STORAGE_A),rom)
PAYLOAD_ARGS := --payload-config "$(PAYLOAD_CONFIG)"
IMAGE_PREREQS := $(ROM_DISK_CHUNKS)
else
PAYLOAD_ARGS :=
IMAGE_PREREQS :=
endif
CPM22_CONVERT_TOOL := $(TOOLS_DIR)/convert_cpm22_asxxxx.py
MEMORY_DOC_TOOL := $(TOOLS_DIR)/generate_memory_docs.py

.PHONY: all image docs clean check-inputs runtime-sources-check rom-disk FORCE

FORCE:

all: image

# The built ROM is also copied to a name that states its configuration, and the
# configuration is printed at the end of every build.
#
# This exists because a plain `make` leaves build/zephyr80.bin holding the STOCK
# system, and a `make CCP=zcpr2 BDOS=zsdos` leaves the same filename holding a
# Z-System.  Nothing about the file says which -- so verifying one configuration
# and then flashing "the ROM" can silently flash the other.  That happened.
# Deferred (=), not immediate (:=): CCP and BDOS are defined further down this
# file, so an immediate assignment here expands them as empty and produces
# "zephyr80--.bin".
CPM_CONFIG = $(CCP)-$(BDOS)
STAMPED_IMAGE = $(BUILD_DIR)/zephyr80-$(CPM_CONFIG).bin

image: $(FINAL_IMAGE) docs
	@cp "$(FINAL_IMAGE)" "$(STAMPED_IMAGE)"
	@echo ""
	@echo "  ROM built:  CCP=$(CCP)  BDOS=$(BDOS)"
	@echo "    $(FINAL_IMAGE)"
	@echo "    $(STAMPED_IMAGE)   <- flash this one to be sure"
	@echo ""


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

$(FIRMWARE_SRC): $(SRC_DIR)/zephyr.asm $(CPM22_ASXXXX_SRC) Makefile FORCE | $(BUILD_DIR)
	sed \
		-e 's|\.include "../$(CPM22_SRC)"|.include "cpm22_asxxxx.asm"|' \
		-e 's|\.include "vdrip_transport.asm"|$(VDRIP_TRANSPORT_INCLUDE)|' \
		-e 's|^VDRIP_TRANSPORT_LINKED = 1$$|VDRIP_TRANSPORT_LINKED = $(VDRIP_TRANSPORT_LINKED)|' \
		-e 's|\.include "cbios_console_vdrip.asm"|.include "cbios_console_$(CONSOLE).asm"|' \
		-e 's|\.include "cbios_storage_vdrip.asm"|.include "cbios_storage_$(STORAGE_A).asm"|' \
		"$<" > "$@"
	@grep -q 'cpm22_asxxxx\.asm' "$@" || { \
		echo "The CP/M include rewrite matched nothing in $@."; \
		echo "CPM22_SRC ($(CPM22_SRC)) and the .include in $(SRC_DIR)/zephyr.asm have drifted apart."; \
		exit 1; }

$(FIRMWARE_REL): $(FIRMWARE_SRC) $(RUNTIME_SRCS) $(CPM22_ASXXXX_SRC) $(CPM22_SRC) | $(BUILD_DIR)
	$(SDASZ80) -I$(SRC_DIR) -I$(BUILD_DIR) $(ASFLAGS) $@ $(FIRMWARE_SRC)

$(FIRMWARE_IHX): $(FIRMWARE_REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<
	$(PYTHON) $(TOOLS_DIR)/check_overlap.py "$@" --symbols "$(FIRMWARE_SYM)"
	$(PYTHON) $(TOOLS_DIR)/check_diag_record.py \
		--defs "$(SRC_DIR)/cbios_defs.inc" --mirror "$(DIAG_RECORD_MIRROR)"

# Which command processor and BDOS the ROM carries.
#
#   CCP  = stock | zcpr2    C400h-CBFFh
#   BDOS = stock | zsdos    CC00h-D9FFh
#
# Both are assembled into the firmware image like everything else, so selecting
# one is a byte replacement at a fixed address rather than a link change.  The
# two are independent: ZSDOS runs under the stock CCP and ZCPR2 runs over the
# stock BDOS.
#
# Neither is built by a plain `make`: both need a CP/M emulator to run their
# period assemblers, so they are explicit targets.  `make CCP=zcpr2` fails with
# a clear message if `make zcpr2` has not been run.
CCP  ?= stock
BDOS ?= stock

CBASE_ADDR ?= 0xC400
ZCPR2_BIN  ?= $(BUILD_DIR)/ccp-zcpr2.bin
ZSDOS_BIN  ?= $(BUILD_DIR)/bdos-zsdos.bin
PATCH_CPM  := $(TOOLS_DIR)/patch_cpm.py

ZCPR2_SRCS := $(wildcard zcpr2/src/*) zcpr2/build-zcpr2.sh $(TOOLS_DIR)/hex_to_ccp.py
ZSDOS_SRCS := $(wildcard zsdos/src/*) zsdos/build-zsdos.sh $(TOOLS_DIR)/l80_slice.py

.PHONY: zcpr2 zsdos
zcpr2: $(ZCPR2_BIN)
zsdos: $(ZSDOS_BIN)

$(ZCPR2_BIN): $(ZCPR2_SRCS) | $(BUILD_DIR)
	./zcpr2/build-zcpr2.sh $(BUILD_DIR)/zcpr2-build $@

# Depends on the symbol map: ZSDOS calls two BIOS helpers by absolute address,
# and both move when the BIOS is rebuilt.  The addresses are generated, never
# written down -- a stale one would assemble cleanly and jump into the middle of
# something at run time.
$(ZSDOS_BIN): $(ZSDOS_SRCS) $(SYMBOLS_FILE) $(TOOLS_DIR)/gen_zsdos_bios.py | $(BUILD_DIR)
	./zsdos/build-zsdos.sh $(BUILD_DIR)/zsdos-build $@ $(SYMBOLS_FILE)

CPM_PATCH_ARGS :=
CPM_PATCH_DEPS :=
ifeq ($(CCP),zcpr2)
CPM_PATCH_ARGS += --ccp $(ZCPR2_BIN)
CPM_PATCH_DEPS += $(ZCPR2_BIN)
endif
ifeq ($(BDOS),zsdos)
CPM_PATCH_ARGS += --bdos $(ZSDOS_BIN)
CPM_PATCH_DEPS += $(ZSDOS_BIN)
endif

$(FIRMWARE_BIN): $(CPM_PATCH_DEPS)

$(FIRMWARE_BIN): $(FIRMWARE_IHX)
	$(MAKEBIN) $(MAKEBIN_FLAGS) $< $@
ifneq ($(strip $(CPM_PATCH_ARGS)),)
	@for f in $(CPM_PATCH_DEPS); do test -f "$$f" || { \
		echo "Missing $$f -- run 'make zcpr2' / 'make zsdos' (both need RUNCPM)"; \
		exit 1; }; done
	$(PYTHON) $(PATCH_CPM) --firmware $@ $(CPM_PATCH_ARGS) \
		--cbase $(CBASE_ADDR) --output $@
endif

$(SYMBOLS_FILE): $(FIRMWARE_REL)
	cp "$(FIRMWARE_SYM)" "$@"

# Build the drive A: volume and split it into one 48 KiB chunk per ROM page.
# Writes only inside $(BUILD_DIR) and the staging tree; it never touches
# images/zephyr80-vdrip2.cpm, which is a separate user-owned volume.
rom-disk: $(ROM_DISK_IMAGE)

$(ROM_DISK_IMAGE): $(ROM_DISK_TOOL) $(CPMTOOLS_DISKDEF) $(ROM_DISK_INPUTS) | $(BUILD_DIR)
	$(PYTHON) $(ROM_DISK_TOOL) \
		--profile "$(ROM_DISK_PROFILE)" \
		--diskdef "$(CPMTOOLS_DISKDEF)" \
		--staging-dir "$(ROM_DISK_STAGE)" \
		--utils-dir "$(UTILITIES_BUILD)" \
		--zsys-dir "$(UTILITIES_ZSYS)" \
		--monitor-dir "$(MONITOR_BUILD)" \
		--stock-dir0 "$(SOFTWARE_DIR)/disk1/0" \
		--stock-dir1 "$(SOFTWARE_DIR)/disk1/1" \
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
		--console "$(CONSOLE)" \
		--storage-a "$(STORAGE_A)" \
		$(PAYLOAD_ARGS)

clean:
	rm -rf "$(BUILD_DIR)"
