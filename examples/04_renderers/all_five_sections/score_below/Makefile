# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := all_five_sections_181_score_below_interactive.c26
TARGET := $(SOURCE:.c26=.bin)

all: $(TARGET)

$(TARGET): $(SOURCE) $(wildcard $(VCS_DIR)/renderers/all_five_sections*/*.c26) $(VCS_DIR)/renderers/all_five_sections_common.c26 $(VCS_DIR)/six_glyph_component.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(ROOT)/examples/_common/all_five_sections_181_interactive_common.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 8192

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

play: all
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(TARGET)"

.PHONY: all clean play
