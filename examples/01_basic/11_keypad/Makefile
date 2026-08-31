# This file is covered under CC0-1.0. See examples/LICENSE.txt.

VCSC ?= ../../../driver/vcsc
VCS_DIR ?= ../../../libraries/vcs

all: keypad.bin

keypad.bin: keypad.c26 $(VCS_DIR)/keypad_controller.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/4K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs.cfg
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map keypad.map keypad.c26 -o $@

clean:
	rm -f keypad.bin keypad.map keypad.lst keypad.sym keypad.cfg

play:
	stella *.bin

.PHONY: all clean play
