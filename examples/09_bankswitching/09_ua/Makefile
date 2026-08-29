# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PERL ?= perl
FONT_SUBSET_TOOL := $(VCS_DIR)/fonts/make_font_subset.pl
BIG_FONT := $(VCS_DIR)/fonts/big_ascii.c26
SMALL_FONT := $(VCS_DIR)/fonts/default_ascii.c26
FONT_SUBSET_DIR ?= .
COMMITTED_FONT_SUBSETS := ua_status_font.c26 ua_cart_type_font.c26
FONT_SUBSET_FLAGS := --license examples/LICENSE.txt --bank bank0
TARGETS := ua_diagnostic.bin uasw_diagnostic.bin

all: $(TARGETS)

ua_diagnostic.bin: ua_diagnostic.c26 ../../common/ua_diagnostic_common.c26
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map ua_diagnostic.map ua_diagnostic.c26 -o $@

uasw_diagnostic.bin: uasw_diagnostic.c26 ../../common/ua_diagnostic_common.c26
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map uasw_diagnostic.map uasw_diagnostic.c26 -o $@

$(TARGETS): $(COMMITTED_FONT_SUBSETS)

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/ua_status_font.c26 status_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/ua_cart_type_font.c26 cart_type_glyphs ' UASW'

clean:
	rm -f ua_diagnostic.bin ua_diagnostic.map ua_diagnostic.hex ua_diagnostic.sym ua_diagnostic.lst ua_diagnostic.cfg
	rm -f uasw_diagnostic.bin uasw_diagnostic.map uasw_diagnostic.hex uasw_diagnostic.sym uasw_diagnostic.lst uasw_diagnostic.cfg

play: play-ua play-uasw

play-ua: ua_diagnostic.bin
	stella -bs UA ua_diagnostic.bin

play-uasw: uasw_diagnostic.bin
	stella -bs UASW uasw_diagnostic.bin

.PHONY: all clean play-ua play-uasw fonts
