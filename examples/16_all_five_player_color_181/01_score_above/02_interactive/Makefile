# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGET := all_five_player_color_181_score_above_interactive.bin
SOURCE := all_five_player_color_181_score_above_interactive.c26
all: $(TARGET)
$(TARGET): $(SOURCE) $(VCS_DIR)/renderers/all_five_player_color_181/all_five_player_color_181.c26 $(VCS_DIR)/six_glyph_component.c26 $(VCS_DIR)/fonts/default_decimal.c26 ../../../common/all_five_player_color_181_interactive_common.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096
clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)
.PHONY: all clean
