# Zephyr-80 CP/M software volumes.
#
# The programs that RUN ON the machine, as opposed to the programs that ARE the
# machine (those live in ../Utilities and ship on the ROM A: volume).
#
#   CPM_1.DRV   third-party CP/M software -- Turbo Pascal, Modula-2, WordStar,
#               SuperCalc, dBASE, BBC BASIC, MBASIC, ZDE, and the stock DRI
#               tools.  User areas are preserved as they were on the machine, so
#               a package stays where its installer put it.
#
#   CPM_2.DRV   your own work -- programs you wrote, ROMs, VGM/ZVG media, and
#               the V9958 definition files.
#
# ---------------------------------------------------------------------------
# THIS MAKEFILE NEVER WRITES A VOLUME THAT IS ALREADY IN USE
# ---------------------------------------------------------------------------
#
# Output goes to build/ and nowhere else.  In particular it does not touch
# ../CPM2.2/images/zephyr80-vdrip2.cpm, which is a working volume this project
# was reconciled FROM, not a build product.
#
# `make install CARD=/media/...` copies the built volumes onto a mounted FAT
# card.  That is opt-in on purpose: it overwrites, and overwriting a volume the
# machine has written to loses whatever was written.
#
# ---------------------------------------------------------------------------
# HOW THE TREE WAS SEEDED, AND THE RULE THAT SETTLED CONFLICTS
# ---------------------------------------------------------------------------
#
# disk1/ and disk2/ were built from the union of the live volume and the old
# ../CPM2.2/images/A staging tree, which had drifted apart.  Where a file
# existed in both AND differed, THE VOLUME WON -- because several of them
# (turbo.com, m2.com, dbase.com, sc2.com, wsu.com) had been configured by their
# own installers on the machine, and the staging copies were the pristine
# originals.  See README.md for the full reconciliation record.

# No implicit rules.  disk1/ and disk2/ are DATA, and make's built-in suffix
# rules will happily try to build one data file from another: a first run here
# tried to compile v9958.def into v9958.sym with the Modula-2 rule and failed
# with "m2c: No such file or directory".  Nothing in this project is built by an
# implicit rule.
MAKEFLAGS += --no-builtin-rules --no-builtin-variables
.SUFFIXES:

BUILD_DIR := build
PYTHON    ?= python3
MKIMAGE   := tools/mkcpmimage.py
DISKDEF   ?= diskdef
FORMAT    ?= zephyr80-vdrip

# Named for exactly what the controller auto-mounts: default_image[] in
# ../../MCU/IOController/src/volume.c is { "CPM_1   DRV", "CPM_2   DRV" }, so
# these are CPM_1.DRV and CPM_2.DRV and not anything else.  Rename either side
# and the controller silently falls back to raw addressing -- the volumes are
# simply not found, with nothing to say why.  VOLINFO reports the live mode.
DISK1 := $(BUILD_DIR)/CPM_1.DRV
DISK2 := $(BUILD_DIR)/CPM_2.DRV

DISK1_FILES := $(shell find disk1 -type f 2>/dev/null)
DISK2_FILES := $(shell find disk2 -type f 2>/dev/null)

.DEFAULT_GOAL := all
.PHONY: all clean list install check-tools

all: check-tools $(DISK1) $(DISK2)

check-tools:
	@test -f "$(MKIMAGE)" || { echo "missing image builder: $(MKIMAGE)"; exit 1; }
	@test -f "$(DISKDEF)" || { echo "missing disk definition: $(DISKDEF)"; exit 1; }

$(BUILD_DIR):
	mkdir -p $@

# One rule for both volumes.  $* is 1 or 2, so disk$*/ is the source tree.
#
# Built by tools/mkcpmimage.py, not by mkfs.cpm and cpmcp.
#
# cpmtools WRITES this format correctly but cannot READ WHAT IT WROTE: the first
# copy into a fresh volume succeeds, and every pass after it aborts with
# "malloc(): invalid size (unsorted)" while scanning the directory.  A dump of
# that directory shows a textbook entry and a byte-exact payload, so the volume
# is fine and the reader is not.  The trigger is filename-dependent and
# deterministic -- MANDEL.BAS provokes it, SMILEY.COM does not -- which is not a
# distinction the on-disk format makes.
#
# Since any multi-file build needs more than one pass, that ruled cpmtools out
# for writing.  mkcpmimage.py builds the whole volume in one pass and verifies
# it by reading its own output back, so a bad image fails the build instead of
# behaving oddly later.  Its output was cross-checked against a cpmtools-built
# volume: cpmls lists the two identically, file for file.
$(BUILD_DIR)/CPM_%.DRV: $(DISKDEF) $(MKIMAGE) | $(BUILD_DIR)
	@echo "building $@ from disk$*/"
	@$(PYTHON) $(MKIMAGE) --tree disk$* --diskdef $(DISKDEF) \
		--format $(FORMAT) --output "$@"

$(DISK1): $(DISK1_FILES)
$(DISK2): $(DISK2_FILES)

# Copy onto a mounted FAT card.  Opt-in, and it overwrites.
install: all
	@test -n "$(CARD)" || { echo "usage: make install CARD=/path/to/mounted/card"; exit 1; }
	@test -d "$(CARD)/CPM" || { echo "no $(CARD)/CPM directory -- create it first"; exit 1; }
	cp $(DISK1) $(DISK2) "$(CARD)/CPM/"
	@echo "copied.  The controller mounts /CPM/CPM_1.DRV as unit 0, CPM_2.DRV as unit 1."

list:
	@for d in 1 2; do echo "CPM_$$d.DRV:"; \
		for u in $$(ls disk$$d 2>/dev/null | sort -n); do \
			printf "  user %-2s %s\n" "$$u" "$$(ls disk$$d/$$u | tr '\n' ' ')"; done; done

clean:
	rm -rf "$(BUILD_DIR)"
