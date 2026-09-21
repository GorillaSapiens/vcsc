# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := heart_score_above_interactive.bin

all: $(TARGET)

$(TARGET): heart_score_above_interactive.c26 $(VCS_DIR)/components/heart_score_component.c26 $(VCS_DIR)/renderers/player_color/player_color.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/playfield.c26 $(VCS_DIR)/4K/mapper.c26 $(ROOT)/examples/_common/heart_score_controls.c26 $(ROOT)/examples/_common/heart_score_player_color_181_common.c26
	$(VCSC) -I $(VCS_DIR) -I . -Map heart_score_above_interactive.map heart_score_above_interactive.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) *.hex *.map *.s26 *.o26 *.sym *.lst *.cfg

play: $(TARGET)
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(TARGET)"

.PHONY: all clean play
