# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

TARGET := heart_score.bin

all: $(TARGET)

$(TARGET): heart_score.c26 $(VCS_DIR)/components/heart_score_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/4K/mapper.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26
	$(VCSC) -I $(VCS_DIR) -I . -Map heart_score.map heart_score.c26 -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) *.hex *.map *.s26 *.o26 *.sym *.lst *.cfg

play: $(TARGET)
	echo WARNING: ignoring user specific settings
	stella \
		-dev.tv.jitter 0 \
		-dev.settings 1 \
		-dev.stats 1 \
		-dev.detectedinfo 1 \
		-dev.ramrandom 1 \
		-dev.bankrandom 1 \
		-basedir "$(CURDIR)" -userdir "$(CURDIR)" "$(CURDIR)/$(TARGET)"

.PHONY: all clean play
