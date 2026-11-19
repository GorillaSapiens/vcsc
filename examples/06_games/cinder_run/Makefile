# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: cinder_run.bin

cinder_run.bin: cinder_run.c26 ../../_common/cinder_run_state.c26 ../../_common/cinder_run_pair.c26 ../../_common/cinder_run_wide.c26 $(VCS_DIR)/six_glyph_component.c26 $(VCS_DIR)/heart_score_component.c26 $(VCS_DIR)/fonts/whimsey_decimal.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/F6SC/mapper.c26 $(VCS_DIR)/4KSC/ram.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/playfield.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/sound_ntsc.c26
	$(VCSC) -I $(VCS_DIR) -Map cinder_run.map cinder_run.c26 -o $@
	@test `wc -c < $@` -eq 16384

clean:
	rm -f cinder_run.bin cinder_run.hex cinder_run.map cinder_run.sym cinder_run.lst cinder_run.cfg

play: all
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" -bs F6SC "$(CURDIR)/cinder_run.bin"

.PHONY: all clean play
