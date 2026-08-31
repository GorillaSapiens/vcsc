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
SOURCE := fa2_diagnostic.c26
TARGET := fa2_diagnostic.bin

all: $(TARGET)

$(TARGET): $(SOURCE) $(COMMITTED_FONT_SUBSETS)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map fa2_diagnostic.map $(SOURCE) -o $@

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/status_font.c26 status_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/cart_type_font.c26 cart_type_glyphs ' FA2'

clean:
	rm -f fa2_diagnostic.bin fa2_diagnostic.map fa2_diagnostic.hex fa2_diagnostic.sym fa2_diagnostic.lst fa2_diagnostic.cfg

play: $(TARGET)
	stella -bs FA2 $(TARGET)

.PHONY: all clean play fonts
