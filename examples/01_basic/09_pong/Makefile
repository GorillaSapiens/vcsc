# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: pong.bin

pong.bin: pong.c26 $(VCS_DIR)/two_paddles.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/three_plus_three_score_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/vcs_4k.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs.cfg
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map pong.map pong.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f pong.bin pong.hex pong.map pong.s26 pong.sym pong.lst pong.cfg

.PHONY: all clean
