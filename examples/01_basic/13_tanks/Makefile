# This file is covered under CC0-1.0. See examples/LICENSE.txt.

VCSC ?= ../../../driver/vcsc
VCS_DIR ?= ../../../libraries/vcs

all: tanks.bin

tanks.bin: tanks.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/sound_ntsc.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/three_plus_three_score_component.c26 $(VCS_DIR)/F8SC/mapper.c26 $(VCS_DIR)/4KSC/ram.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs.cfg
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map tanks.map tanks.c26 -o $@

clean:
	rm -f tanks.bin tanks.map tanks.lst tanks.sym tanks.cfg

play:
	stella *.bin

.PHONY: all clean play
