# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGET := ntsc_player_color_192_interactive.bin
SOURCE := ntsc_player_color_192_interactive.c26

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

play: $(TARGET)
	stella -format NTSC $(TARGET)

clean:
	rm -f $(TARGET) *.map *.lst *.sym *.cfg *.hex *.s26 *.o26

.PHONY: all play clean
