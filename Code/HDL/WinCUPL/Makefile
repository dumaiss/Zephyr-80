SRC_DIR := src
BUILD_DIR := build
SCRIPT := scripts/build_wincupl.sh

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
