PYTHON ?= python3
SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
MAKEBIN ?= makebin

BUILD_DIR ?= build
TOOLS_DIR ?= tools
SRC_DIR ?= src
DOCS_DIR ?= docs

CPM22_SRC ?= cpm-2.2/src/cpm22.asm
PAYLOAD_CONFIG ?= images/banks.ini
CPMTOOLS_DISKDEF ?= images/diskdef

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
	$(SRC_DIR)/cbios_iocall.asm \
	$(SRC_DIR)/cbios_console_vdrip.asm \
	$(SRC_DIR)/cbios_storage.asm \
	$(SRC_DIR)/cbios_storage_vdrip.asm \
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

PRE_SWAP_IMAGE ?= $(BUILD_DIR)/zephyr80.pre-swap.bin
FINAL_IMAGE ?= $(BUILD_DIR)/zephyr80.bin
LAYOUT_MANIFEST ?= $(BUILD_DIR)/layout.manifest
LAYOUT_REPORT ?= $(BUILD_DIR)/layout-report.md
SYMBOL_MAP_DOC ?= $(DOCS_DIR)/symbol-map.md
MEMORY_MAP_DOC ?= $(DOCS_DIR)/memory-map.md

IMAGE_TOOL := $(TOOLS_DIR)/build_zephyr_image.py
SWAPBITS_TOOL := $(TOOLS_DIR)/swapbits.py
CPM22_CONVERT_TOOL := $(TOOLS_DIR)/convert_cpm22_asxxxx.py
MEMORY_DOC_TOOL := $(TOOLS_DIR)/generate_memory_docs.py

.PHONY: all image docs clean check-inputs runtime-sources-check

all: image

image: $(FINAL_IMAGE) docs

docs: $(FINAL_IMAGE) $(FIRMWARE_LST) $(SYMBOLS_FILE) $(LAYOUT_MANIFEST) $(MEMORY_DOC_TOOL)
	$(PYTHON) $(MEMORY_DOC_TOOL) \
		--listing "$(FIRMWARE_LST)" \
		--map "$(SYMBOLS_FILE)" \
		--manifest "$(LAYOUT_MANIFEST)" \
		--firmware-bin "$(FIRMWARE_BIN)" \
		--pre-swap-image "$(PRE_SWAP_IMAGE)" \
		--final-image "$(FINAL_IMAGE)" \
		--symbol-map "$(SYMBOL_MAP_DOC)" \
		--memory-map "$(MEMORY_MAP_DOC)"

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

check-inputs: $(BUILD_DIR) $(FIRMWARE_BIN) $(SYMBOLS_FILE)
	@test -f "$(CPM22_SRC)" || { echo "Missing CP/M source input: $(CPM22_SRC)"; exit 1; }
	@test -f "$(FIRMWARE_BIN)" || { echo "Missing firmware image: $(FIRMWARE_BIN)"; exit 1; }
	@test -f "$(SYMBOLS_FILE)" || { echo "Missing firmware symbol map: $(SYMBOLS_FILE)"; exit 1; }
	@test -f "$(PAYLOAD_CONFIG)" || { echo "Missing payload configuration: $(PAYLOAD_CONFIG)"; exit 1; }
	@test -f "$(CPMTOOLS_DISKDEF)" || { echo "Missing cpmtools disk definition: $(CPMTOOLS_DISKDEF)"; exit 1; }
	@test -f "$(SRC_DIR)/cbios_defs.inc" || { echo "Missing CBIOS definitions: $(SRC_DIR)/cbios_defs.inc"; exit 1; }
	@test -f "$(IMAGE_TOOL)" || { echo "Missing image tool: $(IMAGE_TOOL)"; exit 1; }
	@test -f "$(SWAPBITS_TOOL)" || { echo "Missing bit-swap tool: $(SWAPBITS_TOOL)"; exit 1; }
	@test -f "$(CPM22_CONVERT_TOOL)" || { echo "Missing CP/M conversion tool: $(CPM22_CONVERT_TOOL)"; exit 1; }
	@test -f "$(MEMORY_DOC_TOOL)" || { echo "Missing memory documentation tool: $(MEMORY_DOC_TOOL)"; exit 1; }

runtime-sources-check:
	@for src in $(RUNTIME_SRCS); do \
		test -f "$$src" || { echo "Missing runtime source: $$src"; exit 1; }; \
	done

$(CPM22_ASXXXX_SRC): $(CPM22_SRC) $(CPM22_CONVERT_TOOL) | $(BUILD_DIR)
	$(PYTHON) $(CPM22_CONVERT_TOOL) "$<" "$@"

$(FIRMWARE_SRC): $(SRC_DIR)/zephyr.asm $(CPM22_ASXXXX_SRC) | $(BUILD_DIR)
	sed 's|\.include "../cpm-2.2/src/cpm22.asm"|.include "cpm22_asxxxx.asm"|' "$<" > "$@"

$(FIRMWARE_REL): $(FIRMWARE_SRC) $(RUNTIME_SRCS) $(CPM22_ASXXXX_SRC) $(CPM22_SRC) | $(BUILD_DIR)
	$(SDASZ80) -I$(SRC_DIR) -I$(BUILD_DIR) $(ASFLAGS) $@ $(FIRMWARE_SRC)

$(FIRMWARE_IHX): $(FIRMWARE_REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(FIRMWARE_BIN): $(FIRMWARE_IHX)
	$(MAKEBIN) $(MAKEBIN_FLAGS) $< $@

$(SYMBOLS_FILE): $(FIRMWARE_REL)
	cp "$(FIRMWARE_SYM)" "$@"

$(PRE_SWAP_IMAGE): check-inputs $(PAYLOAD_CONFIG) $(IMAGE_TOOL) $(SRC_DIR)/cbios_defs.inc
	$(PYTHON) $(IMAGE_TOOL) \
		--firmware "$(FIRMWARE_BIN)" \
		--payload-config "$(PAYLOAD_CONFIG)" \
		--defs "$(SRC_DIR)/cbios_defs.inc" \
		--output "$(PRE_SWAP_IMAGE)" \
		--manifest "$(LAYOUT_MANIFEST)" \
		--report "$(LAYOUT_REPORT)" \
		--symbols "$(SYMBOLS_FILE)"

$(FINAL_IMAGE): $(PRE_SWAP_IMAGE)
	$(PYTHON) $(SWAPBITS_TOOL) "$(PRE_SWAP_IMAGE)" "$(FINAL_IMAGE)"

clean:
	rm -rf "$(BUILD_DIR)"
