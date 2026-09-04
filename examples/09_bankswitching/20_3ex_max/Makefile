# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PERL ?= perl
FONT_SUBSET_TOOL := $(VCS_DIR)/fonts/make_font_subset.pl
MESSAGE_FONT_TOOL := $(VCS_DIR)/fonts/make_message_glyphs.pl
BIG_FONT := $(VCS_DIR)/fonts/big_ascii.c26
SMALL_FONT := $(VCS_DIR)/fonts/default_ascii.c26
FONT_SUBSET_DIR ?= .
COMMITTED_FONT_SUBSETS := status_font.c26 wait_font.c26 cart_type_font.c26
COMMON_FONT_FLAGS := --license examples/LICENSE.txt --no-page
STATUS_FONT_FLAGS := $(COMMON_FONT_FLAGS) --bank bank254
WAIT_FONT_FLAGS := $(COMMON_FONT_FLAGS) --bank bank253
CART_FONT_FLAGS := $(COMMON_FONT_FLAGS) --bank bank251
SOURCE := 3ex_max_diagnostic.c26
TORTURE := $(sort $(wildcard 3ex_max_torture_*.s26))
SWAPRAM_SOURCE := $(sort $(wildcard 3ex_max_swapram_*.c26))
SWAPRAM_STORAGE := $(sort $(wildcard 3ex_max_swapram_storage_*.s26))
TARGET := 3ex_max_diagnostic.bin

all: $(TARGET)

$(TARGET): $(SOURCE) $(TORTURE) $(SWAPRAM_SOURCE) $(SWAPRAM_STORAGE) $(COMMITTED_FONT_SUBSETS)
	$(VCSC) -I $(VCS_DIR) -Map 3ex_max_diagnostic.map $(SOURCE) $(TORTURE) $(SWAPRAM_SOURCE) $(SWAPRAM_STORAGE) -o $@

fonts:
	$(PERL) $(FONT_SUBSET_TOOL) $(STATUS_FONT_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/status_font.c26 status_glyphs ' pasFAIL'
	$(PERL) $(FONT_SUBSET_TOOL) $(WAIT_FONT_FLAGS) $(BIG_FONT) $(FONT_SUBSET_DIR)/wait_font.c26 wait_glyphs ' wait/-\|'
	$(PERL) $(MESSAGE_FONT_TOOL) $(SMALL_FONT) '3EX max' > $(FONT_SUBSET_DIR)/cart_type_font.c26
	$(PERL) ./make_torture.pl

torture:
	$(PERL) ./make_torture.pl

clean:
	rm -f 3ex_max_diagnostic.bin 3ex_max_diagnostic.map 3ex_max_diagnostic.hex 3ex_max_diagnostic.sym 3ex_max_diagnostic.lst 3ex_max_diagnostic.cfg

play: $(TARGET)
	stella -bs 3EX $(TARGET)

.PHONY: all clean play fonts torture
