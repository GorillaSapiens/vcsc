# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCS_DIR ?= $(ROOT)/libraries/vcs
VCSC ?= $(ROOT)/driver/vcsc

TARGET := enhanced_multisprite_192_asymmetric.bin
SOURCE := enhanced_multisprite_192_asymmetric.c26
COMMON := $(ROOT)/examples/common/multisprite_interactive_common.c26
STARTUP := enhanced_multisprite_192_asymmetric_startup.s26

all: $(TARGET)

$(TARGET): $(SOURCE) $(STARTUP) $(COMMON) \
           $(VCS_DIR)/4K/mapper.c26 \
           $(VCS_DIR)/vcs.c26 \
           $(VCS_DIR)/frame_ntsc.c26 \
           $(VCS_DIR)/color_ntsc.c26 \
           $(VCS_DIR)/renderers/enhanced_multisprite_asymmetric/enhanced_multisprite.c26
	$(VCSC) -nostdlib -I $(VCS_DIR) -DVCS_NTSC_EXTENDED_VBLANK -DMULTISPRITE_NO_RETAINED_PF_ROWS -T $(VCS_DIR)/vcs.cfg $(SOURCE) $(STARTUP) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.cfg) $(TARGET:.bin=.lst) $(TARGET:.bin=.map) $(TARGET:.bin=.sym)

play: $(TARGET)
	stella -bs 4K $(TARGET)

.PHONY: all clean play
