# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCS_DIR ?= $(ROOT)/libraries/vcs
VCSC ?= $(ROOT)/driver/vcsc

TARGET := enhanced_multisprite_192_asymmetric.bin
SOURCE := enhanced_multisprite_192_asymmetric.c26
COMMON := $(ROOT)/examples/common/multisprite_interactive_common.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(COMMON) \
           $(VCS_DIR)/vcs_8k_f8sc.c26 \
           $(VCS_DIR)/superchip.c26 \
           $(VCS_DIR)/vcs.c26 \
           $(VCS_DIR)/frame_ntsc.c26 \
           $(VCS_DIR)/color_ntsc.c26 \
           $(VCS_DIR)/renderers/enhanced_multisprite_asymmetric/enhanced_multisprite.c26
	$(VCSC) -I $(VCS_DIR) -DVCS_NTSC_EXTENDED_VBLANK -T $(VCS_DIR)/vcs.cfg $(SOURCE) -o $@

clean:
	rm -f $(TARGET) $(TARGET:.bin=.cfg) $(TARGET:.bin=.lst) $(TARGET:.bin=.map) $(TARGET:.bin=.sym)

play: $(TARGET)
	stella -bs F8SC $(TARGET)

.PHONY: all clean play
