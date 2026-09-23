# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
VCSC_BUILD_DEPS := $(VCSC) $(ROOT)/compiler/vcsc-cc1 $(ROOT)/assembler/vcsc-as \
	$(ROOT)/linker/vcsc-ld $(ROOT)/libraries/runtime/libvcsc.l26 \
	$(wildcard $(VCS_DIR)/*.c26) $(wildcard $(VCS_DIR)/3E/*.c26 $(VCS_DIR)/3E/*.s26)
PERL ?= perl
FONT_SUBSET_TOOL := $(VCS_DIR)/fonts/make_font_subset.pl
BIG_FONT := $(VCS_DIR)/fonts/big_ascii.c26
SMALL_FONT := $(VCS_DIR)/fonts/default_ascii.c26
FONT_SUBSET_DIR ?= .
COMMITTED_FONT_SUBSETS := status_font.c26 cart_type_font.c26
FONT_SUBSET_FLAGS := --license examples/LICENSE.txt --bank bank2
SOURCE := 3e_diagnostic.c26
TARGET := 3e_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE) $(VCSC_BUILD_DEPS)
	$(VCSC) -I $(VCS_DIR) -Map 3e_diagnostic.map $(SOURCE) -o $@
$(TARGET): $(COMMITTED_FONT_SUBSETS)

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/status_font.c26 status_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(FONT_SUBSET_FLAGS) $(SMALL_FONT) $(FONT_SUBSET_DIR)/cart_type_font.c26 cart_type_glyphs ' 3E'

clean:
	rm -f 3e_diagnostic.bin 3e_diagnostic.map 3e_diagnostic.hex 3e_diagnostic.sym 3e_diagnostic.lst 3e_diagnostic.cfg
play: $(TARGET)
	echo WARNING: ignoring user specific settings
	stella \
		-dev.tv.jitter 0 \
		-dev.settings 1 \
		-dev.stats 1 \
		-dev.detectedinfo 1 \
		-dev.ramrandom 1 \
		-dev.bankrandom 1 \
		-basedir "$(CURDIR)" -userdir "$(CURDIR)" -bs 3E "$(CURDIR)/$(TARGET)"
.PHONY: all clean play fonts
