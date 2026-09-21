# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: paddleball.bin

paddleball.bin: paddleball.c26 $(VCS_DIR)/components/two_paddles.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/components/three_plus_three_score_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/sound_ntsc.c26 $(VCS_DIR)/4K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26
	$(VCSC) -I $(VCS_DIR) -I . -Map paddleball.map paddleball.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f paddleball.bin paddleball.hex paddleball.map paddleball.s26 paddleball.sym paddleball.lst paddleball.cfg

play:
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)"/*.bin

.PHONY: all clean play
