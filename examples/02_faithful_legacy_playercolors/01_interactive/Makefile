# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PROFILE := $(VCS_DIR)/renderers/faithful_legacy_playercolors

TARGET := faithful_legacy_playercolors_interactive.bin
SOURCE := faithful_legacy_playercolors_interactive.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/playfield.c26 \
           $(PROFILE)/faithful_legacy_playercolors.c26 \
           $(PROFILE)/faithful_legacy_playercolors_macros.inc \
           $(ROOT)/examples/common/fixed_six_digit_controls.c26 \
           $(PROFILE)/faithful_legacy_playercolors.cfg
	$(VCSC) -I $(VCS_DIR) -Wa,--illegals \
	  -T $(PROFILE)/faithful_legacy_playercolors.cfg \
	  -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

play:
	stella *.bin

.PHONY: all clean play
