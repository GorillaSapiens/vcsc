ROOT ?= ../../..
VCSC ?= $(ROOT)/driver/vcsc
VCS_DIR ?= $(ROOT)/libraries/vcs

all: score.bin

score.bin: score.c26 $(VCS_DIR)/fonts/default_decimal.c26 $(VCS_DIR)/six_glyph_component.c26 $(VCS_DIR)/frame_ntsc.c26 $(VCS_DIR)/vcs_2k.c26 $(VCS_DIR)/vcs.c26 $(VCS_DIR)/tia.c26 $(VCS_DIR)/riot.c26 $(VCS_DIR)/vcs.cfg
	$(VCSC) -I $(VCS_DIR) -I . -T $(VCS_DIR)/vcs.cfg -Map score.map score.c26 -o $@
	@test `wc -c < $@` -eq 2048

clean:
	rm -f score.bin score.hex score.map score.s26 score.sym score.lst score.cfg

.PHONY: all clean
