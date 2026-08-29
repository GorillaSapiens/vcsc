# This file is covered under CC0-1.0. See examples/LICENSE.txt.

VCS_DIR ?= ../../../../libraries/vcs
VCSC ?= ../../../../driver/vcsc
TARGET := secam_enhanced_multisprite_asymmetric_228_interactive.bin
SOURCE := secam_enhanced_multisprite_asymmetric_228_interactive.c26
STARTUP := secam_enhanced_multisprite_asymmetric_228_interactive_startup.s26

all: $(TARGET)

$(TARGET): $(SOURCE) $(STARTUP) ../../multisprite_228_interactive_common.c26
	$(VCSC) -nostdlib -I $(VCS_DIR) -DMULTISPRITE_NO_RETAINED_PF_ROWS -T $(VCS_DIR)/vcs_8k_f8.cfg $(SOURCE) $(STARTUP) -o $@

play: $(TARGET)
	stella -format SECAM $(TARGET)

clean:
	rm -f $(TARGET) *.map *.lst *.sym *.cfg

.PHONY: all play clean
