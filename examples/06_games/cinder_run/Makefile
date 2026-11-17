# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: cinder_run.bin

cinder_run.bin: cinder_run.c26 $(VCS_DIR)/renderers/player_color/player_color.c26 $(VCS_DIR)/six_glyph_component.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/4K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/playfield.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/sound_ntsc.c26
	$(VCSC) -I $(VCS_DIR) -Map cinder_run.map $< -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f cinder_run.bin cinder_run.hex cinder_run.map cinder_run.sym cinder_run.lst cinder_run.cfg

play: all
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" -bs 4K "$(CURDIR)/cinder_run.bin"

.PHONY: all clean play
