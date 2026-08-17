# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
STELLA ?= stella
SOURCE := cv_diagnostic.c26
TARGET := cv_diagnostic.bin

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -T $(VCS_DIR)/vcs.cfg \
		-Map cv_diagnostic.map $(SOURCE) -o $@

play: $(TARGET)
	$(STELLA) $(TARGET)

clean:
	rm -f cv_diagnostic.bin cv_diagnostic.map cv_diagnostic.hex \
		cv_diagnostic.sym cv_diagnostic.lst cv_diagnostic.cfg

.PHONY: all play clean
