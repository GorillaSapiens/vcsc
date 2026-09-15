# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: joystick.bin

joystick.bin: joystick.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/4K/mapper.c26
	$(VCSC) -I $(VCS_DIR) -Map joystick.map joystick.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f joystick.bin joystick.hex joystick.map joystick.sym joystick.lst joystick.cfg

play:
	stella *.bin

.PHONY: all clean play
