# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGET := ntsc_blank.bin
SOURCE := ntsc_blank.c26

all: $(TARGET)

$(TARGET): $(SOURCE)
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

play: $(TARGET)
	stella -userdir "$(CURDIR)" -format NTSC "$(CURDIR)/$(TARGET)"

clean:
	rm -f $(TARGET) *.map *.lst *.sym *.cfg *.hex *.s26 *.o26

.PHONY: all play clean
