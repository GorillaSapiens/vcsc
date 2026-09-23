# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: joystick.bin

joystick.bin: joystick.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/frame_ntsc.c26 \
              $(VCS_DIR)/color_ntsc.c26 \
              $(VCS_DIR)/renderers/all_five/all_five.c26
	$(VCSC) -I $(VCS_DIR) -Map joystick.map joystick.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f joystick.bin joystick.hex joystick.map joystick.s26 *.o26 joystick.sym joystick.lst joystick.cfg

play:
	echo WARNING: ignoring user specific settings
	stella \
		-dev.tv.jitter 0 \
		-dev.settings 1 \
		-dev.stats 1 \
		-dev.detectedinfo 1 \
		-dev.ramrandom 1 \
		-dev.bankrandom 1 \
		-basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)"/*.bin

.PHONY: all clean play
