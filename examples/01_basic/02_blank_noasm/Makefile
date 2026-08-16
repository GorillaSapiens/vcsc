# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: blank_noasm.bin

blank_noasm.bin: blank_noasm.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs_4k.cfg
	$(VCSC) -I $(VCS_DIR) -Map blank_noasm.map blank_noasm.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f blank_noasm.bin blank_noasm.hex blank_noasm.map blank_noasm.sym blank_noasm.lst blank_noasm.cfg

play:
	stella *.bin

.PHONY: all clean play
