# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PERL ?= perl
FONT_SUBSET_TOOL := $(VCS_DIR)/fonts/make_font_subset.pl
BIG_FONT := $(VCS_DIR)/fonts/big_ascii.c26
SMALL_FONT := $(VCS_DIR)/fonts/default_ascii.c26
FONT_SUBSET_DIR ?= .
COMMITTED_FONT_SUBSETS := status_font.c26 cart_type_font.c26
FONT_SUBSET_FLAGS := --license examples/LICENSE.txt --bank bank0
SOURCE := bankswitching_diagnostic.c26

all: ordinary superchip poisoned

ordinary: f8.bin f6.bin f4.bin

superchip: f8sc.bin f6sc.bin f4sc.bin

poisoned: poisoned.bin

f8.bin f6.bin f4.bin f8sc.bin f6sc.bin f4sc.bin poisoned.bin: $(SOURCE) $(COMMITTED_FONT_SUBSETS)

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/status_font.c26 status_big_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/cart_type_font.c26 status_small_glyphs ' F468SC?'

f8.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=2 \
		-Map f8.map $(SOURCE) -o $@

f6.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=4 \
		-Map f6.map $(SOURCE) -o $@

f4.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=8 \
		-Map f4.map $(SOURCE) -o $@

f8sc.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=2 -DSUPERCHIP_TEST \
		-Map f8sc.map $(SOURCE) -o $@

f6sc.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=4 -DSUPERCHIP_TEST \
		-Map f6sc.map $(SOURCE) -o $@

f4sc.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=8 -DSUPERCHIP_TEST \
		-Map f4sc.map $(SOURCE) -o $@

poisoned.bin: $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -DMAPPER_BANKS=2 -DSUPERCHIP_TEST -DPOISONED_RESULT \
		-Map poisoned.map $(SOURCE) -o $@

clean:
	rm -f f8.* f6.* f4.* f8sc.* f6sc.* f4sc.* poisoned.* \
		.bin .hex .map .sym .lst .cfg

play:
	for bin in $$(find . -type f -name '*.bin' | sort); do \
		stella "$$bin"; \
	done;

.PHONY: all ordinary superchip poisoned fonts clean play
