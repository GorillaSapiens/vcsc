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
FONT_SUBSET_FLAGS := --license examples/LICENSE.txt --bank bank255
SOURCE := 3f_max_diagnostic.c26
TORTURE := $(sort $(wildcard 3f_max_torture_*.s26))
TARGET := 3f_max_diagnostic.bin

all: $(TARGET)

$(TARGET): $(SOURCE) $(TORTURE) $(COMMITTED_FONT_SUBSETS)
	$(VCSC) -I $(VCS_DIR) -Map 3f_max_diagnostic.map $(SOURCE) $(TORTURE) -o $@

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/status_font.c26 status_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/cart_type_font.c26 cart_type_glyphs '3F max'

torture:
	$(PERL) ./make_torture.pl

clean:
	rm -f 3f_max_diagnostic.bin 3f_max_diagnostic.map 3f_max_diagnostic.hex 3f_max_diagnostic.sym 3f_max_diagnostic.lst 3f_max_diagnostic.cfg

play: $(TARGET)
	stella -bs 3F $(TARGET)

.PHONY: all clean play fonts torture
