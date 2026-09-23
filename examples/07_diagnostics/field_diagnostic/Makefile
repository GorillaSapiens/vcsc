# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PERL ?= perl
FONT_SUBSET_DIR ?= .
SOURCE := vcsc_diagnostic.c26
BOOT := diagnostic_boot.s26
TARGET := vcsc_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE) $(BOOT) diagnostic_pair_indices.c26 diagnostic_pairs.c26 diagnostic_collision_font.c26 diagnostic_fingerprint_font.c26 diagnostic_support.c26 $(VCS_DIR)/fonts/logo_font.c26
	$(VCSC) -I $(VCS_DIR) -I . -Wa,--illegals -Map vcsc_diagnostic.map $(SOURCE) $(BOOT) -o $@
fonts:
	@mkdir -p "$(FONT_SUBSET_DIR)"
	$(PERL) ./make_collision_font.pl "$(VCS_DIR)/fonts/half_ascii.c26" > "$(FONT_SUBSET_DIR)/diagnostic_collision_font.c26"
	$(PERL) "$(VCS_DIR)/fonts/make_font_subset.pl" --bank bank3 --license examples/LICENSE.txt "$(VCS_DIR)/fonts/big_ascii.c26" "$(FONT_SUBSET_DIR)/diagnostic_fingerprint_font.c26" diagnostic_fingerprint_font 0123456789ABCDEF
clean:
	rm -f vcsc_diagnostic.bin vcsc_diagnostic.map vcsc_diagnostic.lst vcsc_diagnostic.sym vcsc_diagnostic.cfg
play: $(TARGET)
	echo WARNING: ignoring user specific settings
	stella \
		-dev.tv.jitter 0 \
		-dev.settings 1 \
		-dev.stats 1 \
		-dev.detectedinfo 1 \
		-dev.ramrandom 1 \
		-dev.bankrandom 1 \
		-basedir "$(CURDIR)" -userdir "$(CURDIR)" -bs F4SC "$(CURDIR)/$(TARGET)"
.PHONY: all fonts clean play
