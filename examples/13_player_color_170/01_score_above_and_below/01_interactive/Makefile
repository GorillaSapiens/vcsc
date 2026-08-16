# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCS_DIR ?= $(ROOT)/libraries/vcs
VCSC ?= $(ROOT)/driver/vcsc

TARGET := player_color_170_score_above_and_below_interactive.bin
SOURCE := player_color_170_score_above_and_below_interactive.c26

all: $(TARGET)

$(TARGET): $(SOURCE) \
           $(VCS_DIR)/vcs.c26 \
           $(VCS_DIR)/frame_ntsc.c26 \
           $(VCS_DIR)/color_ntsc.c26 \
           $(VCS_DIR)/playfield.c26 \
           $(VCS_DIR)/renderers/player_color/player_color.c26 \
           $(VCS_DIR)/six_glyph_component.c26 \
           $(VCS_DIR)/fonts/default_decimal.c26
	$(VCSC) -I $(VCS_DIR) $(SOURCE) -o $@

clean:
	rm -f $(TARGET) $(TARGET:.bin=.cfg) $(TARGET:.bin=.lst) $(TARGET:.bin=.map) $(TARGET:.bin=.sym)

play:
	stella *.bin

.PHONY: all clean play
