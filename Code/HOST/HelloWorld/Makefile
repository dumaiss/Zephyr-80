BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools

Z80ASM ?= z80asm
SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON ?= python3
Z80ASMFLAGS ?=
ASXXXX_ASFLAGS ?= -o -l -s
ASXXXX_LDFLAGS ?= -i
HEX_ORIGIN ?= 8000h

SWAPBITS := $(TOOLS_DIR)/swapbits.py
LISTING_TO_IHEX := $(TOOLS_DIR)/listing_to_ihex.py
IHX_TO_COM := $(TOOLS_DIR)/ihx_to_com.py
INSTALL_DIAGNOSTICS := $(TOOLS_DIR)/install_diagnostics.py

CPM_FORMAT ?= zephyr80-vdrip
CPM_IMAGE ?= ../CPM2.2/images/zephyr80-vdrip2.cpm
CPM_STAGE_DIR ?= ../CPM2.2/images/A/0
CPM_USER ?= 0

ASXXXX_TARGETS := vdrip_checkerboard vdrip_smiley shadow_copy_test shadow_copy_low vdrip_text_mode_test
COM_TARGETS := video_smiley video_smiley_v9958 mandelbrot_v9958 mandelbrot_v9958_real v9958tst nowrap wrapon ioc_ping ioc_reset ioc_rts_probe ioc_sd_read ioc_bulk ioc_sdblk ioc_sdwrite ioc_sdsoak ioc_sdrec ioc_sdfmt ioc_sdbench ioc_diagchk sercon hidstat hidkey sndtest
ASXXXX_SRCS := $(addprefix $(SRC_DIR)/,$(addsuffix .asm,$(ASXXXX_TARGETS)))
COM_SRCS := $(addprefix $(SRC_DIR)/,$(addsuffix .asm,$(COM_TARGETS)))
ASXXXX_INCS := $(wildcard $(SRC_DIR)/*.inc)
ASM_SRCS := $(filter-out $(ASXXXX_SRCS) $(COM_SRCS),$(wildcard $(SRC_DIR)/*.asm))
TARGETS := $(basename $(notdir $(ASM_SRCS)))

RAW_BIN_DIR := $(BUILD_DIR)/raw
HEX_SRC_DIR := $(BUILD_DIR)/hex-src
HEX_RAW_DIR := $(BUILD_DIR)/hex-raw
HEX_LST_DIR := $(BUILD_DIR)/hex-lst
ASXXXX_DIR := $(BUILD_DIR)/asxxxx

BINS := $(addprefix $(BUILD_DIR)/,$(addsuffix .bin,$(TARGETS)))
Z80ASM_HEXS := $(addprefix $(BUILD_DIR)/,$(addsuffix .hex,$(TARGETS)))
ASXXXX_HEXS := $(addprefix $(BUILD_DIR)/,$(addsuffix .hex,$(ASXXXX_TARGETS)))
ASXXXX_IHXS := $(addprefix $(BUILD_DIR)/,$(addsuffix .ihx,$(ASXXXX_TARGETS)))
HEXS := $(Z80ASM_HEXS) $(ASXXXX_HEXS)
HEX_SRCS := $(addprefix $(HEX_SRC_DIR)/,$(addsuffix .asm,$(TARGETS)))
HEX_LSTS := $(addprefix $(HEX_LST_DIR)/,$(addsuffix .lst,$(TARGETS)))
ASXXXX_RELS := $(addprefix $(ASXXXX_DIR)/,$(addsuffix .rel,$(ASXXXX_TARGETS)))
COM_RELS := $(addprefix $(ASXXXX_DIR)/,$(addsuffix .rel,$(COM_TARGETS)))
COM_IHXS := $(addprefix $(BUILD_DIR)/,$(addsuffix .ihx,$(COM_TARGETS)))
COM_BINS := $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(COM_TARGETS)))
DIAGNOSTIC_COM_TARGETS := ioc_ping ioc_reset ioc_rts_probe ioc_sd_read ioc_bulk ioc_sdblk ioc_sdwrite ioc_sdsoak ioc_sdrec ioc_sdfmt ioc_sdbench ioc_diagchk sercon hidstat hidkey sndtest
DIAGNOSTIC_COMS := $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(DIAGNOSTIC_COM_TARGETS)))

# The IOC failure-record layout lives in the BIOS project; this mirror is what
# the tools compile against.  Checking it here means a tool cannot be built
# against a stale layout, which assembles cleanly and only lies at runtime.
DIAG_RECORD_AUTHORITY ?= ../CPM2.2/src/cbios_defs.inc
DIAG_RECORD_CHECK ?= ../CPM2.2/tools/check_diag_record.py

.PHONY: all clean bins hex com install-diags check-diag-record

check-diag-record:
	@if [ -f "$(DIAG_RECORD_CHECK)" ] && [ -f "$(DIAG_RECORD_AUTHORITY)" ]; then \
		python3 "$(DIAG_RECORD_CHECK)" --defs "$(DIAG_RECORD_AUTHORITY)" \
			--mirror src/ioc_diag_record.inc; \
	else \
		echo "check-diag-record: BIOS project not present, skipping"; \
	fi
.SECONDARY: $(HEX_SRCS) $(HEX_LSTS) $(ASXXXX_RELS) $(ASXXXX_IHXS) $(COM_RELS) $(COM_IHXS)

all: check-diag-record bins hex com

bins: $(BINS)

hex: $(HEXS)

com: $(COM_BINS)

install-diags: $(DIAGNOSTIC_COMS) $(INSTALL_DIAGNOSTICS)
	$(PYTHON) $(INSTALL_DIAGNOSTICS) \
		--build-dir $(BUILD_DIR) \
		--staging-dir $(CPM_STAGE_DIR) \
		--image $(CPM_IMAGE) \
		--format $(CPM_FORMAT) \
		--user $(CPM_USER)

$(BUILD_DIR) $(RAW_BIN_DIR) $(HEX_SRC_DIR) $(HEX_RAW_DIR) $(HEX_LST_DIR) $(ASXXXX_DIR):
	mkdir -p $@

$(RAW_BIN_DIR)/%.bin: $(SRC_DIR)/%.asm | $(RAW_BIN_DIR)
	$(Z80ASM) $(Z80ASMFLAGS) -o $@ $<

$(BUILD_DIR)/%.bin: $(RAW_BIN_DIR)/%.bin $(SWAPBITS) | $(BUILD_DIR)
	$(PYTHON) $(SWAPBITS) $< $@

$(HEX_SRC_DIR)/%.asm: $(SRC_DIR)/%.asm | $(HEX_SRC_DIR)
	awk 'BEGIN { fixed = 0 } /^[[:space:]]*[Oo][Rr][Gg][[:space:]]/ && !fixed { print "                org $(HEX_ORIGIN)"; fixed = 1; next } { print }' $< > $@

$(HEX_LST_DIR)/%.lst: $(HEX_SRC_DIR)/%.asm | $(HEX_RAW_DIR) $(HEX_LST_DIR)
	$(Z80ASM) $(Z80ASMFLAGS) -l -o $(HEX_RAW_DIR)/$*.bin $< > $@ 2>&1

$(Z80ASM_HEXS): $(BUILD_DIR)/%.hex: $(HEX_LST_DIR)/%.lst $(LISTING_TO_IHEX) | $(BUILD_DIR)
	$(PYTHON) $(LISTING_TO_IHEX) $< $(HEX_RAW_DIR)/$*.bin $@

$(ASXXXX_DIR)/%.rel: $(SRC_DIR)/%.asm $(ASXXXX_INCS) | $(ASXXXX_DIR)
	$(SDASZ80) $(ASXXXX_ASFLAGS) $@ $<

$(ASXXXX_IHXS): $(BUILD_DIR)/%.ihx: $(ASXXXX_DIR)/%.rel | $(BUILD_DIR)
	$(SDLDZ80) $(ASXXXX_LDFLAGS) $@ $<

$(ASXXXX_HEXS): $(BUILD_DIR)/%.hex: $(BUILD_DIR)/%.ihx | $(BUILD_DIR)
	cp $< $@

$(COM_IHXS): $(BUILD_DIR)/%.ihx: $(ASXXXX_DIR)/%.rel | $(BUILD_DIR)
	$(SDLDZ80) $(ASXXXX_LDFLAGS) $@ $<

$(COM_BINS): $(BUILD_DIR)/%.com: $(BUILD_DIR)/%.ihx $(IHX_TO_COM) | $(BUILD_DIR)
	$(PYTHON) $(IHX_TO_COM) $< $@

clean:
	rm -rf "$(BUILD_DIR)"/*
