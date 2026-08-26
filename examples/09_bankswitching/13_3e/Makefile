# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := 3e_diagnostic.c26
TARGET := 3e_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map 3e_diagnostic.map $(SOURCE) -o $@
clean:
	rm -f 3e_diagnostic.bin 3e_diagnostic.map 3e_diagnostic.hex 3e_diagnostic.sym 3e_diagnostic.lst 3e_diagnostic.cfg
play: $(TARGET)
	stella -bs 3E $(TARGET)
.PHONY: all clean play
