TARGET = main
BUILD_DIR = build
ROM_SIZE = 0x2000
ROM_FILL = 0xff
OBJCOPY = objcopy

AS = sdasz80
LD = sdldz80

ASFLAGS = -plosgff
LDFLAGS = -b _CODE=0x0000
BINFLAGS = -I ihex -O binary --gap-fill=$(ROM_FILL) --pad-to=$(ROM_SIZE)

all: $(BUILD_DIR)/$(TARGET).ihx

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(BUILD_DIR)/$(TARGET).rel: src/$(TARGET).s | $(BUILD_DIR)
	$(AS) $(ASFLAGS) -o $(BUILD_DIR)/$(TARGET).rel src/$(TARGET).s

$(BUILD_DIR)/$(TARGET).ihx: $(BUILD_DIR)/$(TARGET).rel
	$(LD) -i $(BUILD_DIR)/$(TARGET) $(BUILD_DIR)/$(TARGET).rel

$(BUILD_DIR)/$(TARGET).bin: $(BUILD_DIR)/$(TARGET).ihx
	$(OBJCOPY) $(BINFLAGS) $(BUILD_DIR)/$(TARGET).ihx $(BUILD_DIR)/$(TARGET).bin

bin: $(BUILD_DIR)/$(TARGET).bin

clean:
	rm -rf $(BUILD_DIR)

.PHONY: clean all bin
