# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGET := layers_no_score.bin
SOURCE := main.c26
COMMON := $(ROOT)/examples/_common/cooperating_layers_sprites.c26 $(ROOT)/examples/_common/cooperating_layers_motion.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(COMMON) $(VCS_DIR)/vcs.c26 $(VCS_DIR)/frame_ntsc.c26 $(wildcard $(VCS_DIR)/layers/*.c26)
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

play: all
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(TARGET)"

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg) *.o26

.PHONY: all play clean
