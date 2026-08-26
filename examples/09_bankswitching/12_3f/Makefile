# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := 3f_diagnostic.c26
TARGET := 3f_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map 3f_diagnostic.map $(SOURCE) -o $@
clean:
	rm -f 3f_diagnostic.bin 3f_diagnostic.map 3f_diagnostic.hex 3f_diagnostic.sym 3f_diagnostic.lst 3f_diagnostic.cfg
play: $(TARGET)
	stella -bs 3F $(TARGET)
.PHONY: all clean play
