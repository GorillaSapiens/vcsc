# This file is covered under CC0-1.0. See examples/LICENSE.txt.

VCSC ?= ../../../driver/vcsc
VCS_DIR ?= ../../../libraries/vcs

all: drive.bin

drive.bin: drive.c26 $(VCS_DIR)/driving_controller.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/fonts/big_hex.c26 $(VCS_DIR)/4K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs.cfg
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map drive.map drive.c26 -o $@

clean:
	rm -f drive.bin drive.map drive.lst drive.sym drive.cfg

play:
	stella -lc driving -rc driving *.bin

.PHONY: all clean play
