# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: heart_score.bin

heart_score.bin: heart_score.c26 $(VCS_DIR)/heart_score_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/2K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26
	$(VCSC) -I $(VCS_DIR) -I . -Map heart_score.map heart_score.c26 -o $@
	@test `wc -c < $@` -eq 2048

clean:
	rm -f heart_score.bin heart_score.hex heart_score.map heart_score.s26 heart_score.sym heart_score.lst heart_score.cfg

play:
	stella *.bin

.PHONY: all clean play
