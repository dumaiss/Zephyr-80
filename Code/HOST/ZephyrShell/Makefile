# ZephyrShell -- the first native ZephyrOS command environment.

ZCC      ?= zcc
SDASZ80  ?= sdasz80
SDLDZ80  ?= sdldz80
HOST_CC  ?= cc
PYTHON   ?= python3

BUILD    := build
ZEPHYRC  ?= ../ZephyrC
CPM      ?= ../CPM2.2
CFLAGS   := +cpm -compiler=sdcc -O2 -pragma-define:CRT_ENABLE_COMMANDLINE=0 \
	-I$(ZEPHYRC)/include -Isrc
LINK     := -L$(ZEPHYRC)/build -lzephyr
SOURCES  := $(wildcard src/*.c)

.PHONY: all shell bootstrap host-tests test clean
.DEFAULT_GOAL := all

all: shell bootstrap
shell: $(BUILD)/ZSH.COM
bootstrap: $(BUILD)/ccp-zshell.bin
test: host-tests all

$(BUILD):
	mkdir -p $@

$(ZEPHYRC)/build/zephyr.lib:
	$(MAKE) -C $(ZEPHYRC) lib

$(BUILD)/ZSH.COM: $(SOURCES) $(wildcard src/*.h) $(ZEPHYRC)/build/zephyr.lib | $(BUILD)
	$(ZCC) $(CFLAGS) $(SOURCES) $(LINK) -o $@

$(BUILD)/zshell_ccp.rel: stubs/ccp.asm | $(BUILD)
	$(SDASZ80) -o -l -s $@ $<

$(BUILD)/zshell_ccp.ihx: $(BUILD)/zshell_ccp.rel
	$(SDLDZ80) -i $@ $< >/dev/null

$(BUILD)/ccp-zshell.bin: $(BUILD)/zshell_ccp.ihx $(CPM)/tools/hex_to_ccp.py
	$(PYTHON) $(CPM)/tools/hex_to_ccp.py --hex $< --base 0xe400 \
		--size 0x800 --output $@

host-tests: $(BUILD)/zshell-host-test
	$(BUILD)/zshell-host-test

$(BUILD)/zshell-host-test: tests/test_shell.c tests/mock_fs.c \
		src/parser.c src/path.c src/builtins.c src/status.c src/tinyio.c \
		src/exec.c | $(BUILD)
	$(HOST_CC) -std=c99 -Wall -Wextra -Werror -D__z88dk_fastcall= -DZSH_HOST_TEST \
		-I$(ZEPHYRC)/include -Isrc -Itests \
		tests/test_shell.c tests/mock_fs.c src/parser.c src/path.c \
		src/builtins.c src/status.c src/tinyio.c src/exec.c -o $@

clean:
	rm -rf $(BUILD)
