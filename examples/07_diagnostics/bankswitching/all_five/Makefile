# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := banked_all_five.c26

all: f8.bin

f8.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=2 -Map f8.map \
		$(SOURCE) -o $@

clean:
	rm -f f8.bin f8.hex f8.map f8.sym f8.lst f8.cfg

play: f8.bin
	echo WARNING: ignoring user specific settings
	stella \
		-dev.tv.jitter 0 \
		-dev.settings 1 \
		-dev.stats 1 \
		-dev.detectedinfo 1 \
		-dev.ramrandom 1 \
		-dev.bankrandom 1 \
		-basedir "$(CURDIR)" -userdir "$(CURDIR)" -bs F8 "$(CURDIR)/f8.bin"

.PHONY: all clean play
