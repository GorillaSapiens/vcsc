# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: four_player_paddleball.bin

four_player_paddleball.bin: four_player_paddleball.c26 $(VCS_DIR)/components/four_paddles.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/components/three_plus_three_score_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/sound_ntsc.c26 $(VCS_DIR)/4K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26
	$(VCSC) -I $(VCS_DIR) -I . -Map four_player_paddleball.map four_player_paddleball.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f four_player_paddleball.bin four_player_paddleball.hex four_player_paddleball.map four_player_paddleball.s26 four_player_paddleball.sym four_player_paddleball.lst four_player_paddleball.cfg

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
