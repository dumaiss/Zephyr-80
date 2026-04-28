DEVICE ?= PIC18F57Q84
TARGET := io_controller

BUILD_DIR := build
SRC_DIR := src
INC_DIR := include
TEST_DIR := tests
TEST_BUILD_DIR := $(BUILD_DIR)/tests

XC8 ?= xc8-cc
HOST_CC ?= gcc

FIRMWARE_SRCS := $(wildcard $(SRC_DIR)/*.c)
TEST_SRCS := $(SRC_DIR)/io_controller.c $(TEST_DIR)/io_controller_test.c

FIRMWARE_HEX := $(BUILD_DIR)/$(TARGET).hex
TEST_BIN := $(TEST_BUILD_DIR)/io_controller_test

XC8FLAGS ?= -mcpu=$(DEVICE) -I$(INC_DIR)
HOST_CFLAGS := -std=c11 -Wall -Wextra -Werror -I$(INC_DIR)

.PHONY: all clean test size

all: $(FIRMWARE_HEX)

$(BUILD_DIR):
	mkdir -p $@

$(TEST_BUILD_DIR): | $(BUILD_DIR)
	mkdir -p $@

$(FIRMWARE_HEX): $(FIRMWARE_SRCS) | $(BUILD_DIR)
	$(XC8) $(XC8FLAGS) $^ -o $(BUILD_DIR)/$(TARGET)

$(TEST_BIN): $(TEST_SRCS) | $(TEST_BUILD_DIR)
	$(HOST_CC) $(HOST_CFLAGS) $^ -o $@

test: $(TEST_BIN)
	$(TEST_BIN)

size: $(FIRMWARE_HEX)
	@ls -lh "$(BUILD_DIR)"

clean:
	rm -rf "$(BUILD_DIR)"/*
