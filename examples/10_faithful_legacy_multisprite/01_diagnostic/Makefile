# This file is covered under CC0-1.0. See examples/LICENSE.txt.

ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
PROFILE := $(VCS_DIR)/renderers/faithful_legacy_multisprite
TARGET := faithful_legacy_multisprite_diagnostic.bin
SOURCE := faithful_legacy_multisprite_diagnostic.c26
RENDERER := $(PROFILE)/faithful_legacy_multisprite_renderer.s26
STARTUP := $(PROFILE)/faithful_legacy_multisprite_startup.s26
FIXTURE := faithful_legacy_multisprite_diagnostic_data.s26

all: $(TARGET)

$(TARGET): $(SOURCE) $(FIXTURE) $(PROFILE)/faithful_legacy_multisprite.c26 \
           $(PROFILE)/faithful_legacy_multisprite.cfg $(RENDERER) $(STARTUP)
	$(VCSC) -nostdlib -I $(VCS_DIR) -Wa,--illegals \
	  -T $(PROFILE)/faithful_legacy_multisprite.cfg \
	  -Map $(TARGET:.bin=.map) $(SOURCE) $(FIXTURE) $(RENDERER) $(STARTUP) -o $@
	@test `wc -c < $@` -eq 4096

clean:
	rm -f $(TARGET) $(TARGET:.bin=.hex) $(TARGET:.bin=.map) \
	  $(TARGET:.bin=.sym) $(TARGET:.bin=.lst) $(TARGET:.bin=.cfg) \
	  $(TARGET:.bin=.s26) *.o26

play:
	stella *.bin

.PHONY: all clean play
