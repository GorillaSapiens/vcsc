# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := vcsc_diagnostic.c26
BOOT := diagnostic_boot.s26
TARGET := vcsc_diagnostic.bin
all: $(TARGET)
$(TARGET): $(SOURCE) $(BOOT) diagnostic_pair_indices.c26 diagnostic_pairs.c26 diagnostic_collision_font.c26 diagnostic_support.c26
	$(VCSC) -I $(VCS_DIR) -I . -Wa,--illegals -T $(VCS_DIR)/vcs.cfg -Map vcsc_diagnostic.map $(SOURCE) $(BOOT) -o $@
diagnostic_collision_font.c26: diagnostic_collision_objects.font make_collision_font.pl
	./make_collision_font.pl diagnostic_collision_objects.font > $@
clean:
	rm -f vcsc_diagnostic.bin vcsc_diagnostic.map vcsc_diagnostic.lst vcsc_diagnostic.sym vcsc_diagnostic.cfg
play: $(TARGET)
	stella -bs F4SC $(TARGET)
.PHONY: all clean play
