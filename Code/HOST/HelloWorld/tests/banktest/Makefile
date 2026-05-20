BUILD_DIR := build

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON ?= python3

ASFLAGS ?= -o -l -s
LDFLAGS ?= -i

STAGE1_SRC := banktest.asm
STAGE2_SRC := stage2.asm
IHX2INC := tools/ihx_to_stage2_inc.py

STAGE2_REL := $(BUILD_DIR)/stage2.rel
STAGE2_IHX := $(BUILD_DIR)/stage2.ihx
STAGE2_INC := $(BUILD_DIR)/stage2_blob.inc

BANKTEST_REL := $(BUILD_DIR)/banktest.rel
BANKTEST_IHX := $(BUILD_DIR)/banktest.ihx

.PHONY: all clean

all: $(BANKTEST_IHX)

$(BUILD_DIR):
	mkdir -p $@

$(STAGE2_REL): $(STAGE2_SRC) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $@ $<

$(STAGE2_IHX): $(STAGE2_REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(STAGE2_INC): $(STAGE2_IHX) $(IHX2INC)
	$(PYTHON) $(IHX2INC) $< 0x1000 $@

$(BANKTEST_REL): $(STAGE1_SRC) $(STAGE2_INC) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) -I$(BUILD_DIR) $@ $<

$(BANKTEST_IHX): $(BANKTEST_REL)
	$(SDLDZ80) $(LDFLAGS) $@ $<

clean:
	rm -rf "$(BUILD_DIR)"/*
