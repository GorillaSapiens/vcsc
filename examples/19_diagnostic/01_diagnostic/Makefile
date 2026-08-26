# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := vcsc_diagnostic.c26
TARGET := vcsc_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE) diagnostic_pair_indices.c26 diagnostic_pairs.c26 diagnostic_support.c26
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map vcsc_diagnostic.map $(SOURCE) -o $@
clean:
	rm -f vcsc_diagnostic.bin vcsc_diagnostic.map vcsc_diagnostic.lst vcsc_diagnostic.sym vcsc_diagnostic.cfg
play: $(TARGET)
	stella -bs F4SC $(TARGET)
.PHONY: all clean play
