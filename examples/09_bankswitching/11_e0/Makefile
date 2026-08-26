# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := e0_diagnostic.c26
TARGET := e0_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map e0_diagnostic.map $(SOURCE) -o $@
clean:
	rm -f e0_diagnostic.bin e0_diagnostic.map e0_diagnostic.hex e0_diagnostic.sym e0_diagnostic.lst e0_diagnostic.cfg
play: $(TARGET)
	stella -bs E0 $(TARGET)
.PHONY: all clean play
