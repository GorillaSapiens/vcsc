# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
COMMON := $(ROOT)/examples/common/multisprite_228_interactive_common.c26

TARGET := pal_multisprite_228_interactive.bin
SOURCE := pal_multisprite_228_interactive.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/frame_pal.c26 $(VCS_DIR)/frame_50hz_component.c26 $(VCS_DIR)/renderers/multisprite/multisprite.c26 $(COMMON)
	$(VCSC) -I $(VCS_DIR) -Wa,--illegals -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

play: $(TARGET)
	stella -format PAL $(TARGET)

.PHONY: all clean play
