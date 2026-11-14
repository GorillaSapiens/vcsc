# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
TARGET := layers_score_above.bin
SOURCE := main.c26
COMMON := $(ROOT)/examples/_common/cooperating_layers_sprites.c26 $(ROOT)/examples/_common/cooperating_layers_motion.c26
INTERACTIVE := layers_score_above_interactive.bin
INTERACTIVE_COMMON := $(ROOT)/examples/_common/cooperating_layers_controls.c26 $(ROOT)/examples/_common/cooperating_layers_interactive_sprites.c26

all: $(TARGET)

$(TARGET): $(SOURCE) $(COMMON) $(VCS_DIR)/vcs.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/two_plus_two_score_support.c26 $(wildcard $(VCS_DIR)/layers/*.c26)
	$(VCSC) -I $(VCS_DIR) -Map $(TARGET:.bin=.map) $(SOURCE) -o $@
	@test `wc -c < $@` -eq 4096

play: all
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(TARGET)"

interactive: $(INTERACTIVE)

$(INTERACTIVE): interactive.c26 $(INTERACTIVE_COMMON) $(VCS_DIR)/vcs.c26 $(VCS_DIR)/color_ntsc.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/two_plus_two_score_support.c26 $(wildcard $(VCS_DIR)/layers/*.c26)
	$(VCSC) -I $(VCS_DIR) -Map $(INTERACTIVE:.bin=.map) $< -o $@
	@test `wc -c < $@` -eq 4096

play-interactive: interactive
	echo WARNING: ignoring user specific settings
	stella -dev.tv.jitter 0 -basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(INTERACTIVE)"

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) $(TARGET:.bin=.s26) $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg) *.o26
	rm -f $(INTERACTIVE) $(INTERACTIVE:.bin=.hex) $(INTERACTIVE:.bin=.map) $(INTERACTIVE:.bin=.s26) $(INTERACTIVE:.bin=.sym) $(INTERACTIVE:.bin=.lst) $(INTERACTIVE:.bin=.cfg)

.PHONY: all play interactive play-interactive clean
