# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: dual_score.bin

dual_score.bin: dual_score.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/three_plus_three_score_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/2K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs.cfg
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map dual_score.map dual_score.c26 -o $@
	@test `wc -c < $@` -eq 2048

clean:
	rm -f dual_score.bin dual_score.hex dual_score.map dual_score.s26 dual_score.sym dual_score.lst dual_score.cfg

play:
	stella *.bin

.PHONY: all clean play
