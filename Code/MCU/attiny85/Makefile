MCU := attiny85
F_CPU := 1000000UL

TARGET := firmware
BUILD_DIR := build
SRC_DIR := src
INC_DIR := include
TEST_DIR := tests
TEST_BUILD_DIR := $(BUILD_DIR)/tests

CC := avr-gcc
HOST_CC ?= gcc
OBJCOPY := avr-objcopy
SIZE := avr-size
AVRDUDE := avrdude

CFLAGS := -std=c11 -Wall -Wextra -Werror -Os
CFLAGS += -mmcu=$(MCU) -DF_CPU=$(F_CPU)
CFLAGS += -I$(INC_DIR)
HOST_CFLAGS := -std=c11 -Wall -Wextra -Werror -I$(INC_DIR)

LDFLAGS := -mmcu=$(MCU)

PROGRAMMER ?= usbtiny
PORT ?=
AVRDUDE_FLAGS := -p $(MCU) -c $(PROGRAMMER)
ifneq ($(PORT),)
AVRDUDE_FLAGS += -P $(PORT)
endif

LOW_FUSE ?= 0x62
HIGH_FUSE ?= 0xdf
EXT_FUSE ?= 0xff

SRCS := $(wildcard $(SRC_DIR)/*.c)
OBJS := $(patsubst $(SRC_DIR)/%.c,$(BUILD_DIR)/%.o,$(SRCS))
ELF := $(BUILD_DIR)/$(TARGET).elf
HEX := $(BUILD_DIR)/$(TARGET).hex
TEST_BIN := $(TEST_BUILD_DIR)/power_controller_test
TEST_SRCS := $(SRC_DIR)/power_controller.c $(TEST_DIR)/power_controller_test.c

.PHONY: all clean flash fuses size test

all: $(HEX) size

$(BUILD_DIR):
	mkdir -p $@

$(TEST_BUILD_DIR): | $(BUILD_DIR)
	mkdir -p $@

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.c | $(BUILD_DIR)
	$(CC) $(CFLAGS) -c $< -o $@

$(ELF): $(OBJS)
	$(CC) $(LDFLAGS) $^ -o $@

$(HEX): $(ELF)
	$(OBJCOPY) -O ihex -R .eeprom $< $@

size: $(ELF)
	$(SIZE) --mcu=$(MCU) --format=avr $<

$(TEST_BIN): $(TEST_SRCS) | $(TEST_BUILD_DIR)
	$(HOST_CC) $(HOST_CFLAGS) $^ -o $@

test: $(TEST_BIN)
	$(TEST_BIN)

flash: $(HEX)
	$(AVRDUDE) $(AVRDUDE_FLAGS) -U flash:w:$(HEX):i

fuses:
	$(AVRDUDE) $(AVRDUDE_FLAGS) \
		-U lfuse:w:$(LOW_FUSE):m \
		-U hfuse:w:$(HIGH_FUSE):m \
		-U efuse:w:$(EXT_FUSE):m

clean:
	rm -rf $(BUILD_DIR)/*
