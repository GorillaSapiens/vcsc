# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := econobanking_diagnostic.c26
TARGET := econobanking_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg -Map econobanking_diagnostic.map $(SOURCE) -o $@
clean:
	rm -f econobanking_diagnostic.bin econobanking_diagnostic.map econobanking_diagnostic.hex econobanking_diagnostic.sym econobanking_diagnostic.lst econobanking_diagnostic.cfg
play: $(TARGET)
	stella -bs 0840 $(TARGET)
.PHONY: all clean play
