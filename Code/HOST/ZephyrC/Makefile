# ZephyrC -- the C library for Zephyr-80 programs.
#
#   make            library, example and tests
#   make lib        build/zephyr.lib
#   make examples   build/MANDEL.COM
#   make tests      host tests and all test .COM files, including FSTEST.COM
#
# z88dk is a snap on the development host and cannot see /tmp: keep build
# directories inside the home tree.

ZCC     ?= zcc
Z80ASM  ?= z88dk-z80asm
SDASZ80 ?= sdasz80
SDLDZ80 ?= sdldz80
PYTHON  ?= python3
HOST_CC ?= cc

BUILD := build
OBJ   := $(BUILD)/obj
GEN   := $(BUILD)/gen
LIB   := $(BUILD)/zephyr.lib

CFLAGS := +cpm -compiler=sdcc -O2 -Iinclude -Isrc
LINK   := -L$(BUILD) -lzephyr

HEADERS  := $(wildcard include/zephyr/*.h) src/zep_internal.h
LIB_OBJS := $(patsubst src/%.c,$(OBJ)/%.o,$(wildcard src/*.c)) \
            $(patsubst src/%.asm,$(OBJ)/%.o,$(wildcard src/*.asm)) \
            $(OBJ)/zep_stub_image.o

.PHONY: all lib examples tests host-tests clean
.SECONDARY:

all: lib examples tests
lib: $(LIB)
examples: $(BUILD)/MANDEL.COM
tests: host-tests $(BUILD)/FSTEST.COM $(BUILD)/TICKTEST.COM $(BUILD)/SERTEST.COM $(BUILD)/VDPTEST.COM $(BUILD)/TIMTEST.COM $(BUILD)/TONETEST.COM $(BUILD)/PCTRACE.COM $(BUILD)/IRQTEST.COM
host-tests: $(BUILD)/fs-host-test
	$(BUILD)/fs-host-test

$(OBJ) $(GEN):
	mkdir -p $@

$(OBJ)/%.o: src/%.c $(HEADERS) | $(OBJ)
	$(ZCC) $(CFLAGS) -c $< -o $@

$(OBJ)/%.o: src/%.asm | $(OBJ)
	$(ZCC) $(CFLAGS) -c $< -o $@

# The common-memory stubs are assembled for E300h and embedded as a C array.
$(GEN)/zep_stubs.ihx: stubs/zep_stubs.asm | $(GEN)
	$(SDASZ80) -o -l -s $(GEN)/zep_stubs.rel $<
	$(SDLDZ80) -i $@ $(GEN)/zep_stubs.rel >/dev/null

$(GEN)/zep_stub_image.c: $(GEN)/zep_stubs.ihx tools/ihx2c.py
	$(PYTHON) tools/ihx2c.py $< 0xE300 $@ zep__stub_image

$(OBJ)/zep_stub_image.o: $(GEN)/zep_stub_image.c | $(OBJ)
	$(ZCC) $(CFLAGS) -c $< -o $@

$(LIB): $(LIB_OBJS)
	rm -f $@
	$(Z80ASM) -x$(BUILD)/zephyr $(LIB_OBJS)

$(BUILD)/MANDEL.COM: examples/mandel/mandel.c $(LIB)
	$(ZCC) $(CFLAGS) $< $(LINK) -o $@

$(BUILD)/TICKTEST.COM: tests/ticktest.c tests/tick_call.asm $(LIB)
	$(ZCC) $(CFLAGS) tests/ticktest.c tests/tick_call.asm $(LINK) -o $@

$(BUILD)/SERTEST.COM: tests/sertest.c $(LIB)
	$(ZCC) $(CFLAGS) $< $(LINK) -o $@

$(BUILD)/FSTEST.COM: tests/fstest.c $(LIB)
	$(ZCC) $(CFLAGS) $< $(LINK) -o $@

$(BUILD)/fs-host-test: tests/fs_host.c src/zep_fs.c include/zephyr/fs.h src/zep_internal.h | $(BUILD)
	$(HOST_CC) -std=c99 -Wall -Wextra -Wno-pointer-to-int-cast \
		-D__z88dk_fastcall= -Iinclude -Isrc tests/fs_host.c src/zep_fs.c -o $@

$(BUILD)/VDPTEST.COM: tests/vdptest.c $(LIB)
	$(ZCC) $(CFLAGS) $< $(LINK) -o $@

$(BUILD)/TIMTEST.COM: tests/timtest.c $(LIB)
	$(ZCC) $(CFLAGS) $< $(LINK) -o $@

$(BUILD)/TONETEST.COM: tests/tonetest.c $(LIB)
	$(ZCC) $(CFLAGS) $< $(LINK) -o $@

$(BUILD)/PCTRACE.COM: tests/pctrace.c tests/pc_probe.asm $(LIB)
	$(ZCC) $(CFLAGS) tests/pctrace.c tests/pc_probe.asm $(LINK) -o $@

$(BUILD)/IRQTEST.COM: tests/irqtest.c tests/irq_probe.asm tests/irq_probe.h $(LIB)
	$(ZCC) $(CFLAGS) tests/irqtest.c tests/irq_probe.asm $(LINK) -m -o $@

clean:
	rm -rf $(BUILD)
