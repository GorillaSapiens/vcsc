# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCSLIB ?= $(ROOT)/libraries/vcs
PERL ?= perl
FONT_SUBSET_TOOL := $(VCSLIB)/fonts/make_font_subset.pl
BIG_FONT := $(VCSLIB)/fonts/big_ascii.c26
SMALL_FONT := $(VCSLIB)/fonts/default_ascii.c26
FONT_SUBSET_DIR ?= .
COMMITTED_FONT_SUBSETS := status_font.c26 cart_type_font.c26
FONT_SUBSET_FLAGS := --license examples/LICENSE.txt 
TARGET = 4ksc_diagnostic.bin
SOURCE = 4ksc_diagnostic.c26

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCSLIB) -Map $(@:.bin=.map) $< -o $@

$(TARGET): $(COMMITTED_FONT_SUBSETS)

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/status_font.c26 status_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/cart_type_font.c26 cart_type_glyphs ' 4KSC'

play: $(TARGET)
	stella $(TARGET)

clean:
	rm -f $(TARGET) 4ksc_diagnostic.map 4ksc_diagnostic.lst 4ksc_diagnostic.sym 4ksc_diagnostic.cfg

.PHONY: all play clean fonts
