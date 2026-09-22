# Zephyr-80 machine utilities.
#
# The programs that are part of the MACHINE, as opposed to programs that run on
# it.  Everything here is either a rescue tool, a provisioning tool, or a
# diagnostic that speaks the IO Controller protocol -- so all of it is versioned
# with the BIOS and the controller firmware, not with the user's software.
#
# Three sets:
#
#   normal      the ROM rescue disk (A:) -- non-destructive, or destructive
#               only where there is no other way to provision a card (SDFMT).
#               ../CPM2.2/tools/build_rom_disk.py lists what ships.
#   diagnostic  bring-up, benchmark and DESTRUCTIVE tools.  These act on
#               whatever card is inserted, with no drive letter to get wrong.
#               They are never put on the ROM disk; copy one to a work drive
#               when it is needed.
#   tools       everyday tools that drive machine hardware but are not rescue
#               tools.  Also never on the ROM disk.
#
# `make` builds both.

BUILD_DIR := build
SRC_DIR   := src
TOOLS_DIR := tools

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON  ?= python3
ASFLAGS ?= -o -l -s
LDFLAGS ?= -i

IHX_TO_COM := $(TOOLS_DIR)/ihx_to_com.py
BDOSCHAR_FIXTURE_GEN := $(TOOLS_DIR)/generate_bdoschar_fixtures.py
BDOSCHAR_FIXTURE_INC := $(SRC_DIR)/bdoschar_fixtures.inc
BDOSCHAR_CASES_SUB   := $(SRC_DIR)/bdoschar.sub

# --- normal profile: the ROM rescue disk ------------------------------------
# Non-destructive version, transport, power and controller-health check.
NORMAL := ioc_ping ioc_reset ioc_sd_read
# Provisioning: a fresh SD volume needs its directory initialised.  Destructive,
# and kept only because without it a new card cannot be made usable at all.
NORMAL += ioc_sdfmt
# Console and input.
NORMAL += hidkey padstat sercon nowrap wrapon
# Storage volumes and the /SHARED/ folder tools.
NORMAL += volinfo sddir sdget sdput sddel
# Reports which CCP and BDOS are actually executing, read out of RAM.  Uses no
# IO Controller traffic, so it answers when the link is dead.
NORMAL += sysid

# --- diagnostic set ----------------------------------------------------------
# DESTRUCTIVE: these write to whatever card is inserted.
DIAG := ioc_bulk ioc_sdblk ioc_sdwrite ioc_sdsoak ioc_sdrec ioc_sdbench
# Bring-up and characterization: SIO RTS probe, BIOS failure-record check,
# V9958 display test, IO Controller HID status pages, sound card and BDOS tests.
DIAG += ioc_rts_probe ioc_diagchk v9958tst hidstat sndtest bdoschar

# --- tools -------------------------------------------------------------------
# X/Y/ZMODEM file transfer over the serial console port.
TOOLS := xfer zcd

TARGETS := $(NORMAL) $(DIAG) $(TOOLS)

INCS := $(wildcard $(SRC_DIR)/*.inc)
RELS := $(addprefix $(BUILD_DIR)/,$(addsuffix .rel,$(TARGETS)))
IHXS := $(addprefix $(BUILD_DIR)/,$(addsuffix .ihx,$(TARGETS)))
COMS := $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(TARGETS)))

# The IOC failure-record layout lives in the BIOS project; src/ioc_diag_record.inc
# is the mirror these tools compile against.  Checking it here means a tool
# cannot be built against a stale layout -- which assembles cleanly and only
# lies at runtime, in the one report consulted when the link is dead.
DIAG_RECORD_AUTHORITY ?= ../CPM2.2/src/cbios_defs.inc
DIAG_RECORD_CHECK     ?= ../CPM2.2/tools/check_diag_record.py

.DEFAULT_GOAL := all
.PHONY: all normal diagnostic tools test test-zcd clean check-diag-record check-bdoschar-fixtures generate-bdoschar-fixtures list
.SECONDARY: $(RELS) $(IHXS)

all: check-diag-record check-bdoschar-fixtures $(COMS)

normal:     check-diag-record $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(NORMAL)))
diagnostic: check-diag-record check-bdoschar-fixtures $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(DIAG)))
tools:      $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(TOOLS)))

test: test-zcd

test-zcd: $(BUILD_DIR)/zcd.com
	$(PYTHON) $(TOOLS_DIR)/test_zcd.py

check-diag-record:
	@if [ -f "$(DIAG_RECORD_CHECK)" ] && [ -f "$(DIAG_RECORD_AUTHORITY)" ]; then \
		$(PYTHON) "$(DIAG_RECORD_CHECK)" --defs "$(DIAG_RECORD_AUTHORITY)" \
			--mirror $(SRC_DIR)/ioc_diag_record.inc; \
	else \
		echo "check-diag-record: BIOS project not present, skipping"; \
	fi

generate-bdoschar-fixtures:
	$(PYTHON) $(BDOSCHAR_FIXTURE_GEN) --output $(BDOSCHAR_FIXTURE_INC) --submit-output $(BDOSCHAR_CASES_SUB)

check-bdoschar-fixtures: $(BDOSCHAR_FIXTURE_INC) $(BDOSCHAR_CASES_SUB)
	$(PYTHON) $(BDOSCHAR_FIXTURE_GEN) --output $(BDOSCHAR_FIXTURE_INC) --submit-output $(BDOSCHAR_CASES_SUB) --check

$(BDOSCHAR_FIXTURE_INC) $(BDOSCHAR_CASES_SUB): $(BDOSCHAR_FIXTURE_GEN)
	$(PYTHON) $(BDOSCHAR_FIXTURE_GEN) --output $(BDOSCHAR_FIXTURE_INC) --submit-output $(BDOSCHAR_CASES_SUB)

$(BUILD_DIR)/bdoschar.rel: $(BDOSCHAR_FIXTURE_INC)

$(BUILD_DIR):
	mkdir -p $@

$(BUILD_DIR)/%.rel: $(SRC_DIR)/%.asm $(INCS) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $@ $<

$(BUILD_DIR)/%.ihx: $(BUILD_DIR)/%.rel
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(BUILD_DIR)/%.com: $(BUILD_DIR)/%.ihx $(IHX_TO_COM)
	$(PYTHON) $(IHX_TO_COM) $< $@

list:
	@echo "normal:     $(NORMAL)"
	@echo "diagnostic: $(DIAG)"
	@echo "tools:      $(TOOLS)"

clean:
	rm -rf "$(BUILD_DIR)"
