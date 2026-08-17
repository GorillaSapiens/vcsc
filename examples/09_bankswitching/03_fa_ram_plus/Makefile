# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := fa_ram_plus_diagnostic.c26
TARGET := fa_ram_plus_diagnostic.bin

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg \
		-Map fa_ram_plus_diagnostic.map $(SOURCE) -o $@

clean:
	rm -f fa_ram_plus_diagnostic.bin fa_ram_plus_diagnostic.map \
		fa_ram_plus_diagnostic.hex fa_ram_plus_diagnostic.sym \
		fa_ram_plus_diagnostic.lst fa_ram_plus_diagnostic.cfg

play: $(TARGET)
	stella -bs FA $(TARGET)

.PHONY: all clean play
