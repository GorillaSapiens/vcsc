# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCSLIB ?= $(ROOT)/libraries/vcs
TARGET = 4ksc_diagnostic.bin
SOURCE = 4ksc_diagnostic.c26

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCSLIB) -T $(VCSLIB)/vcs.cfg -Map $(@:.bin=.map) $< -o $@

play: $(TARGET)
	stella $(TARGET)

clean:
	rm -f $(TARGET) 4ksc_diagnostic.map 4ksc_diagnostic.lst 4ksc_diagnostic.sym 4ksc_diagnostic.cfg

.PHONY: all play clean
