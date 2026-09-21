# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := player_color_181_poison_score_above_interactive.bin
SOURCE := player_color_181_poison_score_above_interactive.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/color_ntsc.c26 \
           $(VCS_DIR)/frame_ntsc.c26 \
           $(VCS_DIR)/playfield.c26 \
           $(VCS_DIR)/components/poison_debug_score/poison_debug_score.c26 \
           $(VCS_DIR)/renderers/all_five/all_five.c26 \
           $(ROOT)/examples/_common/poison_score_controls.c26 \
           $(ROOT)/examples/_common/player_color_181_interactive_common.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

play:
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)"/*.bin

.PHONY: all clean play
