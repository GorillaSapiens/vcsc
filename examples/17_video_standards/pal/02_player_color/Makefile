# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := pal_player_color_228_interactive.bin
SOURCE := pal_player_color_228_interactive.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/frame_pal.c26 $(VCS_DIR)/frame_50hz_component.c26 $(VCS_DIR)/renderers/player_color/player_color.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

play: $(TARGET)
	stella -format PAL $(TARGET)

.PHONY: all clean play
