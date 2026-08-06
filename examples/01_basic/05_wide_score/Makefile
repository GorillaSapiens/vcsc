ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: wide_score.bin

wide_score.bin: wide_score.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/six_glyph_wide_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/vcs_2k.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs.cfg
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map wide_score.map wide_score.c26 -o $@
	@test `wc -c < $@` -eq 2048

clean:
	rm -f wide_score.bin wide_score.hex wide_score.map wide_score.s26 wide_score.sym wide_score.lst wide_score.cfg

.PHONY: all clean
