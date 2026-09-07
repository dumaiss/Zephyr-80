BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON ?= python3
ASFLAGS ?= -o -l -s
LDFLAGS ?= -i

SOURCE := $(SRC_DIR)/vgmplay.asm
OBJECT := $(BUILD_DIR)/vgmplay.rel
IHX := $(BUILD_DIR)/vgmplay.ihx
PROGRAM := $(BUILD_DIR)/VGMPLAY.COM
IHX_TO_COM := $(TOOLS_DIR)/ihx_to_com.py

.PHONY: all clean

all: $(PROGRAM)

$(BUILD_DIR):
	mkdir -p $@

$(OBJECT): $(SOURCE) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $@ $<

$(IHX): $(OBJECT)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(PROGRAM): $(IHX) $(IHX_TO_COM)
	$(PYTHON) $(IHX_TO_COM) $< $@

clean:
	rm -rf $(BUILD_DIR)
