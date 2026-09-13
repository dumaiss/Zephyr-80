SRC_DIR := src
BUILD_DIR := build
SCRIPT := scripts/build_wincupl.sh

# WinCUPL under Wine, at its default install location in the Wine prefix.
# Override CUPL (and CUPLFLAGS) for a native cupl or another install.  -u names
# the device library by its Windows path, as CUPL.EXE sees it.
WINCUPL_EXE ?= $(HOME)/.wine/drive_c/WinCUPL/Shared/cupl.exe
ifneq ($(wildcard $(WINCUPL_EXE)),)
CUPL      ?= $(WINCUPL_EXE)
CUPLFLAGS ?= -jaxf -u C:\WinCUPL\Shared\cupl.dl
endif
export CUPL CUPLFLAGS

PLD_FILES := $(wildcard $(SRC_DIR)/*.pld)
DESIGNS := $(patsubst $(SRC_DIR)/%.pld,%,$(PLD_FILES))

.PHONY: all clean list $(DESIGNS)

ifneq ($(strip $(DESIGN)),)
all: design
else
all: $(DESIGNS)
endif

list:
	@printf '%s\n' $(DESIGNS)

$(DESIGNS):
	$(SCRIPT) "$(SRC_DIR)/$@.pld" "$(BUILD_DIR)/$@"

clean:
	rm -rf "$(BUILD_DIR)"/*

.PHONY: design
design:
	$(SCRIPT) "$(SRC_DIR)/$(DESIGN).pld" "$(BUILD_DIR)/$(DESIGN)"
