# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
VCSC_BUILD_DEPS := $(VCSC) $(ROOT)/compiler/vcsc-cc1 $(ROOT)/assembler/vcsc-as \
	$(ROOT)/linker/vcsc-ld $(ROOT)/libraries/runtime/libvcsc.l26 \
	$(wildcard $(VCS_DIR)/*.c26) $(wildcard $(VCS_DIR)/E0/*.c26 $(VCS_DIR)/E0/*.s26)
PERL ?= perl
FONT_SUBSET_TOOL := $(VCS_DIR)/fonts/make_font_subset.pl
BIG_FONT := $(VCS_DIR)/fonts/big_ascii.c26
SMALL_FONT := $(VCS_DIR)/fonts/default_ascii.c26
FONT_SUBSET_DIR ?= .
COMMITTED_FONT_SUBSETS := status_font.c26 cart_type_font.c26
FONT_SUBSET_FLAGS := --license examples/LICENSE.txt --bank bank5 --no-page
SOURCE := e0_diagnostic.c26
TARGET := e0_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE) $(VCSC_BUILD_DEPS)
	$(VCSC) -I $(VCS_DIR) -Map e0_diagnostic.map $(SOURCE) -o $@
$(TARGET): $(COMMITTED_FONT_SUBSETS)

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/status_font.c26 status_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/cart_type_font.c26 cart_type_glyphs ' E0'

clean:
	rm -f e0_diagnostic.bin e0_diagnostic.map e0_diagnostic.hex e0_diagnostic.sym e0_diagnostic.lst e0_diagnostic.cfg
play: $(TARGET)
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" -bs E0 "$(CURDIR)/$(TARGET)"
.PHONY: all clean play fonts
