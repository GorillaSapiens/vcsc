# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCS_DIR ?= $(ROOT)/libraries/vcs
VCSC ?= $(ROOT)/driver/vcsc

TARGET := multisprite_181_score_below_interactive.bin
SOURCE := multisprite_181_score_below_interactive.c26
COMMON := $(ROOT)/examples/common/multisprite_interactive_common.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(COMMON) ../../fixed_six_digit_controls_compact.c26 \
           $(VCS_DIR)/vcs.c26 \
           $(VCS_DIR)/frame_ntsc.c26 \
           $(VCS_DIR)/color_ntsc.c26 \
           $(VCS_DIR)/renderers/multisprite/multisprite.c26
	$(VCSC) -I $(VCS_DIR) -Wa,--illegals $(SOURCE) -o $@

clean:
	rm -f $(TARGET) $(TARGET:.bin=.cfg) $(TARGET:.bin=.lst) $(TARGET:.bin=.map) $(TARGET:.bin=.sym)

play:
	stella *.bin

.PHONY: all clean play
