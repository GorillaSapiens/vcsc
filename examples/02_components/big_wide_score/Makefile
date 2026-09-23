# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: big_wide_score.bin

big_wide_score.bin: big_wide_score.c26 $(VCS_DIR)/fonts/big_decimal.c26 $(VCS_DIR)/components/six_glyph_big_wide_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/2K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26
	$(VCSC) -I $(VCS_DIR) -I . -Map big_wide_score.map big_wide_score.c26 -o $@
	@test `wc -c < $@` -eq 2048

clean:
	rm -f big_wide_score.bin big_wide_score.hex big_wide_score.map big_wide_score.s26 big_wide_score.sym big_wide_score.lst big_wide_score.cfg

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
