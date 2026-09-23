# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: blank_noasm.bin

blank_noasm.bin: blank_noasm.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/4K/mapper.c26
	$(VCSC) -I $(VCS_DIR) -Map blank_noasm.map blank_noasm.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f blank_noasm.bin blank_noasm.hex blank_noasm.map blank_noasm.sym blank_noasm.lst blank_noasm.cfg

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
