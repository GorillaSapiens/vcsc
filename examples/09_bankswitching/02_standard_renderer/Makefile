# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
RENDERER := $(VCS_DIR)/renderers/standard_4k_ntsc/standard_4k_ntsc_renderer.s26
SOURCE := banked_standard_renderer.c26

all: f8.bin

f8.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=2 -T $(VCS_DIR)/vcs.cfg -Map f8.map \
		$(SOURCE) $(RENDERER) -o $@

clean:
	rm -f f8.bin f8.hex f8.map f8.sym f8.lst f8.cfg

.PHONY: all clean
