# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := fotomania_diagnostic.c26
TARGET := fotomania_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map fotomania_diagnostic.map $(SOURCE) -o $@
clean:
	rm -f fotomania_diagnostic.bin fotomania_diagnostic.map fotomania_diagnostic.hex fotomania_diagnostic.sym fotomania_diagnostic.lst fotomania_diagnostic.cfg
play: $(TARGET)
	stella -bs 0FA0 $(TARGET)
.PHONY: all clean play
