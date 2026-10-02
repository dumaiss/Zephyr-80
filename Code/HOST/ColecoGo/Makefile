BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON ?= python3

ASFLAGS ?= -o -l -s -w
LDFLAGS ?= -i -m

SOURCE := $(SRC_DIR)/colecogo.asm
INCLUDES := $(SRC_DIR)/cartscan.inc $(SRC_DIR)/cartpatch.inc
OBJECT := $(BUILD_DIR)/colecogo.rel
LISTING := $(BUILD_DIR)/colecogo.lst
SYMBOLS := $(BUILD_DIR)/colecogo.sym
IHX := $(BUILD_DIR)/colecogo.ihx
PROGRAM := $(BUILD_DIR)/COLECOGO.COM

# Standalone harness for the cartridge scanner.  It shares cartscan.inc and
# cartpatch.inc with the loader but needs no Zephyr BDOS extensions, so it
# runs under an ordinary CP/M emulator and its results can be compared with
# the reference model in tools/scan_cartridge.py.
SCANTEST_SRC := $(SRC_DIR)/scantest.asm
SCANTEST_PROGRAM := $(BUILD_DIR)/SCANTEST.COM
TEST_CARTSCAN := $(TOOLS_DIR)/test_cartscan.py
SCAN_TEST_ROMS ?= $(BUILD_DIR)/scantest/IOTEST.ROM ../Software/disk1/8/dk.rom \
	../Software/disk1/8/zaxxon.rom

IHX_TO_COM := $(TOOLS_DIR)/ihx_to_com.py
CHECK_BUILD := $(TOOLS_DIR)/check_build.py

.PHONY: all clean check test scantest

all: $(PROGRAM) check

$(BUILD_DIR):
	mkdir -p $@

$(OBJECT) $(LISTING) $(SYMBOLS) &: $(SOURCE) $(INCLUDES) ../CPM2.2/src/layout/modes.inc | $(BUILD_DIR)
	$(SDASZ80) -I$(SRC_DIR) -I../CPM2.2/src $(ASFLAGS) $(OBJECT) $<

$(IHX): $(OBJECT)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(PROGRAM): $(IHX) $(IHX_TO_COM)
	$(PYTHON) $(IHX_TO_COM) $< $@

check: $(PROGRAM) $(LISTING) $(CHECK_BUILD)
	$(PYTHON) $(CHECK_BUILD) --listing $(LISTING) --ihx $(IHX) --com $(PROGRAM)

scantest: $(SCANTEST_PROGRAM)

$(BUILD_DIR)/scantest.rel: $(SCANTEST_SRC) $(INCLUDES) | $(BUILD_DIR)
	$(SDASZ80) -I$(SRC_DIR) -I../CPM2.2/src $(ASFLAGS) $@ $<

$(BUILD_DIR)/scantest.ihx: $(BUILD_DIR)/scantest.rel
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(SCANTEST_PROGRAM): $(BUILD_DIR)/scantest.ihx $(IHX_TO_COM)
	$(PYTHON) $(IHX_TO_COM) $< $@

# Runs the assembled scanner against the reference model.  Skips itself when
# no CP/M emulator is installed.
test: $(SCANTEST_PROGRAM) $(TEST_CARTSCAN) $(BUILD_DIR)/scantest/IOTEST.ROM
	$(PYTHON) $(TEST_CARTSCAN) --program $(SCANTEST_PROGRAM) $(SCAN_TEST_ROMS)

$(BUILD_DIR)/scantest/IOTEST.ROM: $(TOOLS_DIR)/make_io_test_rom.py | $(BUILD_DIR)
	@mkdir -p $(dir $@)
	$(PYTHON) $< $@

clean:
	rm -rf "$(BUILD_DIR)"
