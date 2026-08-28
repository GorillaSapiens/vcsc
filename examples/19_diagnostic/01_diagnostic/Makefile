# This file is covered under CC0-1.0. See examples/LICENSE.txt.
ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs
SOURCE := vcsc_diagnostic.c26
BOOT := diagnostic_boot.s26
PHASES := 0 1 2 3
TARGETS := $(addprefix vcsc_diagnostic_phase,$(addsuffix .bin,$(PHASES)))

all: $(TARGETS)

vcsc_diagnostic_phase%.bin: $(SOURCE) $(BOOT) diagnostic_pair_indices.c26 diagnostic_pairs.c26 diagnostic_collision_font.c26 diagnostic_support.c26
	$(VCSC) -I $(VCS_DIR) -I . -Wa,--illegals -DDIAGNOSTIC_TEST_UI_PHASE=$* \
		-T $(VCS_DIR)/vcs.cfg -Map vcsc_diagnostic_phase$*.map $(SOURCE) $(BOOT) -o $@

diagnostic_collision_font.c26: diagnostic_collision_objects.font make_collision_font.pl
	./make_collision_font.pl diagnostic_collision_objects.font > $@

clean:
	rm -f vcsc_diagnostic_phase*.bin vcsc_diagnostic_phase*.map \
		vcsc_diagnostic_phase*.lst vcsc_diagnostic_phase*.sym vcsc_diagnostic_phase*.cfg

play: play0
play%: vcsc_diagnostic_phase%.bin
	stella -bs F4SC $<

.PHONY: all clean play play0 play1 play2 play3
