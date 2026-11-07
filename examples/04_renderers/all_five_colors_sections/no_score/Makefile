# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGET := all_five_colors_sections_192.bin
SOURCE := all_five_colors_sections_192.c26
REPEATED_TARGET := all_five_colors_sections_192_repeated.bin

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/vcs.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/playfield.c26 \
           $(VCS_DIR)/F8/mapper.c26 \
           $(ROOT)/examples/_common/all_five_colors_sections_global_preview.c26 \
           $(ROOT)/examples/_common/all_five_colors_sections_preview_sprites.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 8192

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)
	rm -f $(REPEATED_TARGET) $(REPEATED_TARGET:.bin=.hex) $(REPEATED_TARGET:.bin=.map) $(REPEATED_TARGET:.bin=.s26) $(REPEATED_TARGET:.bin=.sym) $(REPEATED_TARGET:.bin=.lst) $(REPEATED_TARGET:.bin=.cfg)

# Explicit opt-in: this renderer still has documented edge-control differences.
repeated: $(REPEATED_TARGET)

$(REPEATED_TARGET): $(SOURCE) $(VCS_DIR)/vcs.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/playfield.c26 \
                    $(ROOT)/examples/_common/all_five_colors_sections_repeated_preview.c26 \
                    $(ROOT)/examples/_common/all_five_colors_sections_repeated_mapper.c26 \
                    $(ROOT)/examples/_common/all_five_colors_sections_preview_sprites.c26
	$(VCSC) -DALL_FIVE_REPEATED_PREVIEW=1 -I $(VCS_DIR) -Map $(REPEATED_TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 8192

play: all
	for rom in $(TARGET); do \
		echo WARNING: ignoring user specific settings; \
		stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$$rom" || exit $$?; \
	done

play-repeated: repeated
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(REPEATED_TARGET)"

.PHONY: all clean play repeated play-repeated
