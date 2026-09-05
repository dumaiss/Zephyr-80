BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON ?= python3

ASFLAGS ?= -o -l -s -w
LDFLAGS ?= -i -m

SOURCE := $(SRC_DIR)/colecogo.asm
OBJECT := $(BUILD_DIR)/colecogo.rel
LISTING := $(BUILD_DIR)/colecogo.lst
SYMBOLS := $(BUILD_DIR)/colecogo.sym
IHX := $(BUILD_DIR)/colecogo.ihx
PROGRAM := $(BUILD_DIR)/COLECOGO.COM

IHX_TO_COM := $(TOOLS_DIR)/ihx_to_com.py
CHECK_BUILD := $(TOOLS_DIR)/check_build.py

.PHONY: all clean check

all: $(PROGRAM) check

$(BUILD_DIR):
	mkdir -p $@

$(OBJECT) $(LISTING) $(SYMBOLS) &: $(SOURCE) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $(OBJECT) $<

$(IHX): $(OBJECT)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(PROGRAM): $(IHX) $(IHX_TO_COM)
	$(PYTHON) $(IHX_TO_COM) $< $@

check: $(PROGRAM) $(LISTING) $(CHECK_BUILD)
	$(PYTHON) $(CHECK_BUILD) --listing $(LISTING) --ihx $(IHX) --com $(PROGRAM)

clean:
	rm -rf "$(BUILD_DIR)"
