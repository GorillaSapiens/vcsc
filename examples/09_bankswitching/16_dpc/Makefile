# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PERL ?= perl
FONT_SUBSET_TOOL := $(VCS_DIR)/fonts/make_font_subset.pl
SMALL_FONT := $(VCS_DIR)/fonts/default_ascii.c26
FONT_SUBSET_DIR ?= .
COMMITTED_FONT_SUBSETS := diagnostic_font.c26
FONT_SUBSET_FLAGS := --license examples/LICENSE.txt --bank bank0 --no-page
SOURCE := dpc_diagnostic.c26
TARGET := dpc_diagnostic.bin

all: $(TARGET)

$(TARGET): $(SOURCE) dpc_data.c26 $(COMMITTED_FONT_SUBSETS)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map dpc_diagnostic.map $(SOURCE) -o $@

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/diagnostic_font.c26 dpc_glyphs ' PASFAILDPC'

clean:
	rm -f dpc_diagnostic.bin dpc_diagnostic.map dpc_diagnostic.hex dpc_diagnostic.sym dpc_diagnostic.lst dpc_diagnostic.cfg

play: $(TARGET)
	stella -bs DPC $(TARGET)

.PHONY: all clean play fonts
