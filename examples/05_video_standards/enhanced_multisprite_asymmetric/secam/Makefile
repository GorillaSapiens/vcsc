# This file is covered under CC0-1.0. See examples/LICENSE.txt.

VCS_DIR ?= ../../../../libraries/vcs
VCSC ?= ../../../../driver/vcsc
TARGET := secam_enhanced_multisprite_asymmetric_228_interactive.bin
SOURCE := secam_enhanced_multisprite_asymmetric_228_interactive.c26
STARTUP := secam_enhanced_multisprite_asymmetric_228_interactive_startup.s26

all: $(TARGET)

$(TARGET): $(SOURCE) $(STARTUP) ../../../_common/multisprite_228_interactive_common.c26
	$(VCSC) -nostdlib -I $(VCS_DIR) -DMULTISPRITE_NO_RETAINED_PF_ROWS $(SOURCE) $(STARTUP) -o $@

play: $(TARGET)
	echo WARNING: ignoring user specific settings
	stella \
		-dev.tv.jitter 0 \
		-dev.settings 1 \
		-dev.stats 1 \
		-dev.detectedinfo 1 \
		-dev.ramrandom 1 \
		-dev.bankrandom 1 \
		-basedir "$(CURDIR)" -userdir "$(CURDIR)" -format SECAM "$(CURDIR)/$(TARGET)"

clean:
	rm -f $(TARGET) *.map *.lst *.sym *.cfg

.PHONY: all play clean
