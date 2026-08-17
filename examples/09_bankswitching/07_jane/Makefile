# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := jane_diagnostic.c26
TARGET := jane_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map jane_diagnostic.map $(SOURCE) -o $@
clean:
	rm -f jane_diagnostic.bin jane_diagnostic.map jane_diagnostic.hex jane_diagnostic.sym jane_diagnostic.lst jane_diagnostic.cfg
play: $(TARGET)
	stella -bs JANE $(TARGET)
.PHONY: all clean play
