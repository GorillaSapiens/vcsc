# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGET := ntsc_enhanced_multisprite_asymmetric_192_interactive.bin
SOURCE := ntsc_enhanced_multisprite_asymmetric_192_interactive.c26
STARTUP := $(ROOT)/examples/04_renderers/enhanced_multisprite/no_score_asymmetric/enhanced_multisprite_192_asymmetric_startup.s26
all: $(TARGET)
$(TARGET): $(SOURCE) $(STARTUP)
	$(VCSC) -nostdlib -I $(VCS_DIR) -DVCS_NTSC_EXTENDED_VBLANK -DMULTISPRITE_NO_RETAINED_PF_ROWS $(SOURCE) $(STARTUP) -o $@
	@test `wc -c < $@` -eq 4096
play: $(TARGET)
	stella -userdir "$(CURDIR)" -format NTSC -bs 4K "$(CURDIR)/$(TARGET)"
clean:
	rm -f $(TARGET) *.map *.lst *.sym *.cfg *.hex *.s26 *.o26
.PHONY: all play clean
