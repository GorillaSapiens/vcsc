# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := all_five_sections_192.bin
SOURCE := all_five_sections_192.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/vcs.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/playfield.c26 \
           $(VCS_DIR)/renderers/all_five_sections_192/all_five_sections_192.c26 \
            $(VCS_DIR)/renderers/all_five_sections_192/palette.c26 \
            $(VCS_DIR)/renderers/all_five_sections_common.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

play: all
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(TARGET)"

.PHONY: all clean play
