# This example is covered under CC BY-NC-SA 4.0. See LICENSE.txt.

ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := player_color_192_animated_sprites.bin
SOURCE := player_color_192_animated_sprites.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/frame_ntsc.c26 \
           $(VCS_DIR)/playfield.c26 \
           $(VCS_DIR)/renderers/all_five/all_five.c26
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) *.o26 $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg)

play:
	echo WARNING: ignoring user specific settings
	stella \
		-dev.tv.jitter 0 \
		-dev.settings 1 \
		-dev.stats 1 \
		-dev.detectedinfo 1 \
		-dev.ramrandom 1 \
		-dev.bankrandom 1 \
		-basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)"/*.bin

.PHONY: all clean play
