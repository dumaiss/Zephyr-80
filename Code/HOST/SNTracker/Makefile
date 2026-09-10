BUILD_DIR := build
SRC_DIR := src
TOOLS_DIR := tools
SONG_DIR := songs

SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON ?= python3
TRANSPOSE ?= 24
ASFLAGS ?= -o -l -s
LDFLAGS ?= -i

SOURCE := $(SRC_DIR)/tracker.asm
MODULES := $(SRC_DIR)/player.asm $(SRC_DIR)/sn76489.asm $(SRC_DIR)/ztr.asm $(SRC_DIR)/ui.asm
PLATFORM_INC := ../CPM2.2/src/platform_zephyr80.inc
OBJECT := $(BUILD_DIR)/tracker.rel
IHX := $(BUILD_DIR)/tracker.ihx
PROGRAM := $(BUILD_DIR)/SNTRACK.COM
IHX_TO_COM := ../VGMPlayer/tools/ihx_to_com.py
FURNACE_SONG := $(SONG_DIR)/night-market.txt
ZTR_SONG := $(SONG_DIR)/night-market.ztr
CSM_SOURCE := $(SONG_DIR)/RunawayCircuit.csm
CSM_ZTR := $(SONG_DIR)/RunawayCircuit.ztr

.DEFAULT_GOAL := all
.PHONY: all clean song csm-song csm-dump validate dump test

all: $(PROGRAM) $(ZTR_SONG) $(CSM_ZTR)

$(BUILD_DIR):
	mkdir -p $@

$(OBJECT): $(SOURCE) $(MODULES) $(PLATFORM_INC) | $(BUILD_DIR)
	$(SDASZ80) $(ASFLAGS) $@ $<

$(IHX): $(OBJECT)
	$(SDLDZ80) $(LDFLAGS) $@ $<

$(PROGRAM): $(IHX) $(IHX_TO_COM)
	$(PYTHON) $(IHX_TO_COM) $< $@

$(ZTR_SONG): $(FURNACE_SONG) $(TOOLS_DIR)/fur2ztr.py
	$(PYTHON) $(TOOLS_DIR)/fur2ztr.py --transpose $(TRANSPOSE) $< $@

$(CSM_ZTR): $(CSM_SOURCE) $(TOOLS_DIR)/csmc.py $(TOOLS_DIR)/csm_language.py $(TOOLS_DIR)/fur2ztr.py
	$(PYTHON) $(TOOLS_DIR)/csmc.py $< $@

song: $(ZTR_SONG)

csm-song: $(CSM_ZTR)

csm-dump: $(CSM_ZTR)
	$(PYTHON) $(TOOLS_DIR)/fur2ztr.py --dump $(CSM_ZTR)

validate:
	$(PYTHON) $(TOOLS_DIR)/fur2ztr.py --transpose $(TRANSPOSE) --validate $(FURNACE_SONG)

dump: $(ZTR_SONG)
	$(PYTHON) $(TOOLS_DIR)/fur2ztr.py --dump $(ZTR_SONG)

test:
	$(PYTHON) $(TOOLS_DIR)/test_fur2ztr.py
	$(PYTHON) $(TOOLS_DIR)/test_csmc.py

clean:
	rm -rf "$(BUILD_DIR)"
