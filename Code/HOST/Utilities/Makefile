# Zephyr-80 machine utilities.
#
# The programs that are part of the MACHINE, as opposed to programs that run on
# it.  Everything here is either a rescue tool, a provisioning tool, or a
# diagnostic that speaks the IO Controller protocol -- so all of it is versioned
# with the BIOS and the controller firmware, not with the user's software.
#
# Two profiles, mirroring build_rom_disk.py's:
#
#   normal      what belongs on the ROM rescue disk (A:) -- non-destructive,
#               or destructive only where there is no other way to provision a
#               card (SDFMT).
#   diagnostic  bring-up, benchmark and DESTRUCTIVE tools.  These act on
#               whatever card is inserted, with no drive letter to get wrong,
#               and have no business on the disk you reach for when the machine
#               is already in trouble.
#
# `make` builds both.  The ROM disk manifest in ../CPM2.2 decides which of them
# actually ships, so nothing here is deleted by the profile split.

BUILD_DIR := build
SRC_DIR   := src
TOOLS_DIR := tools

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON  ?= python3
ASFLAGS ?= -o -l -s
LDFLAGS ?= -i

IHX_TO_COM := $(TOOLS_DIR)/ihx_to_com.py

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

# --- diagnostic profile ------------------------------------------------------
# DESTRUCTIVE: these write to whatever card is inserted.
DIAG := ioc_bulk ioc_sdblk ioc_sdwrite ioc_sdsoak ioc_sdrec ioc_sdbench
# Non-destructive bring-up.
DIAG += ioc_rts_probe ioc_diagchk v9958tst hidstat sndtest

TARGETS := $(NORMAL) $(DIAG)

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
.PHONY: all normal diagnostic clean check-diag-record list
.SECONDARY: $(RELS) $(IHXS)

all: check-diag-record $(COMS)

normal:     check-diag-record $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(NORMAL)))
diagnostic: check-diag-record $(addprefix $(BUILD_DIR)/,$(addsuffix .com,$(DIAG)))

check-diag-record:
	@if [ -f "$(DIAG_RECORD_CHECK)" ] && [ -f "$(DIAG_RECORD_AUTHORITY)" ]; then \
		$(PYTHON) "$(DIAG_RECORD_CHECK)" --defs "$(DIAG_RECORD_AUTHORITY)" \
			--mirror $(SRC_DIR)/ioc_diag_record.inc; \
	else \
		echo "check-diag-record: BIOS project not present, skipping"; \
	fi

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

clean:
	rm -rf "$(BUILD_DIR)"
